# Changelog

## 2026-09-04 — A whole track from four waveforms, and the chapter that failed

A session film and six Shorts, built by driving DAW Pro over the control
protocol and photographing it as it went. **No generation model was used for
any audio** — every sound is written as notes and shaped with the app's own
synth, filter, envelope and effects.

The constraint is the film. The built-in poly synth accepts exactly
`saw|square|triangle|sine` and refuses everything else (measured, with a bogus
value refused the same way as a control), so there is no noise oscillator and no
sample is loaded — a police siren, a heartbeat, thunder, an 808 and a singing
vowel all had to come out of those four shapes.

**`scripts/video/session/`** is the whole rig: `build.mjs` (the wire helpers,
which refuse port 17600 outright), `sounds.mjs` / `thunder2.mjs` / `sat.mjs`
(one chapter's sound per run, rendered solo and measured), `track.mjs` (the
64-bar arrangement, 8 tracks, 1,329 notes), `loops.mjs` (the DJ chapter),
`capture.mjs` (the screenshots), and `spec.py` / `shorts.py`, which emit the
specs for `shortsmith.py` with every figure injected from `MEASUREMENTS.json`.
**A number is never typed twice**, so the film and the Shorts cannot disagree.

⭐ **The rain chapter stays in, and it failed.** Spectral flatness went 0.0001 →
0.0157 across two attempts — 157x better and still 36x short of white noise's
0.5615. Cutting it would have made every other number less believable.

⭐ **`shortsmith.py` now refuses to narrate a spec whose gates cannot pass.**
A `factCheck` for "four bars" against a script that says "four-bar" burned eight
speech takes before anyone noticed the gate, not the voice, was wrong. The
pre-flight compares every `factCheck` and `brandCheck` against the script text
before any synthesis runs, and was positive-controlled with a planted impossible
gate. It caught two more spec bugs in this wave's own Shorts.

⭐ **Narration is cached on a hash of the text AND its gates**, so fixing a typo
in one stage no longer re-synthesises the other eleven. A 30-minute rebuild
became about two minutes, which is what made iterating on the gates affordable.

⚠️ **`amix` was quietly taking 6 dB off every bedded narration** — it normalises
by input count. Fixed with `normalize=0`, verified by re-measuring a bedded
stage (−5 dB → +1.44 dB) against an unbedded control that moved by exactly 0.00.

⚠️ **A moving `crop` can pan but not zoom.** ffmpeg evaluates `crop`'s width and
height once at configure time, so an animated zoom has to move the origin at a
fixed size. `assemble.py`'s `_crop_expr` does that, and a comma inside `min()`
ends `crop`'s argument list — reported, unhelpfully, as a missing filter.

⭐⭐ **No gate in this rig knows WHERE a zoom lands.** The film shipped once with
the siren chapter's zoom framing empty timeline below the synth panel, and all
eight verify gates passed — "distinct frames" is content with two different views
of nothing. Rendering each zoom rect as a still and looking at it took three
minutes and caught that plus a saturator panel reading 30.0 dB under a narration
that says "thirty two decibels". The panel was re-shot at the measured figure;
the sentence was right.

⭐⭐ **Three card-layout bugs, all found by reading one frame.** `sp()` inserted
three literal spaces between letters while `card_bignumber` and `card_list`
already letter-space with `track=`, so every label was rendered at triple width
and auto-shrank to 12-24 pt to fit — legible, and a third of its intended size.
`card_bignumber` had no fit at all on its label and unit, so "THE SIREN,
MEASURED" shipped as "E SIREN, MEASUR". And a `list` card's left key had no
column bound, so "the fundamental never moved" drew straight through its own
value. The renderer now fits all three; the specs no longer need it to.

**Shipped:** the 405 s film and six Shorts, each with a publish sidecar
carrying `containsSyntheticMedia: true`. The generated video is deliberately not
committed; `.gitignore` now covers the media formats, `shots/`, `vo/` and
`segments/` (601 MB of intermediates in this wave alone), with the reference
voice files explicitly un-ignored.

## 2026-09-03h — A publisher that defaults to private, and a scope that would have failed quietly

**`plugins/narrated-film/scripts/publish.py`** uploads a finished film to
YouTube, sets its thumbnail, files it in a playlist resolved BY TITLE (created
if missing), and then **reads the video back** to assert title, privacy,
duration and the synthetic-media flag against what was sent. Guide:
`PUBLISHING.md`.

⚠️ **The scope is `.../auth/youtube`, not `youtube.upload`.** Verified against
the per-method authorization tables rather than recalled:
`playlistItems.insert` accepts `youtube`, `youtubepartner` and
`youtube.force-ssl` but **NOT** `youtube.upload`. The narrow scope uploads
successfully and then fails to file the video — a partial success, which is this
tree's characteristic failure shape.

⚠️ **Uploads from an unaudited API project are FORCED to private** (any project
created after 2020-07-28, until it passes YouTube's compliance audit).
`verify` detects that exact case — asked public, stored private — and reports it
as the audit lock with the remedy, rather than as a mismatch.

⭐ **Verify POLLS.** `contentDetails.duration` is absent while YouTube is still
processing, so a single read would compare against nothing and pass. It waits
for `processed` before asserting.

**Everything checkable offline is checked offline**, so the metadata is provably
right before the one irreversible call. All 14 rules were negative-controlled:
11 fail with exit 1 (over-long/blank/angle-bracketed title, over-long
description, over-long tag set, non-numeric category, bad privacy, malformed
`publishAt`, `publishAt` on a non-private video, missing thumbnail, non-boolean
flags) and 3 warn deliberately and pass (unknown category id, `public`, unknown
key). `--dry-run` prints the exact request body and touches no network.

**Sidecars written for all five existing films** from the descriptions already
drafted, and all five validate against their actual video files.

⚠️ **The network paths are UNTESTED and cannot be tested until the user
authorises** — that is stated in the guide and in the report rather than being
papered over. `install.sh --publish` adds the Google libraries as an OPTIONAL
extra so the tested default install is unchanged; `client_secret*.json` and
`*token*.json` are gitignored, proven with a positive control and a negative
control on `brand.json`.

## 2026-09-03g — A plugin agent that silently lost its tools, and doc rot in the skill that taught it

**`claude plugin validate` fails on `claude-plugin/agents/demo-director.md`, and
that failure was invisible.** Its `description:` was an unquoted YAML scalar
containing a colon-space, sitting above a `tools: >-` folded block; the parser
cannot recover across that combination. The runtime consequence is the dangerous
part: the agent still LOADS, taking its name from the filename, and **every
other frontmatter field — `model: opus` and all 40-odd tool grants — is silently
dropped.** A broken agent and a working one look identical until you run the
validator. Both descriptions (`demo-director`, and `film-director` in the new
plugin, which had the same latent shape) are now quoted, with the text preserved
byte-for-byte through the escape. Both plugins validate clean.

⭐ **The bisect was wrong until it had a baseline.** Quoting the description
"fixed" it and removing the tools block "fixed" it — two independent single
changes, which cannot both be the cause. The missing experiment was running the
UNMODIFIED file through the same harness; it failed, confirming both results
were real and the fault is the interaction, not either half.

**Doc rot found by looking where the code had moved.** `skills/demo-film/SKILL.md`
still taught the md5 frame check — extract PNGs, `md5 -q | sort -u | wc -l` —
which this session PROVED passes a film that is a single still image, because
h264 noise makes every extracted frame a different md5. It now points at
`verify.py`, which sits in that same directory and compares pixels against a
measured noise floor. `BRAND.md` still described `--holder` as defaulting to a
neutral built-in; it now names `brand.json` as the source of truth and those
flags as per-run overrides.

⚠️ **`--brand` defaults to the copy inside the plugin.** Measured: with a
`brand.json` in the working directory, `brand.py` without `--brand` loads the
plugin's own file and ignores the local one — so a user's edited identity is
skipped and the cards render the placeholder wordmark `YOUR BRAND` while passing
every check in the kit. Documented in the plugin's SKILL.md and README, with the
flag added to every example. The scripts print the brand file they loaded.

**Verified by positive control:** agents AND skills are genuinely discovered by
the validator (a deliberately broken copy of each was caught), so a clean pass
means checked, not skipped.

## 2026-09-03f — Three follow-ups, and a confound removed rather than documented

**The `ms-halo` limiter ceiling was the wrong fix, and it is reverted.** It had
been dropped to −4.4 dB to stop an AAC overshoot; that worked, but it limited
that variant 2.8 dB harder than its siblings on an axis whose entire purpose is
comparing INSTRUMENTS — so the listener would have been judging the limiter.
MEASURED: encoding at 320k instead of 256k removes the overshoot completely
(+1.0 → −1.2 dBTP) at the SAME −1.6 ceiling every other variant uses. The
overshoot was codec headroom and the fix belonged in the encoder. All seven
variants now share one ceiling and one bitrate, so the only difference between
any two files is the thing named in its label. The original 256k encodes of the
first three are kept in `256k-originals/`. ⭐ **A confound you can remove beats
a confound you document.**

**Both tech-house cuts get a trimmed greeting.** The shared greeting said "a
digital audio workstation written almost entirely by AI" and the film's own
opening said the same thing twelve seconds later. The identity sentence — "I am
DAW Pro Claude Opus five" — is identical across every film, which is what
carries the brand; only the overlapping clause is dropped. Lessons 1 and 2 keep
the full greeting, because their openings do not collide with it. This avoided
re-rendering 22 stages from an older-schema manifest, which was the actual risk.

**The Russian cut is re-done**, with Russian voice-over and a Russian opening
chapter.

The brand-substring gate earned its place twice more. Both new greetings passed
the aggregate content gate (0.83 and 0.89) while saying **"DAW Proclawed Opus
five"** and **"DAW Pro Cloud Opus five"**. The English one was a real speech
defect and took four regenerations to land. ⭐⭐ **The Russian one was NOT** —
transcribing the ALREADY-SHIPPED Russian narration through the same recogniser
shows it renders "Claude" as "Cloud" too, so that is Russian Whisper
transliterating and the take was correct all along. **The same control that
convicted the English take exonerated the Russian one; without it, six more
regenerations would have chased a defect that did not exist.**

The Russian film's join measured a 0.52 sample jump against 0.13 for English.
Not a click: the source film, before any concatenation, has that same 0.5193
step inside its own first 0.3 s, and both films start at exactly 0.0000. The
concat contributed nothing. **Measure the source before blaming the edit.**

Chapters re-derived for both tech-house cuts (+13 s, not the +17 s the longer
greeting needed) and all five descriptions re-validated against actual
durations; the tech-house runtime claim corrected to 13:35.

## 2026-09-03e — The film pipeline becomes its own plugin

The narrated-video pipeline is now `narrated-film`, a second plugin in this
repo's marketplace with **no dependency on DAW Pro or on any other
application**. `/plugin install narrated-film@daw-pro`.

`tools/voice-video-kit/` was MOVED, not copied, to `plugins/narrated-film/` —
it already existed to be "installed and run on its own" and only lacked a
manifest, a skill and an agent. A third copy of these scripts would have been
the duplication this tree has laws against. What moved: the installer, the
cloned voice, the content gate, the assembler, the brand cards, the channel
art. What did NOT move: `dawctl.mjs` and `panels.mjs`, which drive DAW Pro's
control port and stay in `skills/ui-capture/`. **The generic plugin no longer
requires node at all** — it was only ever needed by those two files.

**Brand identity is now data.** `brand.py` and `channel.py` read `brand.json`
— wordmark, sub-label, byline, copyright holder, disclaimer, palette, fonts,
and `markBars`, the bar heights of the mark itself — instead of hardcoding
"DAW PRO" in six places. DAW Pro's own values live in a `brand.json` beside the
plugin's mirror, so its invocations are unchanged.

**Pinned, not assumed.** Rendering the DAW cards through the parameterised
scripts produces output **bit-identical** to the shipped `intro.mp4`,
`outro.mp4`, `avatar.png`, `lockup.png` and `banner.png` — mean difference
0.00, zero pixels changed, at every sampled frame. The control is a render with
the *generic* brand file, which differs by 54,000–129,000 pixels and, on the
intro, matches the shipped card until t=3.0 s and diverges exactly when the
wordmark resolves. A pin that cannot fail is not a pin.

**New: `scripts/verify.py`.** The probes that had been retyped as shell
one-liners all week, in one place with exit codes: streams, A/V drift, distinct
frames, audio present, loudness and true peak, concat join seams, and
transcribe-back scored against its own script *and a different stage's*. Every
check that could pass by doing nothing carries a positive control, and a check
whose control fails reports `BROKEN` rather than `ok`.

Writing it produced three findings of exactly the kind it exists to catch, all
found by running it against a deliberately broken film rather than by reading
it:

- The frame check originally **hashed** the extracted PNGs and **passed a film
  that was a single still image for its entire duration** — h264 noise makes
  every extracted frame a different md5, so six identical pictures scored "5
  distinct of 6". Hashing answers *are these files identical*, which is not the
  question. It compares pixels now, against a measured noise floor (still film:
  max 0.11; real film: max 5.04).
- The loudness check read ebur128's **first per-frame** reading rather than the
  summary and reported **−70.0 LUFS** for a healthy film, because the film opens
  on a title card and frame one is gated silence. A wrong number that looks
  exactly like a real measurement.
- The join-seam **control was not a worst case**: splicing two arbitrary moments
  gave a jump of 0.06 while ordinary audio in the same film reached 0.11, so the
  control sat *below* the thing it was meant to bound. It is now peak against
  inverted peak (0.91), which is the real worst case for the material.

A fourth was a policy error rather than a bug: the loudness check enforced
−14 LUFS by default and failed a perfectly good narrated lesson at −19.3. There
is no single right integrated loudness for a film; the number is always
reported and only enforced when the caller states a target. True peak over
−1.0 dBTP stays a failure whatever the material.

`REF_TEXT` in `narrate.py` still names DAW Pro, and that is correct — it is the
literal transcript of the shipped reference clip. It now says so, loudly:
generalising the string without replacing the audio degrades every line the
model speaks, and the result still passes the content gate.

DAW Pro plugin **0.10.0** (its mirrored scripts changed, and it gains
`verify.py` and `design-voice.py`).

## 2026-09-03d — MuseScore trailer variants, and a greeting on the back catalogue

Four more channel-trailer variants, and the brand intro/greeting/end card added
to the three films that shipped before Lesson 3 set the format. The existing
three trailer variants are untouched and still byte-reproducible: `build.mjs`
now takes variant names on the command line and defaults to exactly the old
three.

**The variants move on one axis at a time.** The original three vary ENERGY on
General MIDI; the four new ones freeze energy at `theme` and vary INSTRUMENTS
(MuseScore_General.sf2). Comparing across both at once would make a pick
meaningless. All seven are gain-matched to −14.0…−14.2 LUFS measured on the
delivered m4a, and pairwise-verified distinct (max-abs sample difference, with
a file-against-itself control returning exactly 0.000000).

Four things measured here, three of which were wrong first:

**A patch that loads is not a patch that plays.** `project.overview` cannot
verify a sound bank — its `instrument` field is the bare string `"soundBank"`,
so the obvious readback would have thrown on every variant. `project.snapshot`
carries the resolved patch NAME, which is the real gate: asking for a bank/LSB
that is not in the file stores the numbers *exactly as requested* — a numeric
round-trip passes it — and resolves to a placeholder `MuseScore_General · P89`
instead of a real patch name. Verified by planting a bogus LSB and watching the
name check fire where the number check could not.

**Two files can be different patches and identical audio.** The "Expr." variant
rendered byte-identical to the plain MuseScore one: same md5, sample difference
exactly zero. The patches had loaded correctly. MuseScore builds them as the
same samples with modulators routed to CC11 expression, so with nothing written
on CC11 they *cannot* differ — the patch was fine, it had nothing to respond
to. That variant now writes the swell, which is the only thing that makes the
bank mean anything. Caught only because two variants reported identical loudness
to two decimal places.

**AAC overshoot is material-dependent, not a constant.** The halo/vibraphone
variant rendered a clean −1.6 dBTP (DAW and ffmpeg agreeing) and encoded to
**+1.0 dBTP** — a 2.6 dB overshoot where the same ceiling on `theme` overshot
0.3 dB. Bright, dense, sustained content is the codec's worst case. Fixed with a
per-variant ceiling (−4.4 dB), which costs no loudness because the convergence
loop makes the target back up with gain.

**A content gate that passes can still be shipping a wrong brand name.** The
greeting scored 0.86 similarity — comfortably over the 0.60 floor — while
saying *"Diadavius, Proclawed Opus five"* for "DAW Pro Claude Opus five". Four
words out of forty cannot move an aggregate score, and those four are the only
ones that must be right. It was caught by transcribing the ALREADY-SHIPPED
Lesson 3, which renders the same phrase cleanly through the same recogniser —
proving the fault was in the speech, not the transcription. Regenerated with an
explicit check on the brand phrase; the accepted take scores 0.95.
**An aggregate similarity score cannot gate a short critical substring — check
the substring.**

The three films are re-cut by stream copy, not re-encode: intro/outro/film all
measured identical (h264 High, yuv420p, 1920×1080, 30/1, tb 1/15360, aac 48k
stereo), so the finished lesson content is preserved bit-for-bit — verified by
comparing a mid-film frame in the new cut against the original at the same
moment (0.00 difference, against a control that returns 9.86). Originals are
kept in `~/Movies/pre-intro-originals/`. One shared greeting take is reused
across all three, deliberately: three generations would be three subtly
different readings of the same words. Chapter timestamps shifted +17 s with a
new opening chapter, all four descriptions re-validated against their actual
durations.

## 2026-09-03c — Channel-level brand assets, and a visualiser that is not Pillow

Plugin **0.9.0**. A video series and a channel are not the same thing, so
`scripts/channel.py` renders the assets a channel needs and the per-video cards
in `brand.py` are left alone: the videos still say LESSONS, the channel says
AGENTIC. `brand.py` gained `--sub` for exactly that, defaulting to the old
string so every existing film renders byte-identically.

Three traps, each of which produced a wrong artefact before it produced a right
one:

**The avatar is a circle, at 88 px.** A wordmark is mud at that size, so the
avatar is a *mark* — the spectrum-bar motif, cyan at the edges resolving to
violet in the middle, which is the design language's colour for anything
AI-touched. `channel.py avatar` therefore writes circle-masked previews at 800
and 88 px alongside the file, because "looks fine at full size" is not evidence
about the size it is used at.

**Hand-placed layout is centred layout's convincing impostor.** The banner
lockup was left-aligned inside the 1546×423 safe area, which reads as balanced
on a 2560 px desktop banner and badly lopsided on mobile, which crops to the box
and nothing else. The lockup had the same bug worse: fixed at x=200 on a
1600 px canvas, its artwork ended at x=822 — a logo file half of which was
empty. Both now measure the text and centre the group.

**And a README claim that was simply false.** It described the lockup as
transparent; the file was opaque RGB. Verified by reading the pixel, not by
reading the code that drew it. There is now a real RGBA variant, and the
knockout is checked by counting opaque pixels and their bounding box rather
than by sampling one point — the first probe sampled empty space and would have
passed a blank image.

**The trailer.** 72 s at 120 BPM in A minor: the same key and tempo as the
5-second sting, opening with the sting's own rising figure and closing on its
landing chord, so the channel loop sounds like the sting grew. Hand-written
notes through GM instruments; no generation model, which is what the channel
claims about itself and therefore had to be true of its own trailer.

Three variants ship, differing on **one axis only** — energy — with identical
harmony and melody, gain-matched to within 0.2 LUFS so the choice is musical
rather than a loudness preference. Master chain is a gain insert (the fader
stops at +6 dB and GM material needed +14 to +16) into a true-peak limiter, with
the gain converged by measure-correct-repeat: a single computed gain cannot land
it, because the limiter sits after the gain and the relationship is not linear.

⚠️ **The limiter ceiling is −1.6 dBFS, not −1.0, and that is deliberate.** AAC
overshoots: a −1.0 dBTP wav measured −0.5 dBTP once encoded. Limiting to −1.6
lands the *delivered* mp4 on −1.3. Trimming the wav afterwards was tried first
and cost 0.7 dB of loudness for the same peak.

Finally, `showfreqs` was tried for the visualiser and rejected — `mode=bar`
fills solid from the baseline with no gaps, so it cannot draw the logo's shape.
The bars are Pillow, but the glow layer is rendered at 1/3 scale and upscaled,
which is what makes 2160 frames take 75 seconds instead of ten minutes.

## 2026-09-03b — A brand for the lessons, and a lesson that argued with me

Plugin **0.8.0**. `scripts/brand.py` renders the two pieces of furniture every
video now carries: a 5-second opening title whose spectrum bars are driven by
the actual sting, and a closing copyright card. Both go through the same encoder
flags as the film body, and `assemble.py` gained `--intro` / `--outro` which
*refuse* a card whose streams do not match — `concat -c copy` does not error on a
mismatch, it just glitches on playback.

The sting is hand-written in DAW Pro at 120 BPM so that 5.0 s is exactly 10
beats, landing on beat 7 where the wordmark resolves. It is gain-matched with a
measured static gain, not `loudnorm`, which came out 3.7 dB hot on something
that short and dynamic.

Two drawing lessons are written down in `BRAND.md`: this ffmpeg has no
`drawtext` at all (no libfreetype — the filter is simply absent and text
silently never appears), and glow has to be a separate blurred layer, because
blurring the finished frame turns a white wordmark grey.

**Lesson 3 is the interesting one — it took three tries to measure honestly.**

The first metric, low-mid share of the mix bus, went UP when the mix got better:
moving the pad up an octave moves it *into* 150–500 Hz while moving it out of the
bass's way. A mix-bus band share cannot see a collision at all. The second
measured the parts separately — share of the pad's own energy below 250 Hz —
which sees the collision but draws the line in the wrong place: the moved pad's
bottom voice lands at 196–247 Hz, still under it, so the octave move scored a
feeble −4.2 dB and the textbook carve appeared to make things *worse*.

The line belongs to the bass, and the bass was never asked. Measured: it keeps
92.9% of its energy below 150 Hz and half below 65 Hz. On that line the lesson
resolves, and it now teaches the second mistake as well as the answer — every
fix is scored twice, by share *and* by absolute decibels removed from the zone,
because a share improves when you remove the right thing and worsens when you
remove the wrong one. The 250 Hz carve does exactly that: it clears 1.4 dB from
the collision zone, takes 3.6 dB of body out of the pad, and its share climbs
from 66% to 76%. A bell at 250 Hz with a Q of 1.2 reaches ~167–375 Hz, and 77%
of this pad is below it. Moving the part clears 58 dB and makes the pad 4 dB
*louder* in its own range.

⚠️ **And the numbers that fed the first cut of the narration were contaminated by
a bug worth generalising.** The teardown between states read
`track.effects ?? []`, but `project.overview` exposes a track's insert chain
under **`fx`**. The list was always empty, the removal loop ran zero times, every
call reported success, and EQs *accumulated* across states — three of six were
wrong. It was caught by looking at a captured screenshot and seeing three EQ
chips where there should have been one. **A `?? []` fallback on a key you have
not verified is not a safe default; it is a loop that silently does not run.**

## 2026-09-03 — Tools for filming the DAW, and two lessons made with them

Making the demo films turned out to need a lot of small, hard-won knowledge that
lived nowhere. It now ships as part of the plugin (**0.7.0**).

Two new skills. **`ui-capture`** drives DAW Pro's `debug.*` surface — the one
that is *not* reachable from MCP and is the only way to open a panel, move a
control, or take a screenshot. It carries a `panels.mjs` registry that can
photograph any panel by name, and a `pair()` helper that shoots the same knob
before and after a change and then puts it back, proving the restore by
re-reading rather than assuming it. **`demo-film`** covers narration and
assembly: a local text-to-speech voice, and an assembler that turns stills,
rendered loops and real transport footage into a narrated film.

The traps in both are written down with the session that paid for them, because
each one *looks like success*: a modal you forgot to close photographs over your
subject, the instrument picker creates a track when given no valid id, and
`debug.musicalTyping` returns after the first key it recognises, so two settings
in one call silently applies one.

The narration gate is the sharpest of these. Level, pace and spectrum checks all
pass happily on speech that says the *wrong words* — one earlier film had lines
that transcribed as nothing but "Thank you," and every meter said it was fine.
So every take is now transcribed and compared against its script. That gate had
a bug of its own worth knowing about generally: `difflib`'s `autojunk` heuristic
discards common elements in any sequence over 200 long, and narration lines are
600–1000 *characters* — so character-level matching threw away the spaces and
scored a **verbatim** take at 0.17. Compared as word lists with `autojunk=False`
the same take scores 0.91.

There is also a new **`demo-director`** agent that holds both skills, and a
standalone `tools/voice-video-kit/` for using the pipeline outside this repo.
The model weights are not vendored — eight gigabytes of public builds do not
belong in a git repository, so the installer fetches them.

## 2026-08-31 — Knobs for the slur, and a slide that respects distance

The slurring added earlier today could only be reached by asking an AI agent.
It now has controls in the Sampler card: three buttons that say what they do
rather than what they are called — **Chords**, **One Note**, **Slurred** — and
a **Glide** knob beside them.

Two details in that knob were deliberate. Turned fully down it reads `OFF`, not
`0.0 ms`, because "no glide at all" and "a very fast glide" are different things
and should not look the same. And glide does nothing at all on a Chords patch —
so rather than greying the knob out, it stays usable, its markings dim, and a
line underneath says `CHORDS ignores Glide — use One Note or Slurred.` You can
still dial a glide in first and switch the mode after, which is the order most
people would try.

The slide itself also got smarter. Until now a glide took the same amount of
time no matter how far it had to travel, so a one-step slur crawled while a leap
of an octave was rushed through twelve times faster. There is now a second mode
where distance sets duration, the way a real player's slide behaves: short
intervals slide quickly, wide ones take their time. It is off by default, and
the reference is a whole tone — so a glide that sounded right on a stepwise line
sounds exactly the same after switching, and only changes where it should, on
the leaps.

One honest trade: the Sampler card's fixed area grew by 57 points to hold the
new controls, so when the per-zone inspector is open the zone list below shows
six rows where it used to show eight. Nothing changed with no zone selected.

## 2026-08-31 — A wind line that no longer re-tongues every note

Play a sax or flute part in the built-in Sampler and every note used to start
over: a fresh breath, a fresh attack, on all of them. That is what makes a
melody sound typed in rather than played. Overlapping the notes only hid the
problem — the new attack was still there, tucked under the previous note's
tail — and the mono voice mode added earlier did not remove it either. Mono
decided which note wins; it still re-struck the reed on the second one.

The Sampler now has a third voice mode, `legato`. Under it a note arriving
while another is still sounding does not start a new voice at all: the voice
already playing simply changes pitch. Its envelope carries straight on from
wherever it was. There is no second attack, because there is no second note —
which is what a slur actually is. Play a note with nothing sounding and it
attacks normally, so phrasing still reads.

Alongside it, `glideTime` is portamento: instead of stepping to the new pitch,
the voice slides, over anything from an imperceptible smear to four seconds.
The slide is even across the interval — a semitone takes as long in the low
register as the high — and it works in mono as well, where the note re-attacks
but its pitch still slides in from the note before.

One honest limit: a slurred voice keeps playing the sample it started on, so a
very wide slur drifts in timbre as it goes. That is the same trade every
hardware sampler makes, and it is the price of the sound being continuous —
switching samples mid-slide would put a seam in the middle of the slur.

Both are off by default: existing projects render byte-for-byte identically,
verified by hash before and after.

## 2026-08-31 — Four Sampler settings did not survive being saved. Now they do.

Set a Sampler so its notes fade, save the project, reopen it — and the notes
held forever again. The setting was simply gone. The same was true of the
instrument's pitch-bend range and of its mono/poly voice mode: you could set all
four, hear all four, and lose all four the moment you closed the song.

The cause was one list. A project file records a Sampler's settings by name, and
these four names had never been added to it, so they were written nowhere and
quietly reset to their defaults on open. Everything else about the instrument —
its samples, gain, attack, release, expression settings — was recorded properly,
which is why the loss was easy to miss: the patch came back looking almost
right.

**Why this mattered more than a missing checkbox.** With no decay and no sustain
recorded, a note goes back to holding at full volume for as long as the pedal is
down — which is exactly the complaint fixed earlier the same day, below. The fix
arrived intact and a save undid it.

All four are now written into the project and read back, and we checked it by
sound rather than by reading the setting back afterwards: a saved-and-reopened
fading patch is measured falling to silence, a saved-and-reopened octave bend is
measured landing on the octave, and a saved-and-reopened mono line is measured
cutting the note it replaces.

**Songs you have already saved open exactly as they did before.** A Sampler with
none of these four set writes no new information at all, and a file that never
carried them still opens with the settings it always had — a whole-tone bend
range, poly voices, and a note that holds. And if a future version saves a voice
mode this one has never heard of, the song still opens; the unknown setting is
ignored rather than refusing the whole file.

## 2026-08-31 — Piano notes fade under the pedal. Organ notes do not.

Hold the sustain pedal and play a piano note. It should ring, bloom, and die
away — that is what a piano does, because the pedal only stops the dampers
falling; it does not keep feeding the strings. Ours kept the note going at full
volume, forever. A player noticed and asked whether they were wrong. They were
not.

**What we changed, and what we deliberately did not.** The fix is not "make
notes fade". An organ, a string pad and a warm synth pad genuinely do hold for
as long as you keep the pedal down, and making those fade would have been a
worse bug than the one we started with. **The instrument decides, not the
pedal.** So the pedal's job stays exactly what it was — it holds the note off
its release — and the fading is now the instrument's own business.

**Sounds you pick from a sound bank were already right.** A real grand piano
program carries its own fade and always has; we measured it dying to silence in
about fifteen seconds with the pedal held, while a church organ from the same
bank sat perfectly level for the same fifteen seconds. Both correct.

**The built-in Sampler could not fade at all.** It had knobs for how fast a note
starts and how fast it stops after you let go, but nothing for what happens in
between while you are still holding the key. If you loaded a piano library with
sixty samples in it, the only way to make it fade was to edit all sixty. Now
there are two instrument-wide controls — **Decay** (how long the note takes to
drop) and **Sustain** (the level it settles at) — and any individual sample can
still overrule them. Leave them alone and nothing you have already made changes
by so much as a sample.

**And the songs we build for you now use the right instruments.** Ask for a
starter song in any of the fourteen styles and, until now, every part came out
as the same buzzy synth — the one labelled "Piano", the one labelled "Organ",
even the one labelled "Drums". Now a piano part is a piano, an organ part is an
organ, drums are a drum kit, and a bass is a bass. Which means the piano fades
and the organ holds, without you setting anything. Parts genuinely meant to be
a synth — the ones labelled "Synth" and "Lead" — are left as the built-in
synth on purpose.

**Projects you already saved are untouched.** We checked this specifically
rather than assuming it: the new sounds are written into songs as they are
created, so nothing reaches back into work already on your disk.

**Correction, later the same day:** the two new controls were not being written
into your project file, so they reset every time you reopened the song. Fixed —
see "Four Sampler settings did not survive being saved" at the top.

## 2026-08-31 — Build a song by stacking loops, without ever stopping the music

Play a chord part. While it keeps looping, arm a different track, switch to a
bass sound, and play the bass part over the top. Then a shaker. The music never
stops, and you never touch the stop button. That is live looping — the way
The Kiffness builds a track in front of a camera — and DAW Pro now does it.

**How to use it.** Press play, then open a loop session and say how long the
loop is: **four bars, two bars, whatever you like**. (Or say nothing, play your
first part, and press finish — the loop becomes as long as what you just played,
rounded to whole bars so it can never end up slightly off.) Arm a track and a
light starts **flashing amber**: the recording has not begun yet. It begins at
the **start of the next time round the loop**, so what you play lands in time
with what is already going — on a four-bar loop that can be up to four bars of
flashing, which is the loop waiting for you, not the app ignoring you. (Prefer
to come in sooner? Choose bar timing and it starts on the next bar line
instead.) The light goes **solid amber** while you are recording and **cyan**
once the layer is down and playing. Arm the next track and do it again.

**The bit that matters most: a bad layer goes away with one press, and the
music does not stop.** Play something wrong, press undo-layer, and it is gone
while everything else keeps looping — press it again to take back the one before
that. This is a separate control from the usual undo on purpose: the ordinary
undo would take back whatever you did last, which mid-performance might be a
volume change rather than the layer you want rid of.

**You never have to read anything while playing.** The strip beside the
transport is lights, not numbers: amber means "this one is being recorded into",
cyan means "this one is sounding", and each light blinks in time with your loop
rather than to some unrelated ticking. Each light is captioned with the end of
its track's name — `…Chords`, `…Bass` — because that is the part that tells them
apart.

**What you end up with is a real song, not a performance that vanishes.** Each
layer is an ordinary clip on an ordinary track, repeated along the timeline, so
you can close the loop session and then edit it, mix it, bounce it or export it
like anything else you have made.

Two honest limits. This records **instrument layers** — parts you play — not
microphone or guitar layers; those repeat differently and are still to come. And
if you arm a layer in the last split-second before the bar line, it waits for the
*next* bar rather than starting late and losing your first chord — the flashing
light is telling you it heard you.

## 2026-08-31 — A sustain pedal, on the Tab key

Play the on-screen keys and a note stopped the instant you let go. That is what
a real piano does too — a felt damper drops onto the string the moment the key
comes up. What you were remembering is the pedal under the pianist's right foot,
which lifts every damper off the strings so notes keep ringing while both hands
move on to the next chord.

**Press Tab.** A green **⇥ SUSTAIN** light comes on beside MUSICAL TYPING, and
from then on the notes you play keep sounding after you let go of the keys — so
you can move your hand, play the next chord, and hear the two blend the way a
piano blends them. Press Tab again and everything the pedal was holding
releases; anything you are still physically holding down keeps playing.

It is a **latch**, not a hold: press once for on, once for off, rather than
keeping a finger on Tab. Sustain exists precisely because a player has no spare
finger — that is why it lives under a foot on a real piano — and a computer
keyboard has no foot. The cost, said plainly: there is no half-pedalling and no
quick flutter, so re-pedalling on a chord change is two presses instead of one
foot movement. If you want that, a real MIDI pedal plugged into the Mac has
always worked and still does.

You can also click the SUSTAIN light itself, which matters because Tab normally
moves between text boxes. It only becomes the pedal while Musical Typing is on
and you are not typing into anything — in a name field, in the Copilot box, in
Settings, or with the mode off, Tab still moves the cursor exactly as before.

**It records.** With a take rolling on an armed instrument track, your pedalling
is written into the clip as a real sustain lane, so playing the take back
sustains the same notes in the same places. The pedal cannot be left stranded
either: it lifts when the take ends, when you hit panic, when you switch off
Musical Typing, and when the window loses focus — a pedal stuck down is a drone
with no visible cause, and that is the one thing it must never be.

An agent can work the same pedal through the new `play_sustain` tool.

**Fixed along the way, and it would have bitten you:** a note held only by the
pedal used to go silent after exactly eight seconds with the transport stopped.
The instruments were sustaining correctly the whole time; the audio engine had
stopped asking them to. It is fixed, and measured on all three instrument
kinds — the built-in synth, the built-in sampler, and the downloaded sound
banks.

## 2026-08-30 — One button gets you a whole orchestra, and it tells you the truth about the download

A stock Mac ships exactly one sound bank with exactly one drum kit. Ask for
brushes and the answer used to be "you can't" — not "here is how," just no.

Now there is a **Download** button in the instrument picker. It offers
**MuseScore General**: 128 instruments and around fifteen drum kits, brushes
among them, free, MIT-licensed, roughly 216 MB. The size and the licence are on
screen *before* you press anything, because it is your bandwidth, your disk, and
somebody else's work.

While it runs, the picker says what is happening in words — "Downloading 88 MB
of 216 MB…", then "Checking the download…", then "Adding MuseScore General to
your instruments…" — with a bar that only moves during the actual transfer, and
a **Cancel** that works. Cancelling says "Stopping…" until the download has
really stopped, and then "Nothing was added," because the partial file is gone
by then and not a moment earlier.

**The part that matters most is what "finished" means.** A half-downloaded
sound bank that reports success is the worst possible outcome here: an SF2's
instrument names live *after* its sample data, so a transfer that dies two
thirds of the way through leaves a file that opens, loads, and shows you 128
instruments called "Program 0" through "Program 127". It looks fine. It is not.

So a download is only finished when four separate things agree: the server's
advertised size matches what we expect (checked in the first second, not after
216 MB), the bytes on disk are the right *number* of bytes, they hash to the
right fingerprint, and — the one that catches the case the others miss — the
installed file gives up real instrument names when asked. Any of those failing
deletes the file and tells you plainly what happened. Nothing partly downloaded
is ever left where it can be mistaken for a working bank.

Agents get the same four operations over the control protocol
(`instrument.listDownloadableSoundBanks` / `downloadSoundBank` /
`soundBankDownloadStatus` / `cancelSoundBankDownload`) and as MCP tools. The
listing carries the licence and the copyright line, so an assistant can tell you
what it is about to put on your machine.

One piece of honesty about the fingerprint: nobody publishes a checksum for this
file, so DAW Pro downloaded it once, hashed it, and pinned what it saw. That
protects you from a corrupted or truncated download. It is **not** a signature
and does not prove where the bytes came from — and the app's own documentation
says so rather than implying otherwise.

## 2026-08-30 — Playbox: the AI shows you what to play, you play it, and it is yours

Ask for a set of chords and the keyboard lights up with them. Then **you** play
them. That is the whole feature, and the order matters: the AI writes the
invitation, you write the performance. The take is a real recording of you
pressing keys, captured the same way any other take is. Nothing plays a note on
your behalf.

Turn on **CHORDS** in the keyboard strip and press **NEW LIGHTS**. You get a
progression that fits the key, tempo and section you are already working in —
not a generic one — and the keys that play it light up.

**You choose when the lights move on, because the three ways of using this are
three different things.**

- **WHEN I PLAY IT** — the outline waits until you play the chord it is showing
  you. Nothing is refused, nothing is rushed. This is for learning a part.
- **ON THE BEAT** — the outline moves with the click, one chord per bar, and you
  keep up. This is for performing one.
- **AHEAD OF ME** — the outline moves on every chord you play, so the timing is
  entirely yours. This is for writing with it, and it is the default.

**You can now see what is coming, not just what is next.** The chord to play is
outlined; the three after it carry a bar underneath, widest first. That is also
the fix for something that was genuinely confusing: Four Chords and '50s Doo-Wop
use the same four chords in a different order and both start on the same one, so
until you played a note they looked identical. Now they do not.

**It works without an API key, and it tells you which one you got.** With a key
configured, a model writes the progression and the strip says so in violet.
Without one — or if the model returns something unusable — the app varies one of
its own built-in progressions instead, and says *that* instead. "The AI wrote
this" and "we picked a stock progression" are different claims, and only one of
them is ever true at a time.

Chords only for now. Melody needs a different kind of light and a wider
keyboard, so it is not half-built here.

For agents: `playbox_generate` returns the progression as scale degrees, and
defaults its tempo and section from the open project. It lights nothing and
plays nothing. **Please do not follow it with `clip_set_notes` unless you were
asked to** — writing the part for the user is precisely the thing this feature
exists not to do.

## 2026-08-30 — One key, one chord: play real harmony without knowing how to voice one

Musical Typing gave you one key, one note. That is enough to pick out a melody
and not much else — if you cannot voice a chord, you still cannot play a song.

Turn on **CHORDS** in the keyboard strip and every key becomes a whole chord in
a key you pick. `A` is the key's home chord, `S` is the second, `F` and `G` are
the two that surround it, `H` is its sad relative. The letters are printed on
the keys, the chord names are printed under them, and the Roman numerals are
printed under those — so you can learn what you are playing while you play it.

**Pick a named progression and the keys light up in order.** Four Chords, '50s
Doo-Wop, Pop-Punk, the jazz ii-V-I, a 12-bar blues, minor rock. Press 1, then 2,
then 3, then 4, and you have played a song's worth of harmony with four
keystrokes. **The unlit keys still work.** Nothing is disabled, nothing is
locked; the lights are a suggestion you can walk away from mid-bar, and the
moment you do, the rest of the key is right there.

**The chords are voiced, not stacked.** This is the part that decides whether it
sounds like music or like someone leaning on a keyboard. Each chord is placed to
move as little as possible from the one before it, so shared notes simply keep
ringing instead of being re-struck, and nothing leaps an octave between changes.
A bass note sits low, separate from the chord above it, the way two hands sit on
a piano. Close intervals are kept out of the bottom of the range where they stop
sounding like harmony and start sounding like mud.

**And it changes with the instrument.** Piano splits a low bass note from a
compact chord. Pad and Strings spread wide and add sevenths. Guitar stays in
root position where a guitar actually lives. **Bass plays one note — the root —
and that is on purpose:** handing a bass part a whole stacked chord is the most
common way an auto-harmonised arrangement goes wrong.

Everything you play this way is recorded exactly as before. Arm an instrument
track, hit record, follow the lights, and the take is a real MIDI clip you own.

For agents: `chord_voice` returns the same voicings as a pitch array, so
AI-authored chord parts get the same voice leading the button does. It is
read-only — it works out notes, it does not play them.

## 2026-08-29 — You can play the DAW without owning a keyboard, and it records

Until now, playing a note in real time required a hardware MIDI controller. If
you did not own one, the entire live path was closed to you: a full CoreMIDI
input stack shipped inside the app — a real-time-safe thru ring, a capture
session, punch, count-in, take comping — and there was no door into any of it.
Recording a performance was not slow or awkward. It was unreachable.

There is a door now, and it is your computer keyboard. Turn on Musical Typing
and the middle two rows of the keyboard become a piano: the home row is the
white keys, the row above it the black ones, `Z` and `X` move an octave, `C` and
`V` change how hard you are playing. There is an on-screen keyboard too, and it
is polyphonic — it lights up for what you play, whichever way you played it. The
layout is the one Logic and Ableton share, so if you have used either, you
already know it. Keys are matched by physical position rather than by letter, so
the shape stays correct on a keyboard that is not American.

It is a mode you switch on and off, never an ambient grab at your keystrokes.
While it is on, typing into a rename field still types. Releasing a note is
allowed unconditionally, even mid-refusal — the one asymmetry that guarantees a
key can never get stuck down.

And what you play is recorded. Arm a track, hit record, play, and the notes are
in the take, in a clip, with real lengths — through the same capture session
hardware MIDI has always used, so count-in, punch and take numbering all work
without knowing anything new happened. A held note during a bounce is no longer
a thing you have to think about.

The one thing to know: a note played in the first fraction of a second after you
press record does not make it in. A take's anchor is scheduled slightly ahead of
the button, and notes struck before it are discarded — the same rule that makes
count-in work. Hit record, take a breath, then play. A proper count-in cue for
this is still to come.

Separately, and found on the way: a note held in the piano roll's keyboard
gutter used to keep ringing forever if you switched to another app. The app's
own code claimed it silenced audition when it lost focus. It never had. It does
now.

Honest limit, stated plainly: no automated check in this project can press a key
or look at a screen, so the parts of this that were proven are the routing, the
note bookkeeping, and — end to end, against a real running app — that a played
note lands in a take and that an un-armed track records nothing. Whether it
*feels* right to play has not been tested by anyone, because nobody involved in
building it has hands.

## 2026-08-29 — Importing a file no longer deletes the one it lands on

Bringing an audio file onto a track that already has a clip at that beat used to
delete the clip that was there. Not trim it, not warn about it, not ask — delete
it, and hand you back a new id as though nothing had happened. Two imports at
beat 0 left one clip. Both calls reported success.

It mattered most exactly where you would hit it. Sampling your own output is
central to flipping a record: print a section, import the print, chop the print,
print again. Importing pass after pass onto one track is the workflow, and the
natural way to write it — reuse `atBeat: 0` each time — quietly destroyed the
previous pass. The skill that teaches the loop had to carry a warning telling you
to count your clips afterwards.

An import now refuses to land on top of something. It names the clip that is in
the way, and it tells you a beat that is free — nothing is trimmed, nothing is
deleted, nothing is journaled, so the refusal costs you nothing to ignore. The
cheapest way past it is to leave `atBeat` out entirely, which appends after
everything on the track and can never collide.

If you did mean to replace what was there, `overwrite: true` still does the old
thing: clips underneath are trimmed, and ones your file covers completely are
removed. What is new is that it says so. `trimmedClipIDs` and `removedClipIDs`
come back naming exactly what went, and those two arrays are in every import
response, empty on the ordinary path — so a caller checking what happened never
has to tell an absent field from an empty one.

**What this does and does not cover.** It is the import agents and the control
protocol use — `clip_add_audio` / `clip.addAudio`. Importing from inside the app
takes a different path: File - Import Audio always makes new tracks, so it never
had this problem, but *dropping* a file onto a lane region that already has a
clip there still resolves the overlap silently, and that is filed separately
rather than quietly folded in here.

Two details worth stating, because both are the kind of thing that gets
"simplified" later. The refusal asks the overlap policy itself what a placement
would cost rather than testing whether the rectangles intersect: take stacks
legally overlap and lose nothing to an import, so an intersection test would have
started refusing calls that were never destroying anything. And this is
deliberately not what dragging a clip does — a drag still trims what it lands on,
because a drag's footprint is a clip you can see, while an import's length comes
from the file's duration at the current tempo. `atBeat` alone never told you what
it was about to cover, so it was never something you could have consented to.

## 2026-08-29 — Convert the clips you picked, and stop converting the takes you trimmed away

Voice conversion now works on a **selection**. Pick the clips you want, convert, and you get a new track carrying a converted counterpart of each one, sitting at exactly the beats the originals sat at. Not one merged render — the same set of clips, so the arrangement you built survives the conversion. It is a plain audio track when it lands: no insert to add, none to remove, nothing wired back to the voice model. Every conversion makes its own new track, and one undo removes the whole set.

**And the thing it was quietly getting wrong.** Converting a clip used to send the voice engine that clip's *entire backing recording*. For the flow it was built for — a freshly imported full-length stem — that was the same thing, so nobody noticed. For the flow people actually have, it was not: comp a vocal, trim it to the four bars you want, convert, and the engine received the whole untrimmed take and handed back a clip of it, landed at your clip's start beat. Not an error, not a crash, not a missing feature. A plausible-looking answer that was the wrong audio.

Converting each clip separately dissolves that rather than patching it. What the engine now receives is an offline render of that one clip over exactly its own window — so the trim, the offset into the recording, the time-stretch and the pitch shift are all honoured because the render *is* the playback path. If you can hear it, that is what gets converted.

One judgment call worth stating, because it is the kind of thing someone will want to change later without knowing why it is the way it is. Time is baked; level is not. The trim, offset, stretch and pitch shift are rendered in, because they decide *which* audio the engine hears. Clip gain, fades and the gain envelope are deliberately left out of the render and carried onto the converted clip instead. Partly so the result stays editable — a fade you can still drag — and partly because a fade-in baked into the source hands a pitch estimator a few hundred milliseconds of silence to find a voice in, and a clip pulled 12 dB down hands it something close to nothing.

The refusals are as deliberate as the behaviour. If two clips you selected overlap in beats, it says so and names both, because one track cannot hold them both at their own beats and silently trimming one would break the only promise the feature makes. If conversion fails part-way through a set of eight, nothing lands at all — no half-arrangement, no track that looks finished and is not. Everything is checked before the first render, so a refusal costs nothing.

Agents get `vc_convert_clips` for the set and keep `vc_convert_vocals` for a single clip, unchanged in name and shape — though the single-clip form now converts the clip's own window too, since that defect was never specific to sets. The bridge budgets one conversion's worth of time per clip you passed, rather than guessing a number that would time out a legitimate ten-clip run.

The proof is in three places, and the one that matters most is a real render: a ramp file with known values at known frames, a clip trimmed half a second in, and an assertion that the extracted audio matches the source **bit for bit at the offset position** — alongside a control asserting it is *not* the head of the file, which is exactly what the old behaviour produced. Zeroing the offset in the extraction flips both together, which is how we know the test is looking at the right thing.

## 2026-08-29 — Sixty-four pads out of one record, and the 23 milliseconds nobody could hear were missing

Two fixes underneath the sampler. Neither is a feature, and both had to land before chopping a whole record onto pads was something you could actually do rather than something the tool would let you attempt.

**One file, loaded once.** A sampler zone used to load its audio privately: open the file, allocate the whole thing, per channel, per zone. That is invisible and fine at eight zones and ruinous at sixty-four, because chopping a record means sixty-four zones pointing at *the same file* — and the sampler was keeping sixty-four copies of it. A four-minute stereo 44.1 kHz rip is about 81 MB in memory; sixty-four pads of it came to roughly **5 GB**. Nothing warned you, because nothing was wrong in the sense the code understood — it just allocated, and kept allocating.

Zones now share one buffer per source file. Sixty-four pads of a record cost what one pad costs. Measured on a sixteen-zone chop of a single file, the load dropped from 2,883,584 bytes to 180,224 — exactly the sixteen-to-one you would predict, which is the point of quoting it. The test that pins this also loads eight zones from **eight different** files and asserts that memory stays at eight copies: sharing that ignored which file a zone actually pointed at would pass a naive dedup test and produce silence-or-worse in real use, so the wrong answer is held permanently in view next to the right one.

**And the end of every mono sample was being dropped.** `AVAudioFile.read(into:)` does not necessarily deliver the frames you asked for in one call on a mono file — it stops on an internal boundary and reports the short count, which the sampler was believing. Up to **1,023 frames, about 23 ms at 44.1 kHz**, vanished off the end of every mono zone. Stereo files were never affected, which is exactly why this survived: every stereo test passed, and stereo is what a test author reaches for.

At a full sample length that is an inaudibly clipped tail. On a *chop* it is not, because a chop is short — a 100 ms hi-hat losing 23 ms has lost a quarter of itself, and the shorter the slice the larger the fraction. This is the kind of defect that reads as "the pads sound a bit dead" rather than as a bug.

The fix reads in a loop until the file is exhausted. Worth naming the trap, because the obvious version of that loop is wrong in a way that destroys audio rather than merely failing: each `read(into:)` **rewrites the buffer from frame 0 and resets its frame count**, so "keep reading until the count reaches the file length" never terminates usefully and leaves the count at zero — and a zero-length zone is not a quiet zone, it is a silent one. The correct loop advances a write offset into the buffer itself. Both the loss and the fix are pinned by a test that reads mono files at lengths on either side of the boundary, with stereo alongside as the control that must not change.

DAW Pro could already cut an audio clip into separate slices sitting exactly where they were, in one undo step, with clean joins. Nobody could tell, because the way to ask for it was `clip_quantize_audio` with `strength: 0` — a quantize tool, set to quantize by nothing. If you were looking for a way to chop a break into pieces you could rearrange, that is not a tool you would have opened.

Nothing about the cutting has changed. The tool now says what it does: with `strength: 0` this is a **pure chop**, and the description leads with that instead of burying it behind the grid maths. That is the whole of the discoverability fix, and it was deliberately bought at description cost rather than by adding a second `chop` command — two commands doing one thing is a bill you pay forever.

Worth knowing why the chop is clean, because it is a property rather than a promise: slice *i* ends at the exact sample where slice *i+1* begins, so playing them in order **is** the original waveform. There is nothing to crossfade and nothing to click. (Cutting a record into *sampler pads* is a different problem — a pad played alone starts and stops at arbitrary sample values — which is why `clip_slice_to_sampler` snaps its cuts and this does not need to.)

**The new part is `divisions`.** Ask for `divisions: 8` and the clip is cut into eight equal parts instead of at its transients. This is the fallback for material the detector has no useful opinion about: drones, ambient beds, sustained pads, and loops that are already perfectly quantized and have no attacks to find. It runs no detection at all, which also means it works on a clip whose transients would have come out wrong, and it is fast.

`divisions` chooses where the clip is **cut**; the grid settings still choose where each slice **moves to**. They compose — `divisions: 4` with `strength: 1` cuts into quarters and snaps each one to the grid. And since `gridBeats` means nothing when nothing is being nudged, you may now omit it entirely at `strength: 0`. Above `strength: 0` it is still required, exactly as before.

Two things it refuses rather than fudges. Sending `sensitivity` together with `divisions` is an error, not a silent no-op — sensitivity is the detector's knob and no detector is running, so a caller who sent it would have received a plausible-looking chop that ignored them. And asking for more divisions than the clip's length allows is refused with the arithmetic spelled out (how long the window is, how thin each part would be, how many parts would fit) instead of quietly returning fewer pieces than you asked for.

## 2026-08-29 — The twelve-bit sound, and why it is not filtered

A new insert effect, **Bit Crusher**, reduces bit depth and sampling rate — the lo-fi character of a 1980s sampling drum machine, the sound a chopped break has on a record you already know.

It starts on the E-mu SP-1200: **12 bits at 26,040 Hz**. Those are that machine's real numbers, not a flavour of them. Set `downsampleHz` to 40,000 and you have the Akai MPC60 instead, which is why MPC60 chops read as cleaner than SP-1200 chops of the same era.

**The two switches that look wrong are the point of the effect, and they ship OFF.** `antiAlias` and `dither` both default to 0. A bit-crusher that filters politely and dithers away the quantization noise sounds clean-but-crunchy; it does not sound gritty, and it does not sound like the record. The reason is specific and worth knowing rather than obeying: the SP-1200's signature comes from its converter *omitting* the reconstruction filter, so everything above the reduced Nyquist frequency images back down into the audible band. That folding is not a defect being tolerated — it is the character. Turn `antiAlias: 1` on when someone asks for a tamer, modern crush, and `dither: 1` on when you are reducing depth for delivery rather than for sound.

What `bits` does is exact rather than approximate: at `bits: N` the output takes exactly 2^N distinct levels, the code range of a real N-bit converter, and the test suite counts them on a rendered ramp instead of trusting the setting. `downsampleHz` holds each captured sample for the right number of frames — at 8 kHz into a 48 kHz project, every value repeats exactly six times, and at the 26,040 Hz default the runs are a measured mix of ones and twos because the ratio is 1.8433 and not an integer. That is why it is built on a fractional accumulator: an effect that rounded the rate to something divisible would quietly be a different machine, and one that restarted its count every audio block would sound different depending on your buffer size.

`mix` blends the crushed signal against your untouched input, so you can put a little grit under an intact transient; at `mix: 0` the effect is a bit-exact bypass. It adds no latency, and it is available on tracks, buses, and the master chain.

Two honest limits. `downsampleHz` tops out at 48,000, so in a project running at 88.2 or 96 kHz even the maximum setting still halves the rate — the effect is never transparent there, and you should bypass or remove it rather than turn it up. And a project saved with a Bit Crusher **still opens in an older build of DAW Pro, just without the effect**: the insert is an unknown kind to that build, so it is dropped with a warning and the track plays uncrushed rather than the file being refused. The thing to watch is what happens next — save from that older build and the insert is gone for good, because it was never in that build's model to write back. Projects without one are unaffected.

## 2026-08-29 — Play a pad backwards, and let one pad cut another off

Two small switches on a sampler zone, both of which a producer reaches for within about ten minutes of chopping their first break.

**`reverse`** plays a zone's span backwards. That is the reversed cymbal before a downbeat, the sucked-in vocal, the swell into a chorus. It costs nothing: the audio is read backwards where it already sits, never copied, so a reversed pad uses exactly as much memory as a forward one and a whole record chopped across sixty-four pads still holds one copy of the file. Playing a reversed pad higher up the keyboard repitches it exactly as a forward pad would.

Two honest limits, stated rather than half-solved. A reversed zone **ignores loops** in this version — set both and it plays its span once, backwards, and tells you it dropped the loop. What a sustain loop means played backwards, and which end of it the crossfade belongs to, is a real question and this is not an answer to it. And `attack`/`release` are not swapped for you: they shape what you hear, so a short release still trims the tail of the reversed sound, which is what you wanted.

**`chokeGroup`** (0–63) is the open/closed hi-hat rule. Give every hat zone the same choke group and a new hat ends the one still ringing, while the kicks and snares in the same instrument stay fully polyphonic. It is also the switch that makes a re-chopped break sound tight instead of like the loose loop it came from, since slices stop ringing into each other. A choked note is not cut dead — it goes into its own release, so a pad with a long release chokes slowly; shorten that pad's release for a hard choke. Pads generated by `clip_slice_to_sampler` already carry a 10 ms release, so a chop chokes tight without being asked.

`chokeGroup` is a different field from `group`, and the difference matters: `group` decides *which* zone fires when a new note arrives (round-robin and alternate layers are built on it), while `chokeGroup` ends notes that are *already playing*. A zone can use both. Two zones layered by the same note never choke each other, and a note never chokes itself.

Both fields survive save and reload, both can be set on a whole keymap or patched onto one zone by id, and both are optional: a project that uses neither renders bit-for-bit identically to before — which is asserted, on a render containing a looping voice and a bent one, against a checksum taken before either feature was written.

## 2026-08-29 — Chop a record into pads, and get the groove back for free

Sampling a break has always been the same three moves: find the hits, cut between them, and put the pieces on pads you can play. DAW Pro could do the first two and had nowhere to put the pieces. Zones with frame spans existed; nothing populated a set of them from a list of slice points.

`clip_slice_to_sampler` does that in one call. Point it at an audio clip and it cuts at the transients — or at N equal parts, or on the musical grid — and builds one sampler pad per slice, all reading the same file, one per MIDI note from C1 up. Then it writes a MIDI clip that plays them back in the original order at the original times.

That last part is the point of the whole thing, and it is worth being precise about what it means: the reconstruction is **bit-exact**. Rendered side by side, the sampler track and the original clip measure the same level to 0.0 dB. You are not starting from an approximation of the record and hoping. You are starting from the record, expressed as pads, and every change you make from there is one you chose.

Getting that took two decisions that look like details and are not. Reconstruction notes fire at **velocity 127**, not at the detector's confidence in each hit — because a sampler pad's level is already the level of the audio inside it, and firing a quiet-looking hit at velocity 13 would put it 20 dB below its own recording. And when the tool makes a new track for you, the sampler's output gain is 1, not the usual 0.8, so nothing sits two decibels under the thing it is reproducing. Velocity still works normally for any new pattern you write; `velocityFromStrength` opts into the detector's dynamics if you want them.

The cuts themselves are snapped to the quietest nearby sample so a pad played alone does not click, and each pad reports how quiet its cut actually was — on a stereo record there is often no point where both channels cross zero at once, and the tool says so rather than implying a clean cut it did not find. Each pad also gets a 10 ms release, which is what actually fixes the click at the *end* of a slice.

Two things it refuses to do rather than do badly. A chop that would make more pads than you allowed, or run past MIDI note 127, is rejected outright with the arithmetic named — it never quietly keeps the first 32 and drops your last bar, because a chop missing its ending still looks like a successful chop. And a clip that is time-stretched or pitch-shifted is refused, because pads read the raw file: the pads would play the original and you would be listening to something else.

Afterwards, the pads are ordinary sampler zones. Widen one pad's key range to play it chromatically, retune another, set the sampler to mono for the classic choked-soul feel — all without resending the rest.

## 2026-08-28 — Changing a few notes no longer means resending all of them

Editing a MIDI clip's notes had exactly one door: send the clip's entire note array back, every note, whether it changed or not. Raising the velocity of 48 shaker hits meant reading and resubmitting all 907 notes in that clip. A legato pass that shortened 225 note lengths had to round-trip all 225. The cost scaled with the clip, not with the edit.

It also carried a quieter hazard. Reading a filtered slice of a clip's notes and writing it back as if it were the whole clip silently deleted everything the filter left out — a real trap, defended only by a warning in the tool's own description.

A new tool, `clip_patch_notes`, changes specific notes by id instead: pitch, velocity, start position, or length, on exactly the notes you name, leaving everything else in the clip untouched. It cannot add or remove a note under any input, so the deletion hazard above cannot happen through it at all — there is no path from calling it to a note disappearing. An id that isn't actually in the clip refuses the whole call and says which id, rather than doing nothing silently. One call is one undo step, whether it touches one note or a thousand.

The existing whole-array tool, `clip_set_notes`, is unchanged and still the right choice for adding, removing, or reordering notes, or rewriting a clip from scratch. The two tools' descriptions now point at each other, so the choice between them is a one-line read rather than a guess.

## 2026-08-28 — A mixing assistant now produces the signal it needs to measure

When a mixing assistant reads a mix's balance and loudness, it has to listen while the song plays. With the transport stopped, the analysis tool used to return -80 dB across the spectrum and a 0 Hz centroid — exactly what silence measures. That output looks entirely legitimate. An AI assistant would believe it, see "this mix is extremely quiet in every band," and make tonal corrections that were not needed, all without anything going wrong visibly. Silent wrong answers are worse than loud failures.

Now the tool refuses when the transport is stopped. It explains why — the bus is silent because nothing is playing — and what to do: start the song, let it run a moment, then measure again. It refuses only for a stopped transport. A mix that is genuinely quiet while playing, or a muted master, still returns a real reading. The tool never claims a cause it cannot establish.

The assistant now holds transport control. It can play, stop, and seek through a session. It still cannot arm a track or record — a live performance stays a human-at-the-instrument job — but it can produce the signal it needs to listen and measure. The change reaches you only after updating the installed plugin; it is not automatic.

## 2026-08-28 — One gain stage now reaches a streaming level, and a clamped value stops pretending

Sound-bank material is quiet. A solo General-MIDI piano part renders at about
-28 LUFS at velocity 100 and near -35 LUFS at velocity 64, so getting a mix from
there to a -14 LUFS streaming level takes +14 to +21 dB of makeup. The `gain`
insert stopped at +12.04 dB, so it took TWO of them chained together — which, as
the person who hit it put it, "reads like a workaround because it is one".

The gain insert's ceiling is now 16 linear, +24.08 dB, up from 4. That figure is
not a round number picked for looks: it is the smallest of the candidates that
covers the quietest ordinary case measured (a soft solo GM piano, +21.49 dB) with
a little spare. One insert now does what two used to.

Raising a ceiling is safe for work you already have — every gain you ever saved
was 4 or less and is still in range, so nothing moves and no automation point
re-clamps. Lowering one would not have been.

The headroom is real, not free. The gain stage is a plain multiply with no
protection of its own, so a big boost can drive a mix into clipping. Put a limiter
after it, and check the result with a loudness measurement rather than trusting
the multiplier. The tool descriptions now say exactly this instead of implying the
room is free.

**And the more important half.** Asking for more than the ceiling used to return
`ok` and a value you had not asked for, with nothing anywhere saying so — the same
shape of failure as a tool that looks like it worked. Raising the ceiling alone
would only have moved that silent lie to a new number. So the clamp now speaks:
`fx.setParam`, `fx.add`'s seeded parameters, and `mixer.setMasterVolume` return a
`warnings` sentence naming what you asked for, what was actually stored, and the
range. The key is absent when nothing was clamped, so seeing it at all means the
stored value is not the one you sent. Values still clamp rather than erroring —
that behaviour was already documented and callers depend on it.

One thing worth stating plainly, because it was reported the other way round: the
master fader and the gain insert do NOT disagree about out-of-range values at the
engine level. Both clamp. The refusal a caller sees above 2.0 comes from the MCP
tool's own schema, one layer above the app — `mixer.setMasterVolume` itself clamps
silently, which is exactly why it now warns too.

## 2026-08-28 — When you change an instrument, the app now says what your old data will do

Controller lanes — expression, mod wheel, sustain, pitch bend — are performance data
that rides alongside a clip's notes. Which of them actually SOUND depends entirely on
the instrument the track is using, and different instruments honour different sets.
That was already true and already documented. What was missing is that swapping the
instrument silently changes the answer for data you wrote earlier.

This bit someone hard. A composer drew expression lanes while the track was on the
built-in poly synth, which ignores expression entirely — so they were correct data that
did nothing. Later the track was given a sound bank, which honours everything. The
lanes woke up, and because expression rests at FULL when there is no lane at all,
values that look perfectly ordinary — peaking around 108, dipping to 42 — were a broad
volume cut. A finished, checked mix came back 1.25 LU quieter and nobody could see why.

Now changing a track's instrument tells you. If the track carries controller data whose
meaning just changed, the response says so in plain words: which controller, which
direction, and — for expression, channel volume and pan, the three whose rest value is
not zero — why that shows up as a level change rather than as shaping. It warns in both
directions, because data that STOPS working is the same surprise in reverse.

Two things it deliberately does not do. It never touches your lanes: they are correct
data, and quietly neutralising them would be a worse bug than the one being fixed. And
it stays quiet unless the change actually affects a lane you really wrote — switching
from the poly synth to a sound bank changes the answer for all 128 controllers, and a
warning that fires every single time is one nobody reads.

Alongside it, every instrument now reports which controllers it honours, so you can
check before you write rather than after you bounce. That answer depends on the
instrument's SETTINGS, not just its type — the sampler starts honouring the mod wheel
and breath controllers only once its expression depth is turned up.

Fixing this turned up a related bug of exactly the same shape. When the sampler's
brightness filter is switched on, it really does follow whichever controller you point
it at — but the app was still telling people such a lane "will not sound". It was
wrong, in the confident way that is worse than saying nothing. Sampler zones that
crossfade between soft and loud recordings had the same problem. Both now report
honestly.


## 2026-08-28 — The soundfont everyone recommends now actually plays

If you go looking for a free soundfont, you end up at MuseScore. It is the biggest
distribution channel there is, and what it hands you today is a `.sf3` — that is the
only format it ships. Until now DAW Pro could see that file and tell you, honestly,
that it could not play it. That was better than the silence it replaced, but it still
meant the one file a newcomer is most likely to have was the one file that did not work.

Now it works. Import a `.sf3` and it is converted to a real `.sf2` as it lands in your
library — everything downstream, from the program list to the sampler, is unchanged
because what arrives is an ordinary soundfont. MuseScore's own `FluidR3Mono_GM.sf3`
takes about six seconds and comes out with all 197 of its preset names intact.

Two things worth knowing before you do it. The conversion decompresses the audio, so a
24 MB download becomes roughly 220 MB in your library — that is the real size of the
sound, and the `.sf3` was simply a zipped version of it. And if any part of the file
cannot be read, the whole import fails and tells you so, rather than quietly giving you
a bank with silent gaps in it. A soundfont that loads and makes no sound is a worse
outcome than one that refuses, so it refuses.

Under the hood this needed a Vorbis decoder, which is the compressed-audio format
hiding inside every `.sf3`. macOS turns out to have one, but it is undocumented, it is
not present on every version we support, and — the deciding fact — it could not read 17
of the 1186 sounds in that MuseScore file. All 17 were the short single-cycle waveforms
that the classic synth patches are built from, so leaning on it would have shipped you a
soundfont where Square Lead, Saw Lead, Synth Bass and Synth Brass were silent while
every other instrument sounded fine. We carry our own decoder instead, and the test that
guards this plays those patches and listens.

## 2026-08-28 — One bar, repeated, and the undo step that almost joined a stranger's edit

An AI composing agent writing a twelve-bar blues has one bar of rhythm and eleven more
bars that are just that bar again. Writing it out in full costs real money and real
context: expressing that one pattern across all twelve bars was measured at roughly
30 KB of JSON, crossing the wire twice — once to generate the notes, once to send them
back to the app. A different, denser piece with 5,248 notes would have cost over
330 KB for information that is, in truth, one bar and a repeat count.

`clip.repeatNotes` is the fix: name a source (a beat window, or an explicit set of note
ids), a period, and a count, and the clip grows by that many copies without a single
note crossing the wire in either direction. The response reports counts — how many
copies, how many notes were added, whether the clip grew to fit them, whether the
copies span a meter change, and how many new notes land past the clip's end — and never
the notes themselves.

The obvious way to build it is also the wrong way, and the wrong way passes its own
test. Read the existing notes, append the copies in memory, write the result back
through the same path every other note edit already uses — that path journals its undo
entry under a key scoped to the clip, and the undo journal folds two edits sharing a key
if they land inside an 800ms window. A repeat issued shortly after any other edit to
that clip — which, for an agent iterating on a pattern, is the common case, not the rare
one — would silently merge into that edit's undo step. Undo once and both the repeat and
whatever came before it are gone together, with no error and no warning.

The test that catches this has to be about timing, not about notes: edit a clip, repeat
inside the same clip within the coalescing window, and assert that one undo removes only
the repeat. It passed against the real implementation, then was run again on purpose
against the naive shape — routed through the keyed path instead — and went red exactly
as predicted: the undo count stopped growing, the undo label showed the older edit's
name instead of the repeat's, and one undo reverted both changes at once. The real
implementation shares no journal key with anything, so a repeat can never fold into a
neighbor.

Not everything the underlying item named shipped. Both examples above already have a
cheaper path today — writing a Standard MIDI File and importing it — but that path is
still undocumented as the general-purpose thing it actually is; that half is unstarted.

## 2026-08-28 — The instrument meter was calling good instruments dead

The measurement described below shipped, passed twenty-six tests, and was wrong.

Run against two real saxophones — one a single recorded sample, one with genuine
velocity layers — it reported both as lifeless. The layered one is precisely the case
the tool exists to recognise, and it was told, confidently, that velocity was only a
volume knob.

The cause was in how brightness was averaged across the spectrum. The measurement
weighted each frequency by the square of its strength rather than its strength. That
sounds like a technicality and is not: squaring makes the lowest, loudest part of a note
dominate, and the lowest part of a note barely changes when you play harder. The
information that distinguishes a layered instrument lives in the upper harmonics, and
squaring is exactly what buries it. A real difference of 6.6% was reported as 0.3%.

It is fixed. The same two instruments now read 0.09% and 7.9%, and the layered one
resolves into three distinct tones — with the two loudest velocities correctly sharing
one, which is how that instrument was actually built.

Two things about how this was found are worth saying, because neither is about
saxophones.

The tool checks itself before every measurement: it generates a low tone and a high one
and refuses to answer at all if it cannot tell them apart. That check passed the whole
time, and could never have failed. A pure tone has only one frequency in it, and for a
single frequency both ways of averaging give the same answer. **A self-test built from
something simpler than the real thing can be blind to an entire category of mistake
while passing perfectly.**

And every existing test agreed with it. They used a synthetic instrument whose layers
were far enough apart that both methods reached the same verdict. Twenty-six passing
tests, and the only thing that disagreed was a real instrument.

There is now a test that would have caught it, built from a tone with several harmonics
and checked against the arithmetic rather than against a previously recorded result.
Put the old method back and it is the only test that fails.

## 2026-08-28 — An instrument that only gets louder can now be measured

A saxophone sounded, in one listener's words, "like a toy". Nothing in the app disagreed: every
test passed, the levels were correct, the mix met its loudness target. The problem was real and
none of our instruments could see it.

It is measurable, though. On a real instrument, playing harder changes the tone as well as the
volume — lean on a saxophone and it gets brighter, not just louder. A single recorded sample
played at different volumes does not. So: play the same note at rising velocities, and compare
how far the loudness moved against how far the brightness moved. A large change in one with no
change in the other is the signature of a sound that will read as lifeless.

That measurement is now a command. It reports the full table, not just a verdict, so you can
disagree with the conclusion from the evidence.

Four answers are possible, and the distinctions matter: the tone moved (fine), the tone did not
move (this will sound lifeless on anything exposed), nothing sounded at all, or the velocities
never changed the loudness in the first place — in which case the question was never actually
tested. "Nothing was measured" and "we measured, and it was flat" are different findings and
never share an answer.

It also refuses to answer at all if it cannot first tell a low tone from a high one on a signal
it generates itself. A meter that cannot hear the difference would report every instrument as
lifeless, and that reading would look exactly like a true one.

What it does not do is judge quality. It cannot tell you a sound is out of tune, wrong for the
part, or simply ugly. Taste is still yours. Lifelessness is now ours.

## 2026-08-28 — Bulk edits stop mailing back every note they touched

Duplicating a clip, humanising a performance, or deleting several clips used to return every
note involved. Measured: duplicating a 149-note clip returned about 24,000 characters; removing
ten clips returned nearly 200,000 — two hundred kilobytes to report a deletion; humanising a
guitar part returned 260,000. The useful answer in each case was a handful of identifiers and a
count.

Those replies now carry the counts, and say explicitly that the notes were left out so a short
reply is never mistaken for an empty clip.

**This one changes the default**, unlike the same fix applied to note-writing earlier this month,
where the previous behaviour was kept. Ask for the notes and they come back in full, exactly as
before.

Two operations deliberately kept the old default, for the same underlying reason: splitting a
clip and writing its notes both return information you could not have predicted. A split
truncates any note crossing the cut, and writing notes mints new identifiers. Those still arrive
complete.

## 2026-08-28 — The tool server now says when it is running stale code

A rebuilt server that has not been restarted serves the old code, and nothing about it looks
wrong. This cost a whole working session: the source was correct, the build was correct, a search
of the built file found the new feature — and the running process had never read it, having
started six hours earlier. The failure mimics "that was never built", which is the exact wrong
conclusion.

The connection report now carries when the process started, when its code was last built as the
process saw it, and what that file says now. When the last two disagree, the process is running
stale code, and the report says so directly rather than leaving it to be inferred.

## 2026-08-28 — Corrections to two pieces of guidance that were wrong

The advice for fixing a too-quiet export did not work. It suggested adding a limiter and then
raising the level; measured, that lands nowhere near the target, because the level adjustment
happens after the whole master chain and is limited by what that chain already did. The
correction names the ordering that does work: the gain goes at the front of the chain, ahead of
the limiter.

Separately, the song templates listed each genre's tracks by name without saying which ones can
hold played notes and which can only hold recorded audio. Every genre is now annotated. The
lo-fi template is the trap worth naming: its track called "Samples" is audio-only, and it is
exactly the one you would reach for to hold a sampler.

## 2026-08-28 — A sound bank we cannot play now says so, instead of vanishing

Dropping a `.sf3` SoundFont into your bank folder used to do nothing at all. No error, no
warning, no entry in the list — the file was simply not there as far as the app was concerned.
You could open the folder, see the file, open the instrument picker, and not see it, with
nothing to tell you why.

That matters more than it sounds, because `.sf3` is the format most people already have.
MuseScore, which is where nearly everyone gets a free soundfont, hands out `.sf3` files and
nothing else. So the most likely first thing anyone tries is also the one thing that failed in
silence.

The bank list now shows it. An `.sf3` appears with an UNSUPPORTED badge and a line saying what
to do — open it in MuseScore or Polyphone, export a `.sf2`, and import that. It is deliberately
shown rather than hidden: being invisible was the whole problem.

Showing it does not make it playable, and that was guarded carefully. You cannot pick it, an
agent cannot select it, and importing it still refuses with the same plain message it always
gave. Clicking it in the picker does not quietly do nothing either — it repeats the reason.
Trading a bank that fails silently for an instrument that plays silence would have been a worse
bug than the one being fixed.

Playing `.sf3` files directly is a separate, larger job and is not done. Today the app plays
`.sf2` and `.dls`, and now it says so where you can see it.

## 2026-08-23 — Arrow keys step over a track they cannot land on

Dragging a clip to another track worked with the mouse and got stuck with the keyboard. With an
audio track sitting between two instrument tracks, pressing the down arrow on a MIDI clip did
nothing at all — the clip could not get past the lane it was not allowed to land on.

The mouse never hit this because a drag lands where you point: it asks to move two lanes and
never asks about the one in between. An arrow key can only say "down", so it asked for one lane,
was told that lane was the wrong kind, and stopped.

Arrow keys now step **over** a lane they cannot use and land on the next one that will take the
clip. Nothing else changed: the audio lane is still not a legal destination, a mouse drag still
lands exactly where you point and still refuses an impossible lane, and a press with no reachable
lane in that direction refuses exactly as it did before. When several clips move together they
still move as a rigid group — the step chosen is the first one where every clip lands somewhere
it fits.

This behaviour had been written down as a deliberate trade-off, with the advice to reorder your
tracks instead. It was reported as a bug by someone using it, and that ruling has been reversed.

## 2026-08-23 — Right-click an empty part of a track to paste there

Copying a clip and pasting it put it back where the playhead was, on a track chosen for you.
There was no way to say "put it here" with the mouse.

Right-clicking empty space in a track now offers Paste, and the clip lands on that track at that
point. If there is nothing to paste, or what you copied is notes rather than clips, the item is
still shown but greyed, so it is clear the option exists and what it needs. Pasting a MIDI clip
onto an audio track still refuses, and now says which clip and why.

Right-clicking a clip is unchanged and still offers no Paste — pasting "onto" a clip has never
had a well-defined meaning, and that argument still stands.

## 2026-08-23 — The Sampler makes a sound on a machine with no samples

Until now the Sampler could not be tried at all without a sample library of your own. A fresh
project ships no audio, so anyone reaching for it — or for the bend range and voice mode added
today — got silence, and would reasonably conclude the thing was broken.

The app now ships a single generated one-shot: a third of a second of A4, at 440 Hz exactly,
rooted at MIDI 69. Anywhere a sampler zone takes a file path it will also take the name
`builtin:test-tone-a4`, so the Sampler can be played, and its bend range and voice mode heard,
with nothing else on the machine.

A `builtin:` name that does not exist is refused, and the message lists the ones that do. That
matters more than it sounds: a name that quietly fell through to being treated as a filename
would have reported success and played nothing, which is the exact experience this change
exists to remove.

## 2026-08-23 — Writing notes no longer sends them all back to you

Adding notes to a clip returned the whole clip, every note in it, each with a freshly minted
identifier. For anything driving the app in bulk that is a large reply to a request whose
useful answer is a single clip id — and a clip may hold four thousand notes.

There is now a way to ask for the notes to be left out. The default is unchanged: ask for
nothing and you get exactly what you got before.

When the notes are omitted the reply says so explicitly and gives their count, so a suppressed
reply can never be mistaken for a clip that genuinely has no notes in it. The notes remain
readable at any time.

## 2026-08-23 — A misspelled setting is refused rather than quietly ignored

Settings passed inside a nested group — the notes on a clip, a tempo map segment, an automation
target, a sampler zone — were checked less strictly than settings passed at the top level. A
misspelled name in one of those was discarded on the way through, and the request came back
successful having done nothing.

Two such gaps were already known and recorded. Rather than fix the two, we went looking: there
were **seventeen**, including the one used by every single call that writes notes to a clip.

All seventeen now refuse an unrecognised name instead of dropping it. Nothing that previously
worked is affected — a name that was being thrown away was, by definition, already doing
nothing.

## 2026-08-23 — A nonsense value for a sampler knob is refused again

Setting a sampler knob to a word instead of a number — a gain of `"loud"` — was accepted by the
tool layer and passed through to the app, where it had previously been turned away immediately with
a clear explanation.

This was our own regression, hours old, and it came from a feature in this same release. The
new voice mode below takes the words `"poly"` and `"mono"`, so the setting tool had to start
accepting text. It did — for every setting, not just that one. Widening a door for one visitor
opened it for everybody.

The check is now made per setting rather than per shape: only voice mode takes words, and only
words. Everything else is refused at the boundary again, with a message naming what it got. Nothing
that worked before has been narrowed.

## 2026-08-23 — The Sampler bends further than a tone, and can play one note at a time

The Sampler's pitch-bend range was fixed at one whole tone, shared by every instrument in the
project and adjustable by nobody. A wind or string part that bends a fourth had no way to ask for
it.

Each sampler instrument now carries its own bend range, from nothing up to four octaves, defaulting
to the familiar whole tone so existing projects sound exactly as they did.

Alongside it, a voice mode. In the new **mono** setting a new note takes over from the one before
it instead of sounding on top of it — the way a single-reed or brass player physically has to play.
Measured on a real render: a D5 arriving over a held A4 leaves the A4 six hundred times quieter,
which is to say gone rather than merely covered. That distinction matters, because the older trick
of overlapping notes only ever *hid* a re-attack under a decaying tail.

**poly** remains the default and is unchanged.

**Correction, 2026-08-31:** neither the bend range nor the voice mode was
written into the project file, so a saved song reopened at a whole tone and in
poly however they had been set. Fixed — see "Four Sampler settings did not
survive being saved" at the top.

## 2026-08-23 — When a sampler setting is dead, the app says so and names a fix that works

A sampler whose individual zones each carry their own release makes the instrument-wide release
knob inert — the zones win. The app already said so. What it said to do about it did not work: the
suggested remedy named a path that exists deep in the control protocol but is absent from the tool
it named, so following the advice exactly produced a cheerful success and no change whatsoever.

The note now names the verb that actually does the job, and keeps the older form as a parenthetical
for anyone driving the app directly.

A second, quieter version of the same problem sat underneath it. A misspelled setting name inside a
sampler description was being silently discarded rather than refused — the request came back
successful and did nothing. That was our own inconsistency, not a limitation: some of these
descriptions were checked strictly and some were not. The sampler, its zones, and its crossfades are
now all checked. Two others, for hosted Audio Units and sound banks, still have the gap; they are
recorded rather than quietly left.

Finally, the description of a sampler no longer guesses at where its settings came from. It names an
SFZ opcode only when the instrument actually came from an SFZ file, and it now reports the stored
value and the value in force side by side instead of trying to collapse them into one number that
could not be defined once zones disagree with each other.

## 2026-08-23 — The tool reference no longer describes a product we changed this morning

Three pieces of guidance that AI agents read before touching this app had aged into being wrong.

One told every agent that no instrument here can slur between notes — written before the voice mode
above shipped, and stale within hours of it. One described a new MIDI clip as silent until an
instrument is configured, which stopped being true a long time ago; a new track sounds immediately.
One asserted a precise tool count, presented as freshly measured, that was out of date.

All three are corrected, and the count is now marked as needing re-measurement rather than restated
as a number that will rot again.

## 2026-08-20 — A clip plays at its own pitch, not the bend left behind

When a clip had no pitch-bend lane of its own, it would inherit the pitch bend left behind by an
earlier clip on the same track. A clip meant to be in tune played a full semitone sharp — that is
exactly how wrong it was. A preceding clip holding bend 12288 made the next clip play +100 cents
sharp.

The cause was in how the engine chases controller state when playback starts or seeks. That chase
ran once per audio block rather than once per clip, so a new clip beginning mid-block picked up
whatever bend the last clip had set, instead of starting clean.

Now a clip with no bend lane begins at centre pitch, explicitly, at its first beat. Seeking into
such a clip also chases centre rather than the earlier bend. The fixed rendering measures A440, not
a semitone sharp.

Here is an important distinction: mod wheel, breath (CC 11), and other continuous controllers are
not reset at a clip boundary, and this is correct, not an oversight. Resetting them would be actively
wrong — CC 11's neutral value is full, so resetting breath at every clip start would jump it to
maximum. A test pins this.

The reset touches bend-using tracks only and emits exactly one event carrying one value. Tracks with
no bend are untouched. One thing remains open: the same leak still exists when exporting a MIDI file,
which uses a different code path and has not yet been fixed.

## 2026-08-20 — Bounces now tell a hosted plugin it is rendering offline

When you bounced a track through a hosted Audio Unit instrument, the first clip often disappeared
from the bounce. The only way to get it back was to place a dummy note in front of it. A real bounce
would silently lose an instrument's opening.

The cause: Apple's Audio Unit API has a flag that tells a plugin it is rendering offline rather than
live. DAW Pro never set this flag. A plugin that loads its sounds lazily had no way to know it must
load before the render starts, rather than streaming in as playback happens.

The fix sets that flag on every hosted Audio Unit before that unit allocates its render resources,
which is the only moment at which the flag has any effect — set it later and the plugin has already
decided how to behave. Live playback is unchanged: only the offline renderer sets it, the live engine
never does, and a test holds that boundary in place.

Here is what we measured: bouncing through a built-in Apple effect and a General MIDI sound bank
produces byte-identical audio. That proves the change is harmless where nothing was broken; it does
not prove it cures the reported case, because those components were never dropping anything in the
first place. The fix rests on Apple's documented behaviour for the offline flag, and has not yet been
confirmed against the reporter's own project.

## 2026-08-20 — The Sampler stops reporting a Release you cannot hear

Load a sample library and the Sampler's own **Release** knob often does nothing. That is correct, and
it is not new: most `.sfz` libraries set a release time on every zone they contain, and a zone's own
setting wins over the instrument-wide knob — the same way it works in every other SFZ player. The
knob is the fallback for zones that stay silent about it, and a library that speaks for all of them
leaves nothing for it to do.

What was wrong is that nothing said so. Asking the Sampler to describe itself answered "release:
3.4465 seconds" for an instrument that audibly stopped in half a second, and there was no way to
tell that number was dead. An answer that looks exactly like a real answer and is not one is worse
than no answer, and it is worse still for an AI agent, which has no ears to catch it with.

Now the description says which of **Release**, **Attack** and **One-shot** the zones have taken over,
and what the instrument will actually do — including the mixed case, where some zones override and
the rest still follow the knob. If a knob is doing nothing, it now says so in that many words, and
points at the per-zone setting that will work instead.

Nothing about how your projects sound has changed; this is the report catching up with the engine.

## 2026-08-20 — Turn a real knob, move the breath pad

The breath pad has a dot you drag around a circle to say how a player is blowing. You can now drive
that dot from a knob on a MIDI controller instead of the mouse.

Pick what the knob should move — *travel around the ring* or *depth* — arm it, and turn the knob you
want. The first controller move wins, which is how MIDI learn works everywhere; if nothing happens,
the app tells you which controller it last heard, so "your knob is not mapped" and "your knob is not
plugged in" stop looking the same. One knob on *travel* is the whole gesture: it walks the dot from
one effort shape into the next at whatever depth it is sitting at. A second knob on *depth* covers
the rest of the pad.

Two things worth knowing. The mapping is not saved into your song — it describes the hardware on
this desk, so opening someone else's project will not re-point your knobs, and it does not survive a
relaunch yet. And a mapped controller is **not** swallowed: it still reaches an armed track and still
records into the take, so if you are playing through a hosted plugin, pick a controller number that
plugin does not use.

Something that already worked and had never been written down anywhere: a hardware knob sending CC 11
already rides an armed track's expression today, with no mapping and no setup — plug it in, arm the
track, turn it. That works with the transport stopped. On the built-in instruments only CC 1, 2, 11
and 64 do anything; hosted plugins get everything.

**This round is controller-and-agent only — there is no button in the pad panel yet to arm learn.**
Mapping a knob currently goes through the control surface or an AI agent, not the on-screen panel.

## 2026-08-20 — Your bounce now sounds like what you heard

If you put a vibrato or a tremolo on a track that plays through a **sound bank** or a **hosted Audio
Unit plugin**, the export used to disagree with the monitor. It played back correctly and bounced
wrong, which is the worst way for a bug to behave, because everything sounds fine right up until you
send the file to someone.

**Check which of your tracks this applies to before re-bouncing**, because it is not all of them. The
project snapshot reports each track's instrument `kind`:

| `kind` | What it is | Affected? |
|---|---|---|
| `soundBank` | An SF2/DLS bank program — the GM instruments | **Yes** |
| `audioUnit` | A hosted AU plugin instrument | **Yes** |
| `sampler` | Our own sample player | No — never was |
| `polySynth` | The built-in poly synth | No — never was |

The last two never went through the coarse path, so a sax on our own sampler was always bouncing its
vibrato correctly. This distinction was missing from the first version of this entry, and a tester
had to measure their own project to discover it — which is precisely the work good documentation is
supposed to save.

The cause was ours, not the instrument's. A bounce fed those instruments their controller moves in
blocks eight times coarser than live playback does, and a wobble sampled that coarsely comes back as
a *different* wobble. A 5.5 Hz vibrato exported as two vibratos beating against each other. An 8 Hz
one exported at 3.7 Hz. At 11.7 Hz it stopped being a vibrato at all and became a static, slightly
flat note.

Bounces now use the same block size as live playback, so the two agree by construction. Measured on
rendered audio: vibrato depth arrives at 95–100% of what you wrote, at the rate you wrote it. The
false copies are not deleted — they move eight times higher and shrink to a few cents, well out of
the range you hear as a wobble. The cost is 0.14 seconds on a two-minute eight-track bounce — still
two hundred times faster than real time.

This was measured on Apple's built-in sampler with the stock sound bank, which is what those tracks
use. It says nothing about third-party plugins: one that smooths its own controller input never had
this problem in the first place.

One feature comes back because of this. The breath pad's micro-tremor — the small 4–8 Hz waver inside
a sustained note that makes a wind part sound played rather than typed — had to be refused on those
instruments, because at the old block rate it produced an artefact louder than itself. It now lands
there like everywhere else. The refusal still exists for genuinely fast modulation (above 18.75 Hz),
and it still tells you when it applies rather than quietly retuning what you asked for.

Automation on those tracks is eight times finer in an export as a side effect, so a bounce of a
project with controller automation will produce different bytes than it did yesterday. That is the
fix working, not a regression.

## 2026-08-20 — The breath pad has a face: a circle, a dot, and a gauge that says why it went quiet

Eight ways a wind player shapes a note now sit around a circle, and a dot moves between them. Where
the dot points chooses which two blend; how far out it sits chooses how strongly. You hear it while
you drag, and the shape is written into the part when you let go — once, on release, never on every
frame of the drag.

The middle of the circle is worth one sentence, because it is the opposite of what a knob usually
means: the centre is **"exactly as written"**, which is the LOUDEST reading, not the quietest.
Dragging outwards shapes the part more strongly. Nothing in the panel calls that axis a volume, and
the readout is labelled DEPTH for the same reason.

Under the circle is the air gauge, and it exists because a feature that can quietly turn your phrase
down owes you an explanation. It draws one band per phrase whose height is the breath the simulated
player has left, a mark where he got a breath (and a different mark where the gap was too short to be
one), and a plain sentence: *"Air enforcement pulled 2 of 8 notes down, by up to 11.0 dB."* The
switch that turns enforcement on sits on the face of the card, not behind a disclosure, and it starts
OFF — a model that overrides what you wrote is something you turn on once, deliberately.

With the switch off you still get the reading, and the sentence changes tense rather than disappearing:
*"AIR IS OFF. Enforcing it WOULD pull 2 of 8 notes down."* Applying without enforcement is therefore
how you find out what enforcement would do, before you let it do it.

Reachable from the piano-roll BREATH chip and from an instrument clip's context menu. It adds no new
commands and no new AI tools — the engine behind it already had both; this is the half a human can
click.

One fix in here was found by making the window small. On a laptop-sized window the card ran past the
bottom of the screen and took the **Write the shape** button with it — the panel drew perfectly and
could not be used. The card now shrinks its circle first, then its warnings list, and finally scrolls
its middle while the title bar and the button stay put, so the two things you always need — close it,
or commit it — are never the things that fall off the edge.

## 2026-08-19 — The pad you can hear while you drag it, and the value it refuses to leave behind

The breath pad could already write a shape. Now you can hear one while your finger is still moving.
Drag the dot and the instrument responds immediately — the same path a piano-roll key press already
uses, so nothing new runs on the audio thread and nothing new can stall it.

The part worth explaining is what happens when you let go. The pad does **not** leave the last value
you dragged to sitting on the instrument. A MIDI controller is sticky: nothing takes it back. Park a
low expression value and every later playback of that song would be quieter than a bounce of the
same project — the preview would have quietly become part of the record. So releasing the pad
restores the controller to exactly the value the sequencer itself uses when no automation says
otherwise.

One caveat, stated plainly because we measured it rather than assumed it. That restore is the
sequencer's *default* value, which is not the same thing as your track's own automation. If the track
already has an expression lane and you preview in the middle of playback, letting go sets the
controller to full and it stays there until the lane's next point — so that stretch plays back louder
than a bounce would. It corrects itself at the next point, and it cannot happen at all on a track you
have not yet written a shape to, which is the case the pad exists for. (The direction depends on the
controller: expression's default is full, so the error is toward louder there, but a preview aimed at
a different controller errs toward whatever that one's default is — modulation's, for instance, is
off.) Restoring the lane's own value needs machinery that lives inside the schedule builder today, and
we would rather ship the limitation written down than a second copy of that machinery that disagrees
with the first. It is on the roadmap as its own item.

For the same reason the pad only streams **while a gesture is in progress**. That rule is enforced
on the wire, not just in the window: an agent that sends a move without first sending a begin is
refused with a sentence telling it why. And a gesture that is never ended releases itself.

One measurement came out of this that corrects a number we had been assuming: live playback hands
the engine 512-frame blocks — 93.75 times a second, eight times finer than an offline bounce. The
controller-resolution ceiling we had documented is a property of bouncing, not of listening.

A saxophone held a long note and it sat there, flat, the way a real one never does. The report that
came back named the mechanism precisely: seven CC11 expression lanes had been written into the
song, they were stored, they were drawn in the editor, and not one of them reached the audio. The
built-in sampler honoured CC64 and nothing else. The lanes were decoration.

They sound now. CC11 drives amplitude continuously, a per-voice lowpass turns a controller into
brightness on the built-in sampler, SFZ crossfade parses in both its velocity and controller forms,
and `clip.applyBreathContour` writes a shaped breath curve over a sustained note. A warning path
now says, at the moment you author a lane, whether the track's current instrument will actually
honour it — because the failure this round exists to fix was never an error message. It was silence
that looked like success.

Then we asked the sampler three questions nobody had asked it, and two answers changed the plan.

**CC 11 does not open a filter on a sound-bank track.** It is exactly a gain, following the MIDI
square law, with any non-gain difference bounded at −104 dB. That is not "we looked and found
nothing" — the same measurement fires on the built-in sampler's real filter and refuses there by
95 dB. So on a hosted AUSampler the breath control shapes loudness and pitch, and no text may
promise it shapes timbre. **The pitch-bend range is ±2.0155 semitones**, which vindicates an
assumption that had been sitting unverified in the contour generator. And **the stock sax has its
own vibrato on CC 1**, linear in depth, fixed at 5.400 Hz, generated inside the plugin.

That last one matters more than it looks, because of what else turned up: **pitch-bend lanes are
sample-and-held at the render block rate in a bounce.** Offline render uses 4096-frame blocks — an
11.719 Hz sampler against a 5.86 Hz Nyquist — so a 5.5 Hz vibrato exports as two vibratos beating
against each other, and an 11.72 Hz one exports as a static detune. Both of our own layers are
already sample-accurate, which means we cannot fix it by scheduling better; the block size is the
only lever. It is filed with the experiment that settles it. Until then, sax vibrato belongs on
CC 1, where it never touches our bend lane at all.

On top of that sits the first phase of the breath pad: eight named effort shapes — messa di voce,
the two hairpins, terraced, sforzando-piano, sub-tone entry — applied per note or per phrase through
`clip.applyEffortShape`. The phrase-and-breath detector that humanize had been carrying inline is
now one definition used by both. The gates assert on rendered samples rather than stored lane
points: a hairpin crescendo measured at +3.72 dB strictly rising, with a diminuendo control that
falls.

**One contract change to a shipped verb, deliberate and worth stating plainly.**
`clip.applyBreathContour`'s `notesWithVibrato` count now requires `vibratoDepthCents > 0` as well as
sufficient note length. It previously reported vibrato on notes that had none, and its companion
warning fired about notes being "too short" when vibrato had simply been switched off. Callers
reading that field were being told something untrue.

## 2026-08-18 — Nine genres, and a bass that is allowed to bloom

A blues session had to ask for rock. It got rock's 140 BPM, rock's two guitars and, worst of the
three, rock's `bass-tight` — a 4:1 compressor at a 5 ms attack, which catches a blues bass note
before it has finished swelling and flattens exactly the part a blues bass is for. Nothing in that
chain was broken. The template simply wasn't shaped for the job, and there was no other template to
ask for.

There are fourteen genres now: the original five plus **blues** (84), **jazz** (132), **country**
(100), **r-and-b** (88), **funk** (108), **metal** (170), **folk** (96), **reggae** (76) and
**lo-fi** (78). The bar each had to clear was distinctness in *form* as well as roster, because a
genre that differs only in its track names is a roster override wearing a costume. Blues is
genuinely twelve-bar — its body sections are 12 bars, not the 8 a pop layout hands back. Jazz is
32-bar head/solos/head and carries no audio strip at all, since a combo is played rather than
tracked. Lo-fi is Loop A / Loop B rather than verse/chorus. Metal has the hard-panned double rhythm
guitar. A test enforces the bar: no two genres may share a tempo *and* a roster.

Two genres were deliberately not added. There is no `latin`, because salsa, reggaetón, bachata and
cumbia share almost no roster or tempo, and shipping them as one entry would recreate precisely the
rock-serving-blues failure this work exists to fix. There is no catch-all `edm` for the same reason.
Both are reachable through the roster override that landed last pass, with no release.

Six presets joined them, each referenced by at least one roster rather than invented speculatively:
`guitar-crunch`, `acoustic-sparkle`, `horn-section`, `drum-room`, `lofi-tape`, and **`bass-round`**.
That last one is the actual fix, and it is a *pair* with `bass-tight` rather than a correction of it
— the tight preset is right when a bass must sit rock-steady under a dense mix, and nothing about it
changed. What is new is the sibling: the same threshold, so the two differ in how they compress
rather than in how much signal they see, but 2.5:1 at a 20 ms attack with a low-shelf *lift* against
tight's 4:1 at 5 ms with a low-shelf *cut*. The note blooms before the compressor catches it. A test
pins the direction of both differences, so the pair cannot later be tidied into twelve names and
eleven sounds.

Nothing was renamed, retuned or removed, and no verb or tool was added — the catalogs grew in place
and the additions are appended, so the wire-visible order is unchanged.

Two things surfaced while doing it that are worth more than the feature. A negative test fixture went
stale in the same commit that would have inverted it: both unknown-genre tests used `"jazz"` as their
not-found string, so adding the genre would have left them asserting that something which exists
does not. A negative fixture has to be a value the catalog will never plausibly adopt, not merely one
it happens to lack today. And the preset catalog carried a false sentence: it documented the negative
low-shelf as a workaround for the built-in EQ having no high-pass, which stopped being true when the
EQ gained one. The shelf is kept — every existing preset uses it and retuning them would change how
existing projects sound — but it is now documented as the house style it actually is. A wrong doc
produces a report indistinguishable from a wrong implementation, which is the lesson the previous
entry was already about.

## 2026-08-17 — Four answers, and one of them cost no code at all

The open questions from the field report came back answered. Two have landed.

**A bounce now sounds notes that started before it.** The entry below says this one was left where it
was, because whether a region bounce should chase held notes is a product decision and not ours to
make. It has been made: chase, the way the play button already does. A pad held from bar one is
audible when you play *through* bar five, and it should not vanish because you bounced *from* bar
five — which is what it did, at RMS exactly zero, while a straddling *audio* clip in the identical
position sounded fine. That asymmetry is now closed.

It is a fourth reschedule cause rather than a reuse or a flip. Calling it a transport start would
have made that case mean "the user pressed play" when nobody did, and flipping the relocation case
would have changed three live behaviours — seeking while rolling, starting a record, wrapping a loop
— to fix one offline one. The cost is stated rather than implied: a note already mid-decay at the
window edge re-attacks at full velocity, so a bounce synthesises an attack the song does not have
there. You can see it in the measurement — the bounce reads slightly *louder* than the play-through,
0.0662 against 0.0639, where it used to read 0.0.

The part worth trusting is the containment. Chasing can only ever add notes that begin before the
window, so a render from beat zero cannot change — nothing precedes zero. That is now checked in bit
patterns rather than argued: zero differing samples out of forty-eight thousand at beat zero, and
47,998 differing at beat four, so the test can demonstrably see a difference when there is one.
Nothing was re-baselined, because nothing moved.

**The pitch-accuracy target was corrected rather than enforced.** The detector spike set a bar of ±10
cents and attached a consequence — miss it and we throw out the detector and vendor a different
library. The detector missed it. But the bar is impossible by arithmetic: the model reports pitch by
picking one of 256 bins across 6,577 cents, so a bin is 25.8 cents wide and the worst-case rounding
error is ±12.9 cents before the model is consulted at all. No tuning reaches ±10, and neither does
swapping in another library that reports through the same 256 bins — so the consequence would have
discarded a working detector over a specification error.

What it actually does on voice-like material is 4.74 cents median in the sung range and zero octave
errors, which is the failure that actually ruins a tuned vocal. The synthetic tier of the target is
now written in those units. The real-vocal tier is untouched and still binding — and still unmet, in
the honest sense that no real vocal has been through this path yet.

The odd part: the code needed no change, and neither did the tests. The Swift battery had been
measuring median, p95 and octave rate all along, with margin over the measured numbers and a
deliberately-wrong tracker asserted to fail it. The *document* was the only thing still stating a
target nothing could hit.

**The Sampler is reachable now, over MCP.** It was the only instrument surface in the app with
neither a read nor a per-parameter write — effects have describe-and-set, hosted plugins have
describe-and-set, the sound banks report where they came from, and the built-in Sampler had none of
it. After an import, a nineteen-parameters-per-zone instrument was frozen at whatever its `.sfz`
author chose.

Three tools and a new read command. The read is the one worth describing: it reports pitch and
velocity coverage as the *union* of the zone ranges — the outer envelope plus the interior gaps —
rather than a minimum and a maximum. A min/max would report "0 to 127" for a keymap with a hole in
the middle, and a hole in the middle is exactly what cost the last session an afternoon: a bass that
was silent below MIDI 35 and a library silent above 45. It also pages, because the only previous way
to see any of this was a project snapshot that measures 296,809 bytes on a real song.

Underneath, two things that had to be fixed first. Zone ids were published in every snapshot and
then thrown away on every write — the parser minted fresh ones per element — so reading a keymap and
writing it back silently renumbered all of it, and nothing could address a zone to edit it. And a
sampler track recorded nothing about where its library came from, so "which bass is this?" was
answerable only by dumping a megabyte and eyeballing a file path. Both now hold.

One compatibility note, because it changes nothing you'd notice but is the kind of thing that bites
later. Copying one track's zones onto another track still works. Honouring ids is what made that
dangerous — zone ids have to be unique across the whole project, since the project file keys each
zone's sample reference by id — so ids that don't belong to the destination get fresh ones, exactly
as they always did, and the reply now tells you which ones were replaced instead of doing it
silently.

**And agents can paste.** Paste was reachable only through a debug verb, so the one operation you
perform constantly by hand had no honest route for anything else. `edit.pasteClips` fires the app's
own ⌘V — the same clipboard, the same target resolution, the same undo step — and its reply
distinguishes the four things that used to collapse into a bare false: clips landed, the clipboard
was empty, the clipboard holds notes rather than clips, or the destination refused the payload. An
agent that got `false` had no way to tell those apart.

Worth being plain about one limit: the clipboard is *yours*. Nothing can put clips into it over the
wire, so this pastes whatever you last copied.

## 2026-08-17 — What the agents were told, versus what the app can actually do

Someone installed the Music Team plugin, asked it for a song, and then asked it what got in the
way. Eleven findings came back. Six of them turned out not to be about the app at all — they were
about what the agents had been *told*, and in two cases what they had been told was simply wrong.

The sidechain is the clearest example. An agent reported it unusable in an all-MIDI project,
because the tool's own description said the key source has to be an audio track. It doesn't. The
code has only ever rejected a *bus* as a key source — an instrument track is a perfectly valid one,
and ducking a pad off a MIDI kick never needed an audio bounce. What the tool actually requires is
that the *keyed compressor* live on an audio or bus track, which in an all-MIDI project means
adding a bus. The mix engineer couldn't do that either, but for an unrelated reason: nobody had
given it `track_add`. Two sentences and one tool grant, and a capability that had been reported as
missing turned out to have been there the whole time.

The same shape, four more times. `clip_humanize` compounds when you run it twice — the store's own
comment says so, the tool description never did. `render_measure_loudness` re-renders the session
rather than reading the file you just wrote, which is fine, but nothing said so and nothing pointed
at the tools that *do* read a file. The master fader stops at +6 dB, and the answer to a mix that
needs more is a gain insert, not a fight with the fader. And a windowed loudness measurement
silently drops every MIDI note that started before the window — which produced a convincing false
alarm about a silent outro, and cost several probes to disprove.

Two real gaps got closed rather than documented. `note_audition` now returns the instrument's load
status alongside `audible`, because `audible: true` on a patch that is still loading had been read
as "this patch sounds good" — it never meant that, and now it can't be mistaken for it. And
`macro_song_skeleton` now drops a real marker at every section start, so the song's beat map exists
the moment the scaffold lands instead of being retyped by hand into every downstream instruction.

The plugin itself got the rest. Its coordinator agent had been told to delegate through a tool it
was never granted — an exhaustive tool allowlist revokes the built-ins, so its documented job was
literally unexecutable. It now plans, scaffolds, and hands back a delegation plan, with the tools
to reconcile a genre template against an actual brief. The finisher can inspect the file it just
wrote. The composer can read one clip's notes instead of the entire project. And the reference
every agent preloads now carries the traps above, each with the measurement that proved it.

One finding was left exactly where it was. Whether a bounce should chase notes held across its
start is a product decision with a test suite already pinning today's answer, and it belongs to the
person who owns the product.

A later pass through the same report turned up something worse than friction. `track_set_instrument`
describes itself as a partial update — omit a field and it keeps its value — with the sampler as
the stated exception. What that exception meant in practice: send `{sampler: {release: 0.4}}` to
lengthen the release on a 309-zone imported bass, and the omitted `zones` key parsed as an empty
array, which the store then swapped in wholesale. The library was deleted. The call returned
success. The only symptom was an instrument that had stopped making sound, and the documented way
to avoid it was to read all 309 zones back out of a snapshot approaching a megabyte and resend them
with your one change.

The sampler is now partial too, at both levels: omit `zones` and the track's zones stand, omit a
global and it keeps its value instead of snapping back to a default. A `zones` array you actually
send still replaces the map — a wire zone carries no id the parser honours, so there is nothing to
merge by yet — which makes `zones: []` the deliberate way to clear a sampler and nothing else.

`clip.getNotes` / `clip_get_notes` — new, strictly read-only control command and MCP tool. Give it
a clip id and it hands back that clip's notes, with their real ids, optionally narrowed to a beat
range or a pitch range. It exists because there was no honest way to read a MIDI clip's notes back
without either asking for the entire project or mutating the clip to get an echo of it.

`clip.setNotes` has always replaced a clip's whole note array — by design, there's no
add-one-note verb. That's fine for writing, but it means editing requires reading first: you need
the current array, ids included, before you can change three notes and resubmit six. The only
tool that returned notes at all was `project.snapshot`, and on a modest six-track project that's
about 290 KB of JSON — comfortably past what an agent can afford to read on every turn just to
find one clip's content. The only other option was calling `clip.humanize` with zero jitter and
throwing away the jitter, using a mutating command as a magnifying glass.

That trick turns out to be worse than it looks. Zero jitter does draw nothing and does leave the
notes byte-identical — but the edit still runs through the same code path as a real edit, which
marks the project dirty and pings the engine, whether or not anything actually changed. Undo is
the one thing it happens to spare, because the store already skips writing a history entry for an
edit that produced no change — but "the app now thinks you have unsaved work" is exactly the kind
of side effect a read should never have. `clip.getNotes` never enters that path at all.

Two things about the response are worth knowing before wiring it into anything. The beat window is
half-open — a note starting exactly at the end of your range doesn't come back, so two adjacent
windows never both claim the same note. And the response always reports the clip's *total* note
count alongside however many survived your filter, specifically so that filtering, editing, and
then calling `clip.setNotes` with only what you saw can't quietly delete the notes you never asked
for.

## 2026-08-16 — Zooming the note editor no longer slides the music away

Pinch or press ⌘+ in the note editor and the music used to drift sideways under your
cursor — you'd zoom in on a bar and land somewhere else. The arrange has always held
its place. The editor simply never adopted the rule.

It does now, and it anchors on the right thing for each way of zooming. A pinch has a
pointer, so it holds the beat under your fingers. The ± buttons and ⌘± don't — your
hand is at the header, nowhere near the beat you're reading — so those hold the
playhead, or the centre when the playhead isn't in this clip.

The arithmetic wasn't rewritten. It's the same function the arrange has always used,
called from one more place; the editor adds only its own answer to *which point should
stay still*. Worth doing that way because "the centre of the view" now has exactly one
definition, and the day it changes, both surfaces change together.

One bug nearly shipped inside this. The new scale was being written before the anchor
was measured, so the code would have read the playhead's position at the *new* zoom
level — a perfectly plausible number describing the wrong place, and the picture would
have slid by exactly one zoom step. Caught, fixed, and pinned by a test that fails if
anyone reintroduces it.

## 2026-08-16 — The test suite stops forgetting its own history

Internal tooling, invisible in the app, but it was quietly destroying evidence.

This project has 94 "gates" — standalone checks that guard behaviours ordinary tests
can't see. Each run recorded its result into a single file that the next run overwrote.
That file isn't in version control, so the previous result wasn't recoverable from
anywhere. Running a gate destroyed the only record of how it did last time — which makes
*"did this used to pass?"*, the first question anyone asks when something breaks,
permanently unanswerable.

There's now an append-only history alongside it: one line per write, never rewritten.

The interesting part was finding all the places that write. Three different pieces of
code do, and they deliberately record different things — one knows how many checks ran,
another knows how long it took, and only one knows the actual pass/fail verdict, because
only it can tell a genuine failure from one that's expected and pinned. Hook the history
into the obvious two and you'd get a complete record of hashes and timestamps that never
once says whether anything passed. All three now go through a single shared writer, which
also fixed one of them writing non-atomically — it could leave a half-written file behind
if interrupted, a hazard the other two had already been hardened against.

Verified by breaking it on purpose: unhooking each writer in turn fails exactly its own
check and leaves the other two green.

## 2026-08-16 — Hold at the edge and it keeps scrolling

Dragging notes to the edge of the note editor scrolls the view. Holding them there used to do
nothing: the scroll advanced only when a pointer event arrived, and a pointer held still emits no
events. Push to the edge of a long clip and you'd stop, mid-drag, with nowhere left to go.

The reason it had never been built was a real objection written into the code: a clock firing
between pointer events has no event to read, so it would have to *invent* how far the pointer
moved — and an invented number would slide the notes out from under your cursor. That objection
turns out to be answerable. A held pointer only changes position within the content because the
content moved underneath it, and the editor already knows exactly how far it scrolled. So each tick
recomputes the position from that, rather than accumulating guesses. Nothing drifts, because nothing
is being added up; and the value it arrives at is the one the system itself would have reported, so
the next real movement agrees with it instead of jumping.

Two hazards showed up during the build and both would have shipped as bugs. The first gate tried
"no event since the last tick" as the test for *held* — but a 16 ms clock and 16.7 ms pointer events
drift past each other, so roughly every other tick would have fired mid-motion and quietly made
normal dragging faster. It now waits for 200 ms of genuine stillness, which can't beat against
anything. Second, a press with no movement counts as a drag, so simply clicking near the edge would
have launched a runaway scroll. It now arms only once you've actually moved.

The arithmetic is machine-checked: the dragged note's position on screen is pinned across a
four-thousand-point run, and deliberately corrupting the calculation makes that check fail. Whether
the *ramp* feels right is not something any test here can judge — that needs a hand on a trackpad.

## 2026-08-16 — Every key is named, and so is every note

The piano roll's keyboard used to label C and nothing else, which left you counting rows to find
out where you were. Every key now carries its name, and note blocks carry theirs too when there's
room.

A note too narrow for its name shows no name at all rather than a shortened one. This is not
fussiness: "C#4" trimmed to "C#" is a *valid, different pitch*, so trimming here would invent a
plausible wrong answer instead of admitting it ran out of space. Zoom in and the names appear.

Legibility was measured rather than eyeballed — the actual view rendered offscreen and its pixels
read back. Every one of the 128 rows clears the contrast floor. That measurement changed the
design twice: a single dark ink turned out to fail on quiet violet notes, which are exactly the
ones marking AI-generated material, so each note now picks its ink from its own colour and
loudness. And the text metrics we assumed were slightly wrong in a way that had been costing every
eighth note its name at normal zoom.

Accidentals are set one tone quieter than naturals so 128 names read as a scale rather than a wall
— though whether that lands is a matter of taste, and nobody has looked at it in a running app yet.

## 2026-08-16 — Ask a clip what notes are in it

`clip.detectPitch` — new control command and MCP tool. Point it at an audio clip and it returns the
pitch, 62.5 readings a second, with a confidence and a level for each one. This is what the
voice-to-song workflow was waiting on: an agent can now find the notes in a spoken or sung phrase
instead of being told them.

Verified end to end against a tone built for the purpose — 220 Hz for two seconds, then silence.
It read **220.06 Hz, a median error of half a cent**, and no octave errors. Where the silence
begins, every frame says so: the pitch field is simply absent, with a reason attached — *below
level*, meaning too quiet to tell, as distinct from *below confidence*, meaning present but
unclear. A zero there would have become a real note the moment anything read it.

Frames are never dropped, only emptied. A gap in a vocal is information — the difference between
two notes and one long one — so the grid stays even and the holes stay visible.

One shape worth knowing: asking about a whole three-minute song returns about 11,000 frames. That
ceiling is deliberate. Thinning them out would have been easy and would have quietly destroyed the
evenness the previous paragraph depends on.

## 2026-08-16 — The app can hear pitch

Pitch detection runs in-process now: a protocol seam with a SwiftF0 backend behind it, reading
frequency from audio 62.5 times a second. This is the foundation vocal tuning and the voice-to-song
workflow have both been waiting on. It isn't reachable from the app yet — the command that exposes
it is the next piece.

Two things found while measuring it are worth writing down, because both nearly caused the wrong
decision.

**Every bad accuracy number previously on record was a property of the test tone, not the model.**
A 220 Hz pure sine came back 88.8% wrong by an octave. The same pitch played with harmonics — a
sound resembling a voice or an instrument — reads 0.48 cents off, with no octave errors at all. A
model trained on spectrograms of real audio has never seen a pure sine. The fixture was the defect,
and it very nearly condemned a working detector.

**Confidence does not mean "there is sound here."** A tone at −140 dBFS, which is silence by any
practical definition, comes back with 99.99% confidence. Left unguarded, that turns room tone into
a confident melody. Detection now requires both confidence and an actual signal level, and those
two catch different things: confidence rejects noise, level rejects near-silence.

Where a frame has no pitch, it says so and says why — too quiet, too uncertain, or out of range —
rather than reporting zero. A zero would become a real note the moment anything read it.

Accuracy on voice-like material: 4.74 cents median in the sung range, 10.60 in the low range, zero
octave errors in either.

## 2026-08-16 — Humanize and Quantize no longer pretend to work on a comp'd take

If a clip was part of a take comp, the Humanize and Quantize panels would open, let you set
amounts, accept the Apply, close — and change nothing. The store had always refused that edit;
the refusal just never reached the screen.

Both panels now ask before offering. Apply is disabled and the panel says why, naming the comp
and the way out (flatten it, or edit through the comp). The panel also stays open, so the
sentence is still there to read.

The distinction underneath is worth stating, because it decides how every future refusal in a
panel should look: **kind hides, state explains.** Whether a clip is audio or MIDI is what it
*is* — the panel makes no sense, so the entry never appears. Whether it belongs to a comp is
something you can change — so the door stays open and the app tells you what to do first.

Fixed in both panels deliberately. Quantize shipped first and had the identical fault; fixing
only the one you'd noticed would have left the same silence one menu away.

Not yet confirmed by eye: the reason is verified to be computed and wired, but nobody has seen
it drawn in the panel.

## 2026-08-16 — When a clip can't grow to fit your note, it now says so

Placing a note past the end of a clip usually just works: the clip grows to make room. But it
can't always. Another clip may be sitting right behind it, or the note may be further out than
the app is willing to stretch in one go. Until now those two cases looked identical to the
ordinary one — the note landed, stayed silent, and nothing on screen changed.

An amber note now appears and names the actual obstacle, because the obstacles have different
fixes: a clip in the way is something you move, a note too far out is something you place nearer.
Telling you the wrong one would be worse than the silence.

The hard part was not the message. "The clip didn't grow" and "the clip couldn't grow" were the
same answer internally — the same empty result covers a note that already fits, which is what
happens on essentially every edit inside a clip. The naive version of this feature would have
warned you every time you moved a note, and every time you pressed Delete. The rule now returns
a named reason instead of a bare blank, so the ordinary case is something the compiler forces
anyone to handle rather than something a reader has to notice.

Not yet confirmed by eye: the message is verified to fire on the right cases and carry the right
text, but nobody has seen it drawn over the grid.

## 2026-08-16 — You can now ask the app what a rendered file actually contains

Verifying a bounce used to mean leaving the app. Checking whether a render was truncated, or
what the level was in one particular second of it, needed external tools every time.

`audio.profileFile` answers that directly: give it a path and a window size and it returns
peak and RMS for each window, plus the file's own header — duration, sample rate, channels,
bit depth. It reads the file where it lies: nothing is copied, nothing is imported, and the
project's reference slot is left alone, so it works as a throwaway probe rather than an
operation you have to undo.

Two deliberate limits. A digitally silent window reports no level at all rather than zero,
because silence has no decibel value and pretending otherwise is how a truncated render gets
mistaken for a quiet one. And this is not a loudness meter — the existing external loudness
cross-check stays external, since a meter cannot be used to check itself.

## 2026-08-16 — A check that was failing on the wrong view's colour

One of the header checks verifies that the "no clips to select" chip stays visually neutral —
plain secondary ink, no accent colour, no glow. It had been failing, and the tempting reading
was that the chip's colours had drifted.

They hadn't. The check grabbed the chip's source by taking everything up to the next view
declaration in the file, which is not the same thing as taking the chip. It overshot by 3413
characters into the neighbouring declaration — the cyan active-track rail — and reported that
rail's cyan as the chip's. The chip itself was, and is, correct.

It now extracts the declaration by matching its own braces, and refuses to run at all if that
extraction looks wrong in either direction: too short to contain the chip's own text, or long
enough to have swallowed the neighbour. What it asserts about the colours is unchanged, which
was the point — the easy repair was to stop looking for cyan, and that would have left a check
that could never fail again.

## 2026-08-16 — A test that guarded nothing now guards something

One of the note-editor tests claimed to check that changing only a clip's length forces the
editor to reload. It never checked that. It built its two note sets by calling the same
fixture twice, and notes get a fresh identity each time they are made — so the two sets
always differed by identity, and the reload it observed was triggered by the notes looking
different, not by the length changing at all. Deleting the length check outright left the
test green.

It is three lines shorter now and actually fails when the code it names is removed.

The method matters more than the fix: the only reliable way to tell a real test from a
decorative one is to delete the thing it claims to protect and confirm it goes red. Every
test in that file was put through it, and the other eleven earned their keep — including one
with the identical suspicious shape that turns out to be fine, because controller points
carry no identity to diverge on.

## 2026-08-16 — Turning snap off now turns it off in the note editor too

Reported from a real session: with snap off, clicking or dragging the playhead in the note
editor still dropped it on a grid line, while doing the same thing in the arrange worked
fine.

It was not a playhead bug. There were two separate snap settings. The toolbar control drove
the arrange; the note editor kept its own, defaulting to whole beats, and never read the
toolbar's. Both rendered as an identical "SNAP:" label, so there was no way to tell from
looking that you were adjusting only half the app.

There is now one policy deciding what snap applies, and turning snap off wins everywhere.
The note editor keeps its own resolution — sixteenths for notes while clips move in bars is
genuinely useful — but off means off. The editor's own chip now shows the grid actually in
force rather than the resolution you picked, since a chip reading "1/16" while nothing snaps
is the same broken promise in a quieter voice.

One thing deliberately left: the note editor's own resolution still resets when you reopen a
clip. That is a separate piece of plumbing, and your off setting is unaffected by it.

## 2026-08-16 — The loudness tool now admits what it returns

`render_measure_loudness` has always returned a loudness-range figure (EBU Tech 3342 LRA)
and never mentioned it in its own description, so an agent reading the docs would reach for
an external meter to get a number the tool was already handing it. It is documented now,
along with what LRA actually means and the fact that it is the same figure
`reference_analyze` reports — so a mix and a reference track are directly comparable on it.

A second error in the same paragraph turned out to be worse than the omission: the text said
a missing measurement meant the audio was silent. That is only sometimes true. The windowed
figures also go missing when the excerpt is shorter than their window — 400 ms for max
momentary, 3 seconds for max short-term and loudness range — so measuring a two-second
snippet drops three fields while the integrated and true-peak numbers stay perfectly
healthy. Read literally, the old text told you to diagnose that as silence.

Documentation only; no behaviour changed and nothing was added to the control surface.

## 2026-08-14 — Meme songs: a skill for turning a phrase into a track

You can now hand an agent a recording of somebody talking and ask for a song built out of
that voice — the vocal pitched into a melody and played rhythmically, rather than sung over
a backing. `.claude/skills/meme-song/SKILL.md` teaches the whole sequence, and
`scripts/meme/melody-offsets.mjs` turns a tune into the exact pitch-shift calls that play it.

The interesting part is what turned out *not* to be needed. This workflow was filed as blocked
on automatic pitch detection, which hasn't shipped. It isn't: a melody is a set of relative
intervals, so shifting one syllable by 0, +3, +5, +7, +10, +12 semitones plays a minor
pentatonic run no matter what pitch the syllable started at. Detection is needed for exactly
one thing — making the backing agree with the voice's key — and there are three ways to do
that today, the cheapest being to transpose the whole vocal set by a constant, which leaves
the melody untouched.

One ordering rule is now written down because it is easy to get wrong and fails late:
tightening the rhythm must happen before any pitching. `clip_quantize_audio` refuses a
pitch-shifted clip, not just a time-stretched one, so a melody built first is a melody that
can no longer be quantized.

Also fixed a scheduling trap. The pitch detector, the wire command that makes it usable, and
this skill were split across two milestones, and the work-order banner routed cycles to only
one of them — so the detector would have been built with nothing able to call it. All three
now sit together.

## 2026-08-13 — The built app is current again, and now carries the pitch model

Two things. The packaging script only ever copied one resource bundle, hardcoded by name — so
when the pitch model arrived it landed in a different bundle and silently never reached the built
app. It now copies every one, with a single exclusion: test bundles, which must never ship.

And `dist/DAWPro.app` was fifteen hours out of date — built this morning, before everything from
today. If you had been testing against it, none of the recent work would have been there. It is
rebuilt: 40 MB, signature verified, pitch model present and byte-identical to source.

## 2026-08-13 — The note editor no longer offers you something it won't do

Holding ⌘ near a note selection used to light up the stretch handle — while actually clicking
placed the playhead instead. The handle now retracts under ⌘ and ⇧, so what the editor shows you
and what it does are the same thing.

## 2026-08-13 — Grab the playhead and drag it, and snapping finally agrees with itself

The playhead line in the note editor can now be grabbed and dragged anywhere in the grid, not just
in the thin strip at the top. Notes always win: if one is under the pointer you grab the note, so
the playhead can never make notes unreachable by sitting on top of them.

**Snapping in the note editor now follows the same rule as the arrange**, which is what you asked
for. Previously the editor's scrub deliberately ignored your snap setting entirely — it called
itself "the pro default". With snap on, the playhead lands on the grid; with it off, anywhere you
like. Holding ⌥ gives you free positioning without changing the setting, exactly as in the arrange.
All three ways of moving the playhead — ⌘-click, dragging the line, and the strip at the top — now
go through one piece of code, so they cannot drift apart again.

## 2026-08-13 — Three tests that failed depending on your headphones

Internal only, but worth recording. Three audio-analysis tests read the sample rate from whatever
output device happened to be default, while generating their test tone at a fixed 48 kHz. Your
AirPods drop to 24 kHz whenever the microphone engages — so the tests failed whenever you were on
a call, and passed when you weren't. They now pin the rate they analyse at, and pass either way.

## 2026-08-13 — Put the playhead where you're looking

Hold ⌘ in the note editor and the cursor becomes a vertical bar; click on empty grid and the
playhead moves there. It respects your snap setting, and lands anywhere you like when snap is off.
The playhead in the track area moves with it — there's only one playhead, so nothing has to be
kept in sync.

Everything ⌘ already did still works: ⌘ on a note still adds or removes it from the selection,
⌘-dragging still draws an additive selection box, and a plain click on empty space still deselects.
Those three are the ones a change like this quietly breaks, so each has a test that fails if it
stops working.

## 2026-08-13 — Stretch and squeeze a group of notes

Select several notes, hover near either end of the selection, and a handle appears. Drag it and the
whole group scales in time — compress a phrase to fit, or stretch it out. The far end stays put, so
the handle you're holding is the only thing that moves, and the clip grows if you stretch past its
end.

Swing and triplets survive it. That sounds obvious and isn't: scaling notes individually would snap
each one to the nearest grid line and quietly straighten a swung figure into a stiff one. The whole
group is transformed as one gesture instead, and there's a test that fails the moment anyone changes
that.

Two things to know. A selection that starts at the very first beat gets a right-hand handle only —
there's no room to its left. And the handles only appear in Pro density, matching how single-note
resizing already works.

## 2026-08-13 — ⌘A selects every note in the editor

You asked for it: in the note editor, ⌘A now selects all the notes. It stays out of the way
everywhere else — inside a rename field ⌘A still selects text, because macOS hands the key to the
text field before it ever reaches us, and that was measured rather than assumed.

**One rough edge worth trying and telling me about.** Opening a clip shows the editor but doesn't
yet treat it as the surface you're working in, so the very first ⌘A after opening a clip does
nothing until you click somewhere inside the editor. After that it works every time. Making it
work immediately is a one-line change — the reason it isn't already is that a different keystroke
(Delete) uses the same "which panel are you in" rule, and having the two disagree seemed worse to
decide without asking you.

## 2026-08-13 — Pasting notes into a short clip now grows the clip

You reported this: paste a run of notes into a clip that ends before they do, and the notes went in
but the clip stayed short, so the tail never played. The clip now stretches to cover what you
pasted, in the same single undo step — one ⌘Z puts everything back.

It stops at 16 bars of growth, the same ceiling that already applied when a note is dragged past
the end, and it will never grow over a clip that follows it on the same track. If a paste lands
further out than that ceiling allows, the notes are still placed but the clip does not grow — that
case is currently silent, and telling you about it is a separate piece of work.

## 2026-08-13 — Clicking a track no longer grabs everything on it

Clicking a track header used to select every clip on that track. It now just makes the track
active — a cursor, not a grab. Nothing gets selected, so the next Delete can't take the whole
track with it.

That mattered more after yesterday's paste change: clicking a header became the way to choose
where a paste lands, which meant the most ordinary navigation gesture was quietly arming a
destructive one.

**Selecting a whole track is still there, behind ⇧ or ⌘ on the header** — and "just this track,
nothing else" is now two clicks: plain, then ⇧. One knock-on worth knowing: a plain header click
now closes an open piano roll, where before it left the roll on its clip. Hold ⇧ to keep it open.

## 2026-08-13 — You can see which track is active now

The cyan rail marking the active track had been written but never actually placed on screen — the
code that draws it existed and nothing ever called it. That is why the track you picked looked
identical to every other one. It runs down the left edge of the track card now.

This matters more than it did yesterday: paste now goes to the track you select, so being unable
to see which track that is made the feature guesswork.

## 2026-08-13 — Paste goes where you pointed

**Click a track's header, hit ⌘V, and the clip lands on that track.** Before, it went back to the
track you copied it from, whatever you had selected — which is what you reported. Selecting a track
is now treated as saying where you want things to go.

Plain copy-and-paste with no track selected is unchanged: it still lands in place, and a copy
spanning several tracks still keeps those tracks' relative positions when it moves. The distinction
the app now makes is between a track you *deliberately clicked* and one it merely inferred from
whatever clip you last touched — only the first one redirects a paste.

**One consequence worth knowing:** copy a MIDI clip, click an *audio* track's header, then paste,
and nothing lands — you get an amber note saying that track can't hold it. Previously the clip
would quietly go home to the MIDI track. Saying "that won't fit there" seems more honest than
putting it somewhere you didn't point, but tell me if you'd rather have the old behaviour back.

## 2026-08-13 — The note editor's ruler, and it turns out you already had a feature nobody could see

**The strip along the top of the note editor is now a real ruler** — bar numbers, tick marks, a
ground you can see, and a handle showing where the playhead sits. It was always there and always
worked: an 18-point transparent band you could drag to move the playhead. Being invisible, it may
as well not have existed. Nothing about how it behaves has changed; it is exactly 18 points tall
as before. You can just see it now.

Bar numbers appear at any zoom; beat numbers join them once there is room. One thing worth your
eye: the numbers count bars **within the clip** you are editing, starting at 1 — so a clip that
begins at bar 19 of the song shows "1" where the transport reads 19. That is consistent with the
grid underneath, and it is the call most likely to be wrong. Say so if it reads oddly.

## 2026-08-13 — Groundwork: the pitch engine has a runtime

Under the hood, and nothing you can click yet. Pitch correction needs a neural pitch tracker, and
that needs a machine-learning runtime inside the app. ONNX Runtime is now a pinned dependency and
runs real inference in this codebase — a test feeds it a 220 Hz tone and it answers 220.83 Hz.

**The cost, since it is worth being straight about:** the app binary goes from 17.75 MB to
37.63 MB. That is a little over double, and it is the honest post-compression number rather than
the alarming one we had been quoting — stripping debug symbols gives back about 10.8 MB of it.

Two things we learned that will shape the feature itself. The tracker can be extremely confident
and still be wrong: on a clean 440 Hz tone it reports 437.55 Hz — about a tenth of a semitone flat
— while claiming 98.5 % confidence. And how loud a sound is changes whether it lands on the right
octave at all. Both mean the eventual "fix my pitch" button needs to be more careful than
"trust the model when it says it is sure", and both were found before any of it was built.

## 2026-08-13 — Five things you asked for, and one that was quietly eating your work

**Dragging a clip past another one was destroying it.** Not dropping it there — just moving
across. The overlap rule itself was right (drop a clip on another and it overwrites, same as Logic
and Live), but it was being applied on every frame of the drag rather than at the drop, so
anything you passed over on the way got consumed about sixty times a second. Undo always brought
it back, which is why this hid for so long: the edit history looked perfectly clean. Now the move
is previewed while you drag and committed once when you release. The type that runs the drag holds
no reference to the project at all, so the per-frame version cannot come back by accident.

**⌘X / ⌘C / ⌘V now work** for clips and for notes, pasting at the playhead with the group's
internal timing preserved. They are wired through macOS's own Edit menu rather than as our own
shortcut — which matters, because a menu shortcut is checked before the text field you are typing
in, and ⌘C in a rename box would have copied the clip instead of the text.

**Clicking empty space deselects**, in both the arrange and the note editor, and the note editor
closes when the clip driving it is deselected. Holding ⇧ or ⌘ still adds to a selection, a
right-click still keeps the selection it was invoked on, and dragging from empty space still draws
a marquee.

**Audio waveforms now fill their clip.** They were drawn at raw amplitude, so anything mastered
below full scale sat as a thin ribbon down the middle — material at −12 dBFS used about 22% of the
available height. It now fills about 88% of it. Quiet passages still read as quieter, the boost is
capped so near-silence does not blow up into noise, and there is a **TRUE LEVEL** mode if you want
honest amplitude back. There is also a vertical zoom, 1× to 8×, for reading detail.

**Playback stops at the end of your material** instead of running on forever into empty bars. It
is a preference, looping still wins while a loop is active, and recording is deliberately exempt —
recording past the end of what exists is the entire point of recording.

**Also:** the Delete key fix is confirmed working. Six places in the code were still holding other
work back on the assumption that it was broken; all corrected.

**The note editor has a minimap.** A small overview in the corner of the piano roll showing every
note in the clip, where you are in it, and where the playhead is — click or drag it to jump. It is
on by default and collapses to a chip if you want it out of the way. **This one has not had a human
look at it yet:** it passes its tests, but whether it reads well on a dense clip is a question only
your eyes can answer, so tell me if it looks wrong.

**Humanize is now something you can click.** It nudges note timing and velocity off the grid by
small random amounts, for a less mechanical feel — the opposite of Quantize. It has been in the app
for a while, but only agents could reach it; there was no button anywhere. Now it is in the note
editor header and the clip's right-click menu, next to Quantize. Apply is one decisive action that
closes the panel, and the amounts stay where you set them — so undo and reopen is how you re-roll.
**Also not looked at by a human yet.**

**You can already move clips between tracks with ↑ and ↓.** Not a new feature — it has been there,
and I only found it while auditing. Select the clips and press the arrow keys, no modifier. That is
not the drag-and-drop you asked for, which is still missing, but it may unblock you today.

**Tracks now have a "you are here."** Click a track header and it becomes the active track, marked
with a cyan rail down its leading edge. It is a cursor, not a selection — it does not change what is
selected, and it does not open the note editor. Clicking a clip hands the cursor back to that clip's
track, so it follows you rather than getting stuck. **Not looked at by a human yet** — the rail's
appearance rests on code review, not on anyone seeing it.

**But it does not yet fix pasting to another track, and I want to be straight about why.** Paste has
a deliberate rule: if the tracks you copied from still exist, it pastes *in place* — back where it
came from — no matter what else is selected. That is good behaviour for the common case and it was a
settled decision, so I did not quietly override it. It does mean the active track has no effect on
an ordinary copy/paste. **There is a decision waiting for you** on whether deliberately clicking a
track header should override that, or whether cross-track paste should be its own command.

**You can drag clips between tracks now.** Pick a clip up and move it to another lane; a ghost shows
where it will land, and the move commits once when you let go — not sixty times a second on the way,
which is the bug that was eating your clips. A multi-clip selection keeps its shape rather than
collapsing onto one lane, matching what ↑/↓ already did. If a lane can't hold what you're dragging
(a MIDI clip over an audio track), the ghost simply won't cross — it doesn't refuse the whole move,
so you keep the horizontal part.

Two things I chose that you may want changed: the readout still shows only the beat, not the
destination track name; and a lane that won't accept the clip says nothing — the ghost just stops.
**No human has done this with a mouse yet.** Every automated check around it passes, but none of
them can execute a drag, so this one genuinely needs your hand.

**Not done yet:** copy/paste into a different track. I said
previously that both needed "a concept the app does not have — a selected track for actions to
target." **That was overstated.** What I measured since: paste already resolves a target track, but
it derives it from whichever *clip* is focused — so with nothing selected there is no track, and it
falls back to the first one that fits. That is exactly the behaviour you ran into. How much has to
be built on top of that is still being checked.

## 2026-08-13 — Voice conversion actually works now, and the fix travels with the app

Voice conversion has been producing noise instead of a voice. Two separate bugs, neither of them
in our code:

**One is in Apple's MLX itself.** Its `conv_transpose1d` silently leaves a large chunk of its
output blank when the output is long — about half the samples wrong on a 46-second clip. Short
clips are fine, which is why the library we build on advertises "perceptually identical" results
in good faith: they tested on 13.5 seconds, below where it breaks. We work around it by splitting
each call into shorter pieces.

**The other is in that library.** It multiplies a random-noise term by zero where the reference
implementation uses 0.66666. That noise is what gives a converted voice its breath and texture;
without it you get the conditional average of a voice, which sounds metallic and rings. The
comment directly above the line says "expanding with noise" — someone almost certainly zeroed it
to get repeatable numbers while debugging and never put it back.

With both fixed, conversion runs in **1.7 seconds for 46 seconds of audio** — about 26× realtime,
and 10× faster than the PyTorch path we were going to fall back to.

Until today those fixes only worked from the command line: the app's own voice sidecar still ran
the broken code on every machine. It now applies them at startup and reports whether they took, so
a silently-unpatched sidecar can't masquerade as a healthy one. The fixes also ship inside the app
bundle, so they travel to another laptop or a packaged build rather than only existing in a
developer's checkout.

Not fixed: the Mac App Store. The voice engine is a 1.7 GB Python process, which the App Store
sandbox does not permit. Direct distribution works.

## 2026-08-11 — A test that can now say "I don't know" instead of quietly saying "fine"

Our automated checks had a blind spot. Some of them are *preconditions* — they confirm the world is
in the state a later check assumes. One test restarts the app and then confirms your "follow the
playhead" preference survived. Before it can claim that, it has to know the old copy of the app
really shut down. If it hadn't, the test could reconnect to the *old* app and read the setting out
of the process that never restarted — and report a pass.

Until now, a failed precondition just got recorded and the test carried on, reporting the later
checks as passes. Anyone reading the results would see one failure and have no way to know it made
four other passes meaningless.

Checks can now declare what they depend on. If a precondition fails, everything resting on it is
reported as **UNKNOWN** rather than passed or failed — with a note saying which precondition
invalidated it. A check that depends on two things names both. Genuine failures are still reported
as failures; this only affects results we can no longer vouch for.

While doing this we also found that a separate long-standing complaint — that this same test had
been failing for an unknown number of cycles — has been fixed by earlier work, and confirmed it now
passes completely.


## 2026-08-11 — Adding a track while the song plays got about 50 ms faster, and we can prove it

Adding a new track in the middle of playback is one of the more expensive things the app does: it
has to rebuild the audio graph and hand every currently-playing clip back to the sound engine. We
have measured that cost for a while, and a note in one of our timing checks suggested it had
quietly improved. That was a single measurement, so it was written down as a suspicion rather than
a fact.

It is now a fact. Across eight fresh runs, the cost of that mid-playback track add has dropped by
roughly 50 ms compared with every measurement taken in mid-July — and the old and new sets of
numbers do not overlap at all, with a clear gap between them. The per-track part of the cost is
unchanged; it is the fixed overhead that got cheaper. The runs were also taken on a *busier*
machine than the original ones, so if anything the improvement is understated.

We did not change any behaviour here and we did not loosen any of the limits the check enforces —
this was a measurement, and the only edits were to the explanatory notes. One of those notes had
been quietly comparing two different things: a number this check can calculate, and a different
number measured a different way. They were never the same quantity and never should have been
compared. That is now spelled out, so the next person to read it is not misled.

## 2026-08-11 — A test that now re-checks its own assumptions instead of trusting a note

One of our visual checks watches the piano roll scroll to follow the playhead. To do that it looks
at the pixels and decides "there is a note here" by whether the ink is dark enough — a sensitivity
setting. Two different parts of that check share one sensitivity number, but they look at strips of
very different heights, so they have very different amounts of room to spare before a real note
stops registering.

That mattered for a practical reason. If a note ever *did* slip below the sensitivity threshold, the
check would fail with a message about a completely different mechanism — one that filters out the
playhead line — and send whoever read it to the wrong setting entirely.

The check now measures its own margin on every run and prints the result, and fails with a message
that names the sensitivity setting directly if the margin ever disappears. While adding that, the
measurement turned up a small correction: an older note in the code said notes stop registering
past a certain sensitivity, and they don't — they survive noticeably further, and the falloff is
gradual rather than a clean edge. The margin is about two and a half times the shipped setting
rather than one and a half. We corrected the note where it was written rather than only where it
had been quoted, and because the numbers are now re-derived on every run, that particular figure
can't quietly go stale again.

No behaviour changed: the sensitivity setting itself is untouched, and nothing about how the app
plays or draws is different.

## 2026-08-11 — The doubled note we were hunting cannot happen on the sound the test uses

Yesterday's entry ended by saying our loudness meter was blind to the thing we were trying to
detect — two copies of one note playing at once — and that we'd need to add new machinery deep in
the audio engine to see it. We went to build that machinery. It turned out not to be needed, and
the reason is more interesting than the fix would have been.

Two things were true at once, and together they looked like a single mystery.

First: the sound the test plays is a General MIDI instrument, which is handled by Apple's built-in
sampler rather than by our own synthesizer. When a MIDI instrument is told to play a note it is
already playing, the standard behaviour is to *restart* that note, not to stack a second copy on
top of it. So on the exact sound our test uses, the doubling we were hunting cannot occur at all.
We measured this directly: two copies on two separate tracks light up every meter we have, and two
copies on one track are indistinguishable from a single note.

Second: on our own built-in synthesizer, two copies of one note genuinely *do* play together — and
the loudness meter still often can't see them. Two identical notes reinforce or cancel depending on
how their waveforms line up, and at one particular alignment they sum to exactly the original
loudness. That's why the earlier measurement kept reading "no change" even in setups where a second
note was definitely sounding. Loudness was simply the wrong thing to look at. The *brightness*
reading we already publish sees it immediately — it nearly doubles.

One detail decides whether the first point actually applies to the engine rebuild, so we checked it
rather than assuming: a note only retriggers instead of stacking if both instructions reach the
*same* sampler. They do. The component that owns loaded instruments is deliberately kept outside
the audio engine's lifetime — it survives a rebuild by design, and a rebuild changes nothing that
would cause an instrument to be reloaded — so the rebuilt engine is handed back the very same
sampler, with its sound and its plugin state intact.

The practical upshot for anyone using DAW Pro: the failure that would actually hurt you is a held
note going silent when the engine rebuilds, and that has always been plainly visible to the checks
we run. The doubled-note scenario turns out to be unreachable on the standard sounds. No engine
changes were made, and none are needed.

## 2026-08-11 — Ten measurements that turned out to be measuring nothing

There's a known race deep in the audio engine: when the engine is torn down and rebuilt while
music is playing, the "stop all notes" signal sent to the old engine may not be consumed before
that engine is thrown away. If it loses that race, a note that was sounding survives into the new
engine. On the current build we believed this was harmless, and we wanted to check one specific
way it could bite: if the old note survives *and* the rebuild re-starts the same note, you'd have
two copies of one note playing at once, which would be about 3–6 dB louder.

The plan was ten runs of the existing test, comparing the loudness before and after. Ten runs, all
clean, all reading exactly the same level — no doubling. Which looked like an answer, and wasn't.

Every one of the ten runs produced byte-identical numbers. A measurement that never moves is
indistinguishable from an instrument that can't move, so before trusting it we checked the
loudness meter could actually see a doubled note. It can: two notes of the same pitch on two
separate tracks read 6.0 dB louder, right where the theory says they should.

But the same two notes on *one* track read 0.0 dB louder — no change at all, across sixteen
thousand samples. And one track is exactly the situation this race creates. So the flat reading we
got ten times over carries no information: "the signal was flushed correctly" and "the signal was
missed and the extra note vanished into the mix" produce the identical number. The test we ran
could never have told them apart.

We don't yet know what makes the second note disappear — the obvious explanation, the sampler
running out of voices and reusing one, is ruled out by the code, which has 64 voices and only
needed 2. That's now filed as its own piece of work, along with what it would actually take to
answer the original question: a way to count the notes the engine is really playing, rather than
inferring it from how loud things are.

## 2026-08-11 — Checking that the view scrolls the right way, and the note our own test was wrong about

When you press play with "follow the playhead" on, the arrangement and the piano roll scroll along to
keep the playhead in view. Our tests checked that the view moved, and that the playhead stayed on
screen. They did not check which *direction* it moved. The test counted how many different scroll
positions it saw — and a set of positions has no order, so a view that scrolled *backwards* through
the song while the music played forwards would have passed every single check.

Two new checks read the scroll positions in the order they were captured and assert they never go
backwards. On their own those would be almost worthless: a view that never moved at all also never
goes backwards. So each one sits directly under the existing "it actually moved" check and says in
writing that it is meaningless without it — if someone ever weakens that neighbour, they take this
one down with it, and now they'll know.

Which raised the harder question: if the scroll position *couldn't* report going backwards, the new
checks would pass on a broken build forever. So two more checks rewind the song to the start while
it's still playing and assert both views page back — which is what the code is documented to do, and
what nothing had ever actually driven end to end. That doubles as proof the new checks can fail.

One correction worth recording: the note that opened this work claimed *nothing anywhere* checked
scroll direction. It was written after searching for the words "monotonic", "increasing", "forward" —
and there was a direction check sitting there all along, written as a bare `>` comparison, which no
word search can see. The check was real but narrow (one surface, two points, buried in an unrelated
test), so the work still needed doing — but the claim that justified it was false.

## 2026-08-11 — A check that would have passed on an empty screenshot, and then passed by one pixel

One of the visual checks watches the piano keyboard strip down the left of the editor and asserts it
stays byte-for-byte identical while the view scrolls — that strip shouldn't move when the music
scrolls horizontally. Correct as far as it goes, but it was the wrong shape: a screenshot window
aimed at blank background is *also* identical every time. It would have passed more reliably on
nothing than on the real thing, and nothing anywhere checked the window was pointed at the keyboard
at all.

It now also asserts that the strip contains something — specifically the small cyan keyboard icon in
the editor header — and, in the same breath, that a deliberately blank slice of the same screenshot
contains nothing. Both halves are one check on purpose: a separate "the blank bit is blank" check
would have been another thing that passes on nothing, which is the problem we were fixing.

Then the interesting part. That new check passed, and it passed by one pixel. Sweeping the
measurement window down the image shows the icon registers from 110 pixels to 152, and the window
had been placed at exactly 110 — one pixel higher and it reads as empty. It would have gone green
today and started failing on any small change in how the header is laid out, for no reason connected
to the thing it is meant to catch. It has been moved to 131, the middle of that range, where it
reads nearly three times the detection threshold with about twenty pixels of room in each direction.

The general lesson is one we keep re-learning in a new costume: knowing a check passes tells you
nothing about how close it came to failing, and only a sweep tells you that. A margin is part of a
measurement, not a detail of it.

One of the visual checks looks at the piano roll and asks whether the little markers in the
controller lane line up with where the notes actually start. It reads both straight off the screen
by finding coloured stripes, which is a good way to catch the two halves of the display drifting
apart.

The trouble is that the playhead — the line showing where you are in the song — is drawn in the same
colour as the notes, and it crosses the row the check reads. So the list of "note starts" quietly
included one thing that wasn't a note start. Nothing failed because of it, but the check had become
easier to pass than intended: a marker that happened to line up with the playhead would have counted
as correct.

The fix is to tell them apart by width. A note is about 177 pixels wide on screen; the playhead is
two. That gap is wide enough that a cutoff of eight sits comfortably clear of both.

Two other ways of solving it were considered and rejected on measurement rather than taste. Ignoring
anything touching the edge of the screenshot sounds safer, but it would have thrown away a real note
that was half off-screen — and a real marker depends on that note, so the check would have started
failing for a reason that had nothing to do with the app. Working out where notes *ought* to be from
the scroll position also fails, because the scroll position lands somewhere different every run; the
playhead was the only thing standing still.

The check now also refuses to pass if the filter ever removes so much that there is nothing left to
verify, and it prints the unfiltered stripes next to the filtered ones — so if it ever does fail,
it's immediately obvious whether the filter was too greedy or the stripe was never detected at all.

That safety net needed a second attempt, and the reason is worth recording. The first version asked
"are there still at least as many note starts as there are markers to explain?" — which sounds like
it would catch the filter eating something. It doesn't. The note at the very start of the visible
area is half off-screen, and so is its marker, so losing that note removes one from each side of the
comparison and the totals still match. A deliberately over-greedy filter was run to test this, and
that check stayed green while printing the very note it had just eaten. It now also asserts that one
specific note is present by name, rather than relying on counting alone.

## 2026-08-11 — Held notes: the last untested path, and a bug we nearly deleted by mistake

Some time ago a note that was already sounding could go silent for good if the app rebuilt its audio
setup underneath it — hit a certain kind of change while the music was playing and a held pad would
just stop. That was fixed a while back. What has been happening since is slower and less glamorous:
proving the fix actually holds at every place in the code that can trigger such a rebuild, one at a
time, with a test that fails if you break it.

Four of those places are now covered by tests that play real audio and listen to the result. The
fifth is covered only by a check on the source code, and that is deliberate — the code path in
question looks unreachable, and a test that pretends to exercise an unreachable path is worse than
no test, because it reads like coverage. The test says so on its own label rather than in a comment
someone has to go find.

Two things came out of the work that were not what we went looking for.

The first is a genuine loose end in how the app tears down and rebuilds its audio engine. When the
engine is replaced, it sends a "stop all notes" message to the old one — but it can then throw that
old engine away before the message has been acted on. A note that was sounding can survive into the
new engine. Today nothing bad comes of it, because the same rebuild also re-starts the note properly
including its ending. It is written down rather than fixed, because changing teardown ordering in
real-time audio code is not something to do casually or as a side errand.

The second is a correction worth being blunt about. The original report behind all this said a pad
went silent "when I switched audio devices" — and it turned out that sentence was never something a
person said. It was our own summary of a measurement, written in quotation marks, and then quoted
back as though it were a user's words for the next nine days. Finding that out, we came close to
throwing the whole device-switch question away on the grounds that nobody could reproduce it. That
was the wrong conclusion: knowing who said something tells you nothing about whether it is true. The
measurement was real, it was never explained, and switching between two different audio devices
remains the one version of this that has never actually been tested. It is now its own open item.

Testing it properly turns out to need a second silent audio device to switch to, and this machine
only has one that is safe to touch — everything else would play sound out loud, and some of it
belongs to other apps. So that one is waiting on a decision rather than on work.

## 2026-08-11 — A test that was measuring the machine, not the app

The same follow-the-playhead check had a rule reading "the view must have scrolled to at least three
different positions during the test." That sounds like a statement about the app. It isn't. Three
positions means two page-turns, and the second page-turn only happens once the music has played for
about twelve seconds — inside a test window of fifteen. Roughly two seconds of margin. Every run we
measured landed on exactly three. A slightly busier machine would have failed the test without
anything being wrong with the software.

It now asks for two positions instead of three, which needs one page-turn at around six and a half
seconds — four times the margin, and no longer tied to how far ahead the view likes to scroll.

Worth being honest about two things. The looser rule is not free of assumptions either; it still
depends on the window size, just far less tightly, and the comment in the file now says so rather
than overclaiming. And the reason we had written down for making this change turned out to be wrong:
we thought this was the only rule left proving the view moves at all, but another rule added in the
very same round already proves that. The rule earns its place for a different reason — it is the only
one proving the view moved during the stretch the screenshots were taken from — and that reason is
now written where the next person will find it.

## 2026-08-11 — A test that had been watching the wrong pixels

Our automated check for "does the view follow the playhead while music plays" had been failing four
of its checks for weeks, on the piano roll side only. The cause turned out to be more interesting
than a stale number: **notes are drawn in exactly the same cyan as the playhead.** The check finds
the playhead by looking for that cyan in a strip of the grid that is supposed to contain no notes —
and that strip had ended up sitting directly on the row where every note in the test song lives. So
it was measuring a note and reporting it as the playhead.

Nothing about the app was broken. The instrument was.

That strip is no longer a fixed number. Every run, the check now asks the app where the grid
actually is, scans it to find which row the notes occupy, and picks a clear one — then proves it
aimed correctly before trusting anything it sees: the playhead has to move in every single frame,
and its mark has to be a two-pixel line rather than a wide block. A note sits still between page
turns and is nearly two hundred pixels wide, so either check alone catches the old mistake.

The whole thing now passes for the first time.

## 2026-08-11 — A playback test that was two seconds from failing for the wrong reason

One of our automated checks watches the view scroll to keep up with the playhead during playback, and
it insisted the view scrolled *at least twice*. That number was never the thing worth checking — it
just falls out of the window width, the zoom and how far ahead of the playhead we like to sit. Improve
any of those for good reasons and the check goes red while the app is working perfectly.

Measuring showed how close that already was. In the piano roll the view scrolled exactly twice, and
the second scroll needed about twelve seconds of playback inside a fifteen-second measurement window
that also has to absorb app launch. Roughly two seconds of margin — a slower machine would have failed
a working app.

The check now asserts only what it was really guarding: that we turn the page a handful of times
during playback rather than jerking the view on every tick. The thing the old floor was quietly
standing in for — that the playhead never slides off screen — is checked directly, and always was. A
neighbouring check already answers "did it scroll at all", and we found it has the same fragility, so
that one is written down as its own job rather than quietly patched here.

## 2026-08-11 — Triage notes for the audit tool, and a claim of ours withdrawn

The audit tool flags a handful of tests it cannot prove sound. Those flags are not all the same thing,
and the tool now says so: some are real weaknesses, and some are tests that genuinely cannot misfire
where the proof simply lives in a different function than the one being read. Treating the second kind
as the first leads to "fixes" that make a test worse, so the distinction is now written down beside the
tool with both known examples named.

We had recorded one of those tests as a third, separate kind — a case where a test passing on an empty
list was the right answer rather than an oversight. Checking that before acting on it showed it was
wrong: every place that test is called supplies a non-empty list, so the situation never arises. The
note is withdrawn and the test is filed with the others. What survived the check was more useful than
the claim: the test's guard compares two lengths to each other rather than to zero, which looks like a
safeguard and is not one on its own. That shape is now documented so nobody mistakes it for one.

## 2026-08-11 — A research note stopped quoting numbers, and its own instructions turned out not to work

One of our research notes described an audit tool and then reproduced that tool's output: totals, and a
table of every flagged spot with its line number. Those line numbers went out of date, and one stale pair
was copied into the tool's own source, where it sat until last cycle's work went to check those lines and
found unrelated code. So the table was not merely at risk of going stale — it had already exported a wrong
fact into working code. The note now carries the method and the reasoning and no numbers at all; the tool
prints its own, on demand, and cannot go stale.

Checking the note's instructions rather than just reading them turned up a second problem: the command it
told you to run did not work, and had not worked for either author who wrote it. The setting it used takes
a path interpreted relative to the script's own folder rather than the folder you are standing in, so the
obvious value silently pointed one level too deep. The plain command, with no setting at all, works fine —
and now that is what the note says, along with a warning for anyone who does need the setting.

## 2026-08-11 — A decision not to build something, and a correction to yesterday's note

Two of the tests the audit tool still flags are sound; it simply cannot prove it, because the proof lives
inside a helper function it deliberately does not read. We decided not to teach it to. Writing that down
took longer than writing the code would have, because the reason we had recorded for the decision — that
only one test would benefit — turned out to be wrong when checked. Three would. The decision holds anyway,
for a better reason: those three tests need two different kinds of cross-function reasoning, not one, and
each kind is a new way for the tool to wrongly declare a test sound. The tool's value is that when it
clears something, you can believe it.

This note also corrects the previous one. It claimed that running a single test directly left our
"which tests have actually been run" ledger un-updated, so a freshly fixed test was recorded as both
never-run and out-of-date. That was false — the ledger updates on a direct run, and says so in a comment
we did not read. The ledger is accurate and the staleness figure never moved. The original complaint that
prompted the note, about single-test runs overwriting a full run's summary, is a different file and still
stands.

## 2026-08-11 — A test that checked "nothing was trimmed" now also checks there was something to trim

The audit tool described in the last three notes found one genuinely weak test, as opposed to tests it
merely misunderstood. A check on arrow-key nudging asserted that nothing was trimmed or removed, and that
every clip kept its length — but the first two parts were about a different object, so the third would
have been satisfied by having no clips at all.

It was never actually broken: an earlier check in the same test reads the clips by position and would
have crashed first. But that protection lives in a separate statement, and a known open issue means a
failed earlier check does not stop later ones from running. The check now states its own precondition —
three clips — and its failure message reports the count and each clip's length, where before it printed
nothing about the clips at all.

Worth noting for what it is: with the test fixture as written, the new condition cannot fail today. Its
value is that the check now stands on its own, and that it will catch a future change to how the fixture
builds its clips.

The test was run before and after the change — 55 of 55 passing both times, with the leg in question a
genuine pass rather than a skip in each.

## 2026-08-11 — The audit tool now understands a test that proves itself by crashing

The last two notes described a checking tool that was excusing tests too easily. Tightening it left four
tests flagged as unexplained that were in fact perfectly sound — so this change teaches the tool the
reason they were sound, and they are quietly excused again.

The pattern is worth describing, because it is not the obvious one. Those tests never state that the list
they are checking is non-empty. Instead they reach into it — "the gap between the second and third item
is four beats" — so if the list were empty the test would crash rather than pass. Failing loudly is a
perfectly good proof of non-emptiness; it just does not look like one.

Two shapes are now recognised: reaching in by position directly, and reaching in from inside a loop over
a fixed list of expected values. The second needed care — a loop over an *empty* fixed list proves
nothing at all, so the tool checks that the list actually has entries.

Four tests are excused again. Two remain flagged and they are different from each other: one is sound for
a reason that lives inside another function, which this tool deliberately does not follow, and stays
flagged on purpose; the other is the genuinely thin check found last time, still waiting on its own fix.
Both are now written into the tool's own notes so nobody has to rediscover which is which.

Because this change makes the tool excuse *more* rather than less, the checking was inverted: rather than
proving nothing new was excused, we proved that exactly the four intended tests changed, that nothing
moved the other way, and that no other test's verdict shifted in any respect. Two of the newly handled
shapes appear nowhere in the current test suite and are covered only by purpose-built examples.

## 2026-08-11 — The audit tool no longer counts a test as its own proof

Yesterday's note described a checking tool that was excusing tests too easily, and a worse version of the
same flaw in its most-used code path. That one is now fixed.

It had been reading the surrounding source as plain text inside a fixed window. The window was wide
enough to reach into the test's own body, so a test could be counted as the evidence that it was worth
running. It also accepted any property whose name merely started with "length" — and "lengthBeats", how
long a clip is, appears throughout these tests. Between them, a test could excuse itself using nothing
more than a mention of a clip's length.

It now looks at the code's actual structure instead of its text: it skips the part of the expression the
test itself occupies, requires a real length check rather than a name that starts with one, and — as with
yesterday's fix — requires the check to be about the same list the test iterates.

Six tests were being excused on reasoning that didn't hold. Five are sound anyway, and now show up as
unexplained until we teach the tool the pattern they actually use; that follow-up is written down. The
sixth is the genuinely thin one, and it is now correctly flagged. Nothing else moved: the other
forty-three excused tests are excused for exactly the same reasons as before, and nothing in the current
test suite became *more* excused — across today's tests, the tool only got stricter.

## 2026-08-11 — An audit tool stopped accepting the wrong evidence, and we found it doing something worse

One of our automated checks looks for tests that would pass even if the thing being tested were empty —
"every item in the list is correct" is trivially true of a list with nothing in it. To avoid crying wolf,
the tool excuses such a test when a nearby line proves the list isn't empty.

It was matching that nearby line too loosely. If a test checked "every landing is on the right track",
the tool would accept a nearby line about a completely different list — the *clips*, say — as proof the
*landings* weren't empty. Both lines mention the same result object, so they looked related; they aren't.
No test in the current suite was written that way, so nothing was being wrongly excused today. The point
of fixing it is that the next test written that way would have been waved through silently.

While confirming that fix, we found the same flaw in a second, much more widely used part of the same
tool — and that one is active. It reads the surrounding source as text within a fixed window, and the
window is wide enough to reach inside the test's own body. So a test could end up counted as its own
proof. It also treated any property whose name merely *starts with* "length" as a length check, and
"lengthBeats" — how long a clip is — appears all over these tests.

Six checks in the current suite are being excused for a reason that doesn't hold. We read all six. Five
are sound anyway, for a reason worth noting: they don't state that the list is non-empty, they reach
into it by position — so on an empty list they fail loudly rather than passing quietly. The sixth is
genuinely weak, and only an earlier line in the same test keeps it honest.

So no test in the suite is silently passing when it shouldn't. But the tool's reasoning was wrong in all
six cases, and one test is thinner than it appears. Both are now written down and scheduled rather than
left as a footnote.

## 2026-08-11 — Converted vocals no longer overwrite each other, and land somewhere stable

Voice conversion is handled by a small local service that writes its result to a file and hands back
the path. It names that file using the current time to the nearest second, plus two other values that
never change while it is running. So two conversions finishing in the same second produced the same
filename, and the second silently replaced the first. Measured: twenty-four conversions produced only
seven distinct files.

A single vocal take takes far longer than a second to convert, so this was unlikely to bite one clip
at a time. It mattered for converting in batches, and for anything driving conversions in a loop —
including us: an earlier performance measurement looked reassuringly flat only because later runs were
re-reading a file that had been overwritten.

The app now copies each result to its own storage the moment it arrives, before it can issue another
conversion, under a name that cannot collide. Converted audio also now lands in the app's own folder
rather than inside the service's directory. If a copy ever fails, the conversion reports an error
rather than handing back a path that might be overwritten.

One visible consequence: the file path reported for a conversion now points at the app's copy rather
than the service's. That is the point of the change — the reported path and the audio that was
imported are now guaranteed to be the same file.

## 2026-08-11 — An audit tool was excusing a check that tests nothing

We have a tool that hunts for a specific weak spot in our automated checks: asserting "every item in
this list is correct" without first establishing the list has anything in it. An empty list passes
that test trivially, so such a check can look green while testing nothing at all.

The tool excuses a check when it finds a nearby assertion establishing the list's size. It was
matching those by name only. In one of our checks, two separate lists in unrelated blocks happened to
share a name, and the tool credited the second with the first one's size assertion — an assertion
describing a value that list never held. So a check that genuinely tests nothing was being marked
fine.

The tool now works out which declaration a name actually refers to, and only accepts a size assertion
that refers to the same one. Where it can't work that out, it now says so and flags the check rather
than excusing it.

Exactly one check changed status across all 135 the tool examines, and that is the one this was
about. Verified by keeping a record of all 135 beforehand and comparing every row — and by
constructing three deliberate examples: the tool now catches the two it should while still excusing
the legitimate pattern it exists to allow.

## 2026-08-11 — Finished reserving the alarm phrase, and added a guard so it stays reserved

An earlier fix stopped our shared check-reporting code from printing a deliberately alarming phrase
when the thing reporting wasn't actually a check. Two more places still printed it in their own
wording: the auditing tool that surveys all our checks, in both its "I couldn't read anything" and
"I found nothing to look at" messages.

Both are real warnings worth keeping loud, and both keep their wording, their exit codes and their
advice — only the reserved phrase is gone, so searching for it once again means one thing. The
judgement behind that: the phrase means "a check tested nothing and still looked fine," whereas the
auditing tool means "I scanned no files." A different claim wearing the same words is precisely what
costs somebody an investigation.

The more useful part is a guard against this recurring. The previous round of this fix checked one
message in a file and missed another a hundred and forty lines further down, which is how these two
survived. So the guard now runs the tools, drives each into its failure state, and inspects what they
actually print — plus a rule that the phrase may appear in the auditing tool only in comments, never
in something it prints. That second rule covers a message we can't easily trigger on demand. Proven
by planting the phrase into exactly that untriggerable message and confirming the guard caught it
while every other check stayed green.

## 2026-08-11 — The test harness could leave a launched app running behind it

The harness that launches the app for automated checks tracks each launch by a small file holding
the process id, and shuts everything down when the check finishes. That shutdown step remembered
only the *first* launch of a given check. A check that launched the app a second time under its own
id file would, on finishing, shut down the first one and quietly leave the second running — along
with a stale id file pointing at it.

Shutdown now covers every launch a check made, not just the first. The obvious alternative, keeping
only the most recent launch, was rejected: it moves the problem rather than fixing it, since the
first launch is never cleaned up either, so it would strand the first app instead of the second.

Fixing this also closed a related hazard. Each launch keeps its own private settings folder, and the
shutdown step looked that folder up by check name — a lookup the first shutdown erases. The second
shutdown would then have fallen back to the real application's own lock file rather than the
sandboxed one. Each launch now carries its own path explicitly, so shutdown can never reach outside
its sandbox.

No check in the current suite launches twice under its own id file, so nothing was actually
stranding processes in practice. It was fixed because the harness's whole safety guarantee is that
it only ever shuts down processes it can name exactly.

## 2026-08-11 — Fixed a slow leak in the test harness that launches the app

Our automated checks launch the app in a sandboxed copy and capture everything it prints. The code
that arranged to save that output registered a new shutdown handler every single time it launched
the app, and never removed any of them. A check that launches once or twice never noticed. Anything
that launched a dozen times in one go accumulated handlers until Node itself warned about a memory
leak — and that warning lands in the same output the checks read as evidence.

There's now a single shutdown handler that saves every launch's output from a list, instead of one
handler per launch. Verified by counting handlers across twelve launches rather than by watching for
the warning, since the warning only appears past ten and a short test would look fine either way.

Worth recording why the obvious shortcut was rejected: simply refusing to register the handler more
than once keeps the count flat and looks correct, but each handler was holding its own launch's
output, so only the first launch's log would ever be saved. That version passes a handler count and
quietly throws away eleven logs out of twelve — a worse bug than the one being fixed.

## 2026-08-11 — A warning that meant "something is broken" stopped crying wolf

Our automated checks share a small piece of common code that prints the final verdict. When a check
finishes without having actually tested anything, that code prints a deliberately alarming warning —
the point being that a check which quietly tests nothing is far more dangerous than one that fails,
because it still reports success.

The trouble was that this same piece of code is also used by a couple of tools that aren't checks at
all — a report on which checks have gone stale, and the runner that executes them. When one of those
legitimately had nothing to report, it printed the alarm word for word. It appeared in a log, someone
went looking for a broken check, and there wasn't one.

Those tools now print a differently worded message that says the same thing honestly without using
the alarm phrase, so searching for the phrase means what it's supposed to mean again. The wording is
chosen by the shared code rather than supplied by each caller, so no tool can reintroduce the alarm
by accident. The checks themselves print exactly what they printed before, character for character.

We have a suite of roughly seventy-five automated checks that exercise the app end to end. Running
all of them takes about half an hour, which in practice means they get run rarely.

Two of those checks are unusual: instead of driving the app, they run our entire unit-test suite —
one of them five times over. Timed directly, those two alone account for just under twelve minutes.
Two checks out of seventy-five, and they dominate the clock.

There's now a quick mode that leaves those two out and runs the other seventy-three. It works out
which ones to skip by reading the checks themselves and spotting the ones that launch the full test
suite, so it stays correct on its own as checks are added or changed — nothing is hardcoded.

It also refuses to be quietly wrong. It names every check it skipped and why, it prints the real
total so a partial run can never be mistaken for a complete one, it rejects an unrecognised mode
name rather than silently running everything, and if it ever finds nothing to skip it says so
loudly — because a filter that has quietly stopped working looks exactly like one with nothing to
do.

## 2026-08-11 — A checking tool that couldn't run now says so, instead of looking like a failed check

One of our internal audit tools needs a code-parsing library that isn't shipped with the project. If
that library wasn't installed, the tool crashed with a wall of technical error text and stopped with
the same failure signal it uses to report a genuine problem with the code.

That combination is worse than it sounds. Someone running the audit on a fresh copy of the project
would see a failure and have no way to tell whether the code was bad or the tool had simply never
managed to start. A broken instrument was reporting itself as a finding.

It now stops with its own distinct signal and says plainly that it could not look — that this is a
failed measurement, not a result — followed by the exact command to fix it. It also prints which
copy of the parsing library it used, and that library's version, on every single run. The tool's
conclusions depend on how that library reads code, so a result that can't be traced back to a
specific version isn't really a measurement at all.

Nothing about the app changed, and no new dependency was added to the project.

## 2026-08-11 — Every screenshot the app takes now records whether it was the frontmost window

A long-running puzzle got closed today, though not by being solved.

For months a particular screenshot our checks take had come back very slightly different from run to
run — about 94 bytes apart, out of roughly 380,000, at identical dimensions. Small, erratic, and
unexplained. Four possible causes had been named over time. All four are now ruled out, and they are
ruled out by *size*: three of them change that screenshot by thousands of bytes, which is far too
much to be the culprit. The last one, whether the app happened to be the frontmost window, turns out
to change the picture by exactly nothing — measured across eight screenshots in both states, while a
deliberate control change moved the same picture by 19,000 bytes.

So the honest summary is that the difference no longer happens and we cannot say why it once did.
The original runs came from a version of the app we can no longer reconstruct. Absence is not an
explanation, and the entry says so rather than claiming a fix.

What did ship is the instrument. Every screenshot the app takes now reports whether the app was
frontmost when it was taken. If the difference ever returns, that fact will already be recorded
beside it instead of having to be guessed at afterwards.

That instrument justified itself within the hour. The experiment meant to settle the question tried
twice to hold the app's focus steady and failed both times — nothing hands focus back to an app that
never asks for it. Both halves of the comparison had quietly become the same half. Because every
screenshot now records its own focus state, a broken controlled experiment could be salvaged as a
sound observational one, instead of returning a confident and meaningless "no difference".

## 2026-08-10 — Re-ran the window-size experiments now that they can actually vary something

With the window size finally sticking, we went back and ran the experiment it exists for.

Six of our visual checks had never been confirmed safe to run at a fixed window size. All six have
now been run twice, at two different sizes, and none of them behaves differently — so all six are
safe to pin. Three of those six had been declared safe once before; that earlier verdict came from
the broken method, so it was worth nothing until re-measured. It holds up. The other three, which
drive the song-generation model and are slow and memory-hungry, had never been measured at all.

The part worth stating plainly is the limit of what this proves. Every run passed, at both sizes. So
what we compared was two clean results against each other, and two clean results look identical
whether or not size matters. This says these six checks are safe to pin at the two sizes we tried.
It does not say window size never matters to them.

Each run now records the window size it actually started with, and we compare those recorded sizes
before trusting any comparison of the results — which is precisely the step whose absence let the
earlier round quietly measure nothing.

## 2026-08-10 — Our window-size experiments had been comparing a thing to itself

Nothing in the app changed here either. This is the second repair of the day to the checks that
guard it, and it came out of noticing that an experiment we had already trusted could not have
worked.

Some of our checks are sensitive to how big the app window is. To find out which, we run a check
twice at two different window sizes and compare. Setting the size worked — we set it, we read it
back, it was what we asked for. But every check still ran at the same default size regardless,
because starting the app deliberately wipes its saved settings so each run begins from a clean
slate. That wipe is correct and worth keeping; it just also erased the size we had set moments
earlier. So both halves of the experiment ran at the identical size, and comparing them told us
nothing at all. The results looked perfectly normal, which is the whole problem.

The size is now applied after the wipe rather than before it, so there is nothing left to undo it.
Asking for a size the app already has now says so plainly instead of quietly looking like a success,
a typo in the size stops everything before the app is even launched, and a size that fails to take
hold is treated as a wrong measurement rather than a small cosmetic miss.

Worth recording how close this came to going wrong twice. The first version of the fix worked, and
covered only 31 of our 75 checks — the other 44 open their connection to the app a different way and
silently got no size at all. It surfaced because one of those checks passed 38 out of 38 under a
setting that had never been applied to it: the passing result was identical either way, and the only
clue was a line missing from the log. Passing while a feature sits inert is not evidence the feature
works.

## 2026-08-10 — Closed a hole that let an automated check pass without checking anything

Nothing in the app itself changed today. This is about the checks that guard it.

Every one of our automated checks ended by asking a question shaped like "did anything fail?" and
reporting success when the answer was no. That sounds right, and it is wrong in one specific way: if
a check had quietly stopped running its tests altogether, nothing had failed — so it reported
success. A check that tested nothing and a check that tested everything and found no problems
produced the same green result. There was no way to tell them apart from the outside.

Sixty checks across fifty-nine files now report through a single shared piece of code that asks two
questions instead of one: how many tests ran, and how many failed. Zero tests run is no longer a
pass. It is now its own distinct outcome that says so in plain words — "this check asserted nothing"
— because staying silent about having done no work is exactly the failure we were trying to catch.

To be sure this changed nothing else, we ran all sixty-eight checks start to finish before the
change and again after, and compared them one by one rather than just comparing the totals: every
single check produced the identical result both times. Two of them are known to be failing for
reasons already being tracked, and since a failing check looks the same before and after, those two
were confirmed a second way — by checking that the individual tests inside them still came out
exactly as before.

Along the way we found three checks with a subtler version of the same problem. Each had a path
where, if the check itself crashed partway through, the crash was counted in a way the final tally
couldn't see. Depending on which way we had resolved it, that would either have made the check
report an impossible result, or — worse — swallowed the crash and turned a failing check green. All
three now record the crash as a failed test like any other.

The last check still standing outside this system was the one that hunts a specific old crash by
launching the app and hammering it ten times in a row. It had been left alone deliberately, with a
note explaining that it already used its own numbering for results and that folding it in would blur
two of them together. Reading that note against the check itself, the reasoning turned out to be
backwards. The blurring it warned about was already there, and worse than predicted: the same result
number meant both "the app never started, so this proved nothing" and "the app died halfway through"
— which is the check succeeding at the exact job it exists to do. The best possible news and the
absence of any news at all were arriving under the same label. Folding it in pulled them apart. We
confirmed it by deliberately breaking the app mid-run and watching the check report a real failure,
where before it would have reported something indistinguishable from never having started.

Four checks remained outside the system, set aside together on the grounds that bringing them in
would mean running them, and running them would mean loading the very large AI models they exercise.
Pricing that out one check at a time rather than as a group, the reason held for two of them, half
held for a third, and did not apply at all to the fourth — which never loads a model, never contacts
the real services, and stands up a small stand-in of its own instead. It had been set aside for a
cost it does not have. It is now folded in, and the remaining three are tracked separately with their
real costs written down rather than assumed. The best evidence that this was worth doing: with all
its tests disabled, that check used to report success, and now reports that it tested nothing.

A second of those checks turned out to be cheaper than its label too. It tests what the app shows you
when you ask for a song while the AI service is switched off, which means it has to actually kick the
service into starting — the expensive part. Except it doesn't wait for it: it shuts the service down
the instant it can identify it, so the model never finishes loading. Across five runs, the service
never once got as far as accepting connections, and nothing was left running afterwards. Measuring
that before committing to it turned a job budgeted at several sittings into one.

That check also had a specific way of lying. It can legitimately skip part of its work when
conditions aren't right, and it correctly refuses to count a skip as a success — but it decided its
overall result by asking only whether anything had failed. Skip everything, and nothing has failed,
so it passed. It now reports how much it actually checked, and a run that checks nothing says so.

A third check carried a warning that it could only ever be run once, because the AI service it needs
in a freshly-stopped state cannot be stopped again through the app once it has started. That is true
of the app's own stop button, but not of the service itself, which can simply be shut down directly —
which is what we are required to do after these runs anyway. So the check ran twice in one sitting,
before and after the change, and both runs exercised the part that only exists during a cold start.
The warning had made a limitation of one button sound like a law of the machine.

Bringing that one in surfaced a subtler problem worth describing, because it is the same mistake in a
new place. These checks now use a shared result code meaning "this checked nothing". That check
already used the same number to mean "the check itself crashed". Left alone, a crash would have
become indistinguishable from a run that tested nothing — the precise confusion we spent this whole
effort removing, reintroduced by the act of removing it. A crash is now recorded as a failure, like
any other. We confirmed it by deliberately crashing the check and watching the two versions disagree.

The last one is the check that proves repeated voice conversion doesn't degrade into noise. It was
brought in on its full run — two rounds of twelve real conversions plus the app-integration round —
rather than the cheap stand-in round, which was the whole reason we wrote that requirement down a
cycle earlier: taking the shortcut would have declared the check covered while the expensive parts of
it had never actually run once. Results were identical before and after, and the read-only vendored
directory it borrows from was verified untouched afterwards by two independent means.

That completes the effort. Every check the app has now reports how much it checked, and none of them
can report success after checking nothing. Two honest caveats, both of which we would rather write
down than let someone rediscover. First, this fixes checking *nothing*; it does not fix checking
*less than intended* — and we demonstrated that on a real check, which can be reduced from
fifty-three tests to thirteen by one mis-set environment variable and still reports success. It now
at least prints how many it ran, so the shortfall is visible to a reader, but nothing objects
automatically. Second, a separate family of abrupt exits scattered through these checks is untouched
and tracked on its own.

One pattern is worth recording because it outlived every individual fix. Six checks had been set
aside as too expensive or too constrained to bring in. Examined one at a time, every single one was
cheaper or less restricted than its own note claimed: one never loads a model at all, one only ever
starts a load and immediately aborts it, one was described as runnable only once when in fact only a
button was, and one was said to be already protected when it was protected on only half its paths.
Each of those notes had been read and believed for cycles. A note explaining why something was
deferred is an unverified measurement, and it gets more trusted the longer it sits there.

Nothing shipped from the next piece of work, and the reason is worth writing down. Two of these
checks take pictures of the app, so they need testing at more than one window size before anyone
relies on them. The established way to do that is to set the size in a throwaway session, then run
the check and compare. We ran both sizes. Both checks reported identical results — which looked like
the answer we wanted, and was worthless: each check also prints the window size it actually started
with, and all four runs had started at the same size. The size we set never reached them. A change
made earlier for good reasons — wiping saved settings between runs so each starts clean — also wipes
the saved window size, so the size-setting step had been quietly doing nothing.

Two right decisions that are incompatible with each other, which is the honest description of the
problem and now its own tracked item. What is worth keeping from it: had those checks not printed
the size they started at, two identical runs would have been recorded as evidence that window size
does not matter. The experiment caught itself; the small test we wrote to validate the approach
beforehand did not, because it reproduced the mechanism in miniature and the miniature differed in
exactly the way that mattered.



The app has 73 automated checks that drive a real copy of it and inspect what happens. Each one
normally runs only when someone touches the area it covers, which means a check can quietly stop
working and nobody notices. One of them records having gone through exactly that before, and says it
plainly in its own notes: a check nobody runs is indistinguishable from one that passes. How long
each of the three had been failing this time, we can't say — nothing was watching, which is the
whole point.

So we ran 69 of them back to back, start to finish. 65 passed. Three failed, and each failure was
re-run on its own afterwards to make sure it was real and not just interference from the checks
running before it. All three were real.

**The one that looked like it affected you — and turned out not to.** A check about renaming failed:
when you type in a rename field and press Delete, the app is supposed to notice you are editing text
and leave your selected clip alone. The check reported that something in the deletion path was still
running when it shouldn't be, and our first reading was that this might destroy clips.

It doesn't. We went and measured it rather than guessing. The check had a blind spot — at the moment
it looked, there were no clips left to lose, so its safety test was comparing nothing to nothing. We
fixed that blind spot first, put a real clip there, selected it, and pressed Delete with the rename
field focused. **The clip survives.** The app guards this in two independent places, and the second
one does its job even when the first has already stepped aside.

So the fault was in the test, not the app — the test was watching a counter that only records "a
keystroke arrived here", and treating it as if it recorded "something was deleted". Those became
different numbers when a separate keyboard fix landed recently, and nothing re-ran this check
afterwards to notice. Your clips were never at risk, and no change to the app was needed.

The check has now been corrected, and it gained a new part that records the true behaviour — that the
keystroke does reach the app and is then turned away — so nobody re-reads the old number as a fault
again. It also caught a stale note elsewhere in the code still claiming the keyboard never worked this
way; that is tracked separately. The full suite of 5338 automated tests passes.

**The other two were bookkeeping, not bugs.** One check counts the app's remote-control commands and
expects 173; there are now 174, because recently added voice-model importing added one. The count is
right about the last saved version of the code and only disagrees with work that hasn't been saved
yet, so we deliberately left it alone rather than editing it to match. The other tracks which checks
adjust panel sizing, and had drifted by one.

Four further checks were deliberately left out of this run: two of them load a 54 GB audio model, and
they contradict each other — each needs that model switched off when it starts, and each switches it
on. They cannot both work in a single pass, so they are run by hand. That is now tracked too.

**And then the tool we use to measure all of this declared itself untrustworthy — correctly.** It
works by reading every check's source code and sorting each one into a category. To prove it can
still tell those categories apart, it had been pointed at three real checks known to be in a
particular state, and it refused to report anything at all if it got them wrong. The trouble is that
this week's work moved all three out of that state on purpose. The tool was checking itself against a
condition the project had just finished eliminating, so it failed — not because it was broken, but
because it had succeeded.

It now proves itself against small examples written for that purpose, one per category, which cannot
go stale when the real checks change. But swapping in self-written examples introduces a subtler
danger, and guarding against it is the more important half of this fix: a tool that proves itself
only against its own examples would still pass every one of them while reading none of the real
checks — reporting a clean result about nothing at all. That is precisely the flaw described at the
top of this entry, reappearing inside the instrument built to find it. So it now also insists it
actually read something real before it will report anything, and it says which of the two situations
it is in rather than failing the same way for both.

**A check can also pass while quietly declining to test part of what it covers.** Some of our checks
need a person — whether a menu item looks right, whether a real key press travels the way a simulated
one does. Rather than guess, those parts announce themselves as skipped and the check carries on. That
is the honest behaviour and we want to keep it. The problem was on the reporting side: a skipped part
is neither a pass nor a failure, so it left no trace in the result, and a run that skipped work
reported the same clean line as one that did all of it.

Runs now report skipped work alongside the result — currently 28 skipped parts across 11 checks. The
count is deliberately reported with its denominator, because the more useful finding was how few
checks say anything about this at all: 13 of 73. The other 60 are not known to be skip-free; they are
simply silent, and a number that quietly leaves them out would imply otherwise. Skipped work still
does not count as failure, and nothing about whether a check passes has changed.

The count is assembled two independent ways — from what each check reports about itself, and from the
individual announcements — which are then compared. That comparison is the point rather than a
finishing touch: this exact figure was previously measured as 38, and the error surfaced only because
one check's own total disagreed with the tally taken from its output.

**Finally, the rule from the top of this entry is now enforced automatically, and enforcing it turned
up one more check with the original flaw.** Fixing sixty checks by hand fixes them once; nothing
stopped the next new check from being written the old way, which is how sixty accumulated in the first
place. A new check now reads every other check and fails if any of them decides its own result without
going through the shared code.

Writing it surfaced a check that had been missed. It reported its result indirectly — handing the
outcome to a shared cleanup routine that exited on its behalf — so the earlier survey, which looked
for the decision being made in place, could not see it. It had the exact flaw described above: had it
somehow tested nothing, it would have reported success. It has been corrected, and its result now
comes out the same way every other check's does.

Seven checks are formally excused. Four need a large model loaded to run at all; two are waiting on
work already scheduled; one already refuses to pass without testing anything, by its own separate
route. Each exemption names the task that will remove it, and the enforcing check fails if an excused
check is later fixed without its exemption being deleted — so the list cannot quietly outlive the
problem it was written for.


We also looked at making the whole suite of checks run on a schedule, so nobody has to remember to
start it. We are not going to do that, and the reason is worth writing down: seventy-three of our
seventy-four checks work by launching the actual app, and there is no way to run it invisibly. A
scheduled run would open the app seventy-three times, on its own, on the machine you make music on.
That is not a setting anyone would want us to pick a good default for, so we did not build it at
all — not even switched off, because a switched-off feature reads as a finished one.

What we built instead answers the question the schedule was meant to answer, and it answers it
faster. There is now a check that takes about a second and tells you which checks have never been
run, and which ones have been edited since they last ran — the second group being the ones whose
last green result no longer describes the code that is in the file today. It names them, one by one,
rather than just counting them, because a number is easy to skim past and a list of names is not. It
runs as part of the normal development routine, which is a thing that already happens, rather than
waiting on a timer that nobody set.

Each check now records that it ran, at the moment it reports its result, so this stays accurate by
itself as work goes on. That bookkeeping is deliberately unable to affect anything: we tested it
against a full disk, a read-only folder and a path that was not writable at all, and in every case
the check still reported exactly what it would have reported otherwise, down to the byte. A note
about the bookkeeping failing goes to the error log and nowhere else. It would be a poor trade to
gain a coverage report and lose the ability to trust a green result, so the recording is wired to
lose that argument every time.

The record is kept per check rather than per run. That matters because running a single check used
to overwrite the record of everything else, which had already destroyed one set of results earlier
this week. Now running one check updates one line and leaves the rest untouched — which is a
property of how it is stored, not a rule someone has to remember.

One limitation, stated plainly: seven checks still cannot report their own coverage, because they are
the seven that were formally excused above and never reach the shared reporting code. They will show
as never-run no matter how often they are run. The two tasks already scheduled to fix those
exemptions will fix this at the same time; it is not a separate problem, and it is not a new one.


Separately: some of our test commands quietly changed a setting nobody asked them to change. Opening
the effects editor from a test also switched the mixer panel to its detailed view — and left it that
way. That setting is one you own; the app remembers it between launches. So a test run could change
how your mixer looked, and nothing in the test said it had.

Both of the safeguards we already had were blind to this by construction. One only remembers panels a
test explicitly says it is going to change; the other only looks at tests that ask for a density
change in the first place. A panel changed sideways, through some other command, is invisible to
both. The fix records every panel setting before a test runs and puts them all back afterwards,
including removing ones the test invented — so a setting you never had does not survive the test that
created it.

We proved it the honest way, by running two tests and comparing. The unprotected one changed the
mixer setting and left it changed. The protected one, doing the same thing twenty-two times over, left
it exactly as it found it. The protection also refuses to guess: if it cannot read the current
settings properly, it stops rather than assuming there were none — assuming none would have meant
erasing all of them, which would be a far worse bug than the one it was written to fix.

Two related things we found and wrote down rather than quietly fixing. The same problem affects two
more tests we have not protected yet, and we confirmed that by measurement rather than assuming it.
And more broadly, our tests share their saved settings with the copy of the app you actually use —
we noticed a test run had moved where the app's window opens. We put it back, and that wider issue is
now written down as its own piece of work rather than patched setting by setting.


Follow-up: two more of our tests had the same problem, and we checked rather than assumed. One we had
already suspected; the other we had written down as unconfirmed, and it turned out to be leaking too.
A third we had assumed was fine genuinely is fine — we ran it to be sure instead of taking our own
earlier word for it. Both leaking tests now restore your panel settings the way the others do, and
both still pass.


The bigger fix behind those two: our tests no longer share their saved settings with the copy of the
app you use. They used to write into exactly the same place your own preferences live, which is how a
test run was able to move where your window opens — that one was not even our code doing it, it was
the system's own window-position memory, so no amount of tidying up individual settings could have
caught it.

Tests now run under a different name, which gives them their own separate store of settings. Everything
they save goes there instead, including the things the system saves on their behalf without asking us.
Your own settings are untouched, and we verified that by comparing the file byte for byte before and
after — along with a deliberately corrupted copy, to prove the comparison would have noticed if
anything had changed.

The per-setting protections we added earlier are still in place. They are now redundant, and we are
leaving them there anyway until the new approach has more time behind it.


And a test that checks the tests: it launches the app, makes it save a setting, and then confirms your
own preferences file is byte-for-byte what it was. It proves it is capable of noticing a change first,
by planting one deliberately and catching it — a check that has never been seen to fail at anything is
not worth much. It also checks the specific thing that started all this: that the window position the
system saves on the app's behalf now lands in the test's own store rather than yours.

To prove it is watching a real target rather than an empty one, it launches a second, throwaway copy
under a different name and confirms it notices that copy's writes. The tempting alternative — switch
the protection off and check that something breaks — was rejected: when that test worked, it would do
so by writing into your real settings, which is the thing being protected.


Then we ran the whole suite and compared it against the last full run from before any of this, one test
at a time rather than just comparing totals. Seventy-one tests, and your own settings file came out of
it byte-for-byte identical — which is the thing we actually wanted to prove, and which would not have
been true a day ago.

The comparison earned its keep immediately: it found one test we had broken. Giving the tests their own
name meant one of them could no longer find the app it was trying to drive, because it had the old name
written into it. Everything else about that test looked fine, and it would have kept looking fine — it
only surfaced because we compared the full before and after picture rather than checking that things
still broadly passed. It is fixed, and the name is now derived in one place instead of written down in
two.

**And it solved a five-day-old mystery.** One test takes a picture of the editor, undoes an edit, and
takes another picture to prove the undo repainted the screen exactly as it was. That test worked, but
it had a note attached recording something nobody could explain: the picture it took came out slightly
different each time it ran — three different file sizes across eleven runs, with no pattern. The note
guessed the cause was the window size being remembered somewhere outside the test's control, and
admitted it was a guess.

The guess was half right, and the half it got wrong is the interesting half. The window size was never
it — the test pins the window and the dimensions were identical every time. The culprit was the same
shared settings file, holding things the test does not pin: how tall the editor pane is, how tall the
rows are, how far you are zoomed in. Another test would leave one of those changed, and the next run of
this one would inherit it and draw a slightly different picture.

It now runs identically every time. We were careful not to let a clean streak stand in for a proper
explanation, because running the same test fifteen times in a row with nothing in between is exactly
the situation where the old setup would also have looked clean. So we checked it the other way round:
we deliberately planted a leftover value in the settings — the same thing another test would have
done — confirmed it was really there, and ran. The picture came out identical to every other run,
because the settings are now wiped and reset before each one. We also confirmed the picture genuinely
does respond to those settings, so that "identical every time" means something rather than nothing.

We did not pin the exact picture as the expected answer, deliberately. A change already queued will
alter it on purpose, and an expected answer that goes stale the moment you look away is worse than
none.

**The tests now run against the app as it ships, not as this machine happens to be set up.** When we
gave the tests their own settings, we filled those settings with a snapshot of whatever this
particular Mac was already using. That was deliberate — it let us make the change without altering
what any test saw. But it left the tests running against one developer's preferences rather than
against what a new user actually gets.

We have now emptied that snapshot down to a single entry. Everything else falls back to the app's own
shipped defaults.

Before doing it we worked out, key by key, which settings would actually change. Sixteen entries were
removed; only six of them differ from what the app ships. The rest — panel widths, zoom levels, row
heights, three on/off switches, the assistant's model — had been captured at values identical to the
defaults, so removing them changes nothing. Knowing that in advance turned the whole exercise from
guesswork into checking predictions, and it meant we could tell a real problem from an expected
change immediately.

The six that do differ all concern how densely panels are packed. The tests had been running with six
of seven panels in the denser "pro" layout, while a new user gets the simpler one.

One test genuinely broke, and it is a real flaw worth having found: it measures a strip along the
bottom of the window, but never specified which layout the transport bar should be in. It had been
passing because of a setting it never asked for. We have not patched over it — loosening the
measurement until it passes would gut the very check that gives the test its meaning — so it is
written up to be fixed properly.

One more failed for an amusing reason: a test that verifies the settings isolation was itself
checking, as part of its setup, that a particular setting held a particular value — the value that
had just been removed. It was asserting the contents of the snapshot rather than the behaviour it
exists to prove. Fixed so it can't go stale against that snapshot again, in either direction.

Two others failed only when the whole suite ran at once and passed cleanly on their own — ordinary
timing sensitivity under load. We checked that claim rather than assuming it: the same
run-it-alone method still reproduced the genuine failure above, so it is a real test and not a way of
making everything look fine.

Your own settings files came through all of it byte-for-byte unchanged, verified with a check we
first proved capable of detecting a single flipped byte.

**The app can now say which settings file it is writing to.** Until today, the way we confirmed the
tests were writing somewhere separate from your settings was to ask the operating system what the
test process was called, and reason from there. That is an inference about the app rather than a
statement by it. There is now a diagnostic the app answers directly: which name it is running under,
whether it has a bundle identity, and which preferences domain it therefore persists to.

Two details we were careful about. The answer distinguishes what is *derived* from what is
*measured* — the domain name is worked out from the app's identity, so it is labelled that way, and
a separate optional check actually looks a key up through both paths and reports whether they agree.
That second part refuses to report agreement when the key was never written in the first place,
which would otherwise be a comparison of nothing against nothing that always looks fine.

The isolation test now asks both the operating system and the app the same question and requires the
answers to match. Two independent instruments, because a single one cannot notice its own mistake.
The diagnostic is strictly read-only — a check whose job is proving the app does not write where it
shouldn't must not itself write anywhere.

**Two more checks moved onto the shared reporting code.** Continuing the work at the top of this
entry: two checks that were still deciding pass-or-fail their own way now go through the shared
piece that also asks "how many tests actually ran". One of them turned out to have exactly the
weakness that piece exists to catch — its self-test would have reported success if its list of
fixtures were ever emptied, because nothing had failed. It now says it tested nothing instead.

One of the two needed a judgement rather than a mechanical change. It had its own numbering for how
it reports outcomes, and one of those outcomes — a test run that came back red — was filed under
"could not score this" rather than "this failed". A red run is a failure, and reporting it as though
the check had done no work would have been the precise defect this whole effort is meant to remove.
That one outcome was reclassified; the rest were left exactly as they were.

We checked that reclassification could not confuse anything downstream, and the first reason we came
up with for why it was safe turned out to be wrong — a search that appeared to prove the check wasn't
used anywhere was actually a search that found nothing at all. The real reason it is safe is that the
thing consuming these results only ever distinguishes success from failure, not one kind of failure
from another.

A latent problem surfaced along the way and is written up rather than quietly patched: one check
reports the line numbers where it finds issues, and those numbers drift out of alignment whenever the
file contains a multi-line comment, because of how it strips comments before scanning. It has been
handing out coordinates that point a few lines off.

**That one is now fixed, and it was worse than it first looked.** The check removes comments before
scanning, and removing a multi-line comment was also removing the line breaks inside it — so every
line number it reported after that point was short by however many lines the comment spanned. It had
been telling us line 529 for something that actually sits at line 536.

The reason to spend real time on this rather than nudge the one number: we checked every file it
scans instead of only the file where the problem turned up. Seventeen of eighty-nine were affected,
and the worst was off by three hundred and twenty-seven lines — far enough that a reported location
would land in an entirely different part of the file. A tool that hands out coordinates and gets them
wrong generates bad references faster than anyone can chase them down, and misleading line numbers
have cost us real investigations before.

All eighty-nine now report accurately. We confirmed the fix changed nothing else — the check finds
exactly the same problems it found before, only now with the right addresses — and confirmed our
measurement could actually tell a real fix from a no-op before trusting it.

## 2026-08-10 — Voice conversion no longer degrades the more you use it

Converting the same vocal a few times in a row used to get progressively louder and more distorted,
until by the fourth or fifth conversion the output was pinned against the ceiling and audibly
crushed. Nothing you did caused it — the audio engine was reusing graphics-card memory it hadn't
finished writing, so each conversion inherited a little more garbage from the last.

Measured, before and after, on twelve conversions in a row: the level used to climb by a factor of
twelve and peak at 0.99 (with true peak actually past full scale); it now stays flat, varying by
0.03%. The engine clears that memory before every conversion. Conversions cost about 0.03 s more
each, and the engine now takes about half a second longer to start — but it loads faster on the
first conversion, so in practice you get that back.

**One thing to know.** The fix is applied when the app starts the voice engine. If you started the
engine yourself from a terminal, the app can't apply it, and conversions will still degrade. The
app now detects exactly that case — but only an AI assistant asking about engine status currently
sees the warning; it isn't shown in the Voice panel yet. Stopping and restarting the engine from
the app applies the fix.

**A separate problem found along the way, not yet fixed.** The voice engine names its output files
using a timestamp accurate only to the second, so conversions finishing within the same second
overwrite each other — twenty-four conversions produced seven files in testing. A single vocal take
takes longer than a second to convert, so ordinary use is unaffected; the risk is batch conversion.
It's tracked and will be fixed separately. Until then, if you convert several short clips in rapid
succession, check you got every file.

## 2026-08-10 — Half the voice-conversion model was random noise (found, corrected, not yet shipped)

The voice model has four "normalising flow" layers that shape the converted voice. Two of them —
the 2nd and the 4th — were never actually loaded from the trained model file. They were filled with
fresh random numbers every single time the model loaded, which means voice conversion produced a
slightly different result on every run and none of them used the weights that had been trained.

The cause was a one-line disagreement between two pieces of the vendored engine: the file that
converts models and the file that loads them number the layers differently, and only the loader
runs. Layer 0 is the one place the two agree, which is why every smoke test looked fine.

There is now a corrector that fixes a model file's layer names without touching a single byte of
the actual weights, plus a gate that proves it: the broken model fails 6 checks and produces a
different fingerprint on every load; the corrected one passes all of them and produces the same
fingerprint every time, in separate processes.

**This is not in your hands yet, and it is worth being plain about that.** The corrected model has
to actually reach the app, and the one voice currently available takes a code path that our own
settings cannot redirect. Which of three routes to take is a decision waiting on you. There is also
a loudness caveat: the corrected model runs about 10 dB hotter, leaving roughly 1.2 dB of headroom.
It did not clip in testing, but that was one test signal, not a library — so a listening check comes
before this ships.

## 2026-08-09 — The Delete key works the same way every time

Pressing Delete used to be a coin flip. Three different parts of the app each claimed the key —
the piano roll, the arrange area and the automation lane — and which one actually got it depended
on where the keyboard focus happened to have landed. Focus moved every time you selected a clip,
so the same keystroke could do different things on consecutive presses: sometimes it deleted the
notes you had selected, sometimes it appeared to do nothing at all, and in one case it deleted the
whole clip out from under the notes you were actually pointing at.

All three now ask the same question the Edit menu already asked — what are you pointing at? — and
act on that answer. Notes when the piano roll is open with a selection, automation points when a
lane holds one, clips otherwise. Where focus sits no longer changes the outcome, and Delete can no
longer remove a clip when what you had selected was the notes inside it.

## 2026-08-09 — Copy and paste for clips and notes

There was no way to copy anything. Not a clip, not a note, not a phrase you wanted twice.

Now the Edit menu and the right-click menus carry Cut, Copy and Paste, and they know what you are
pointing at: notes when the piano roll is open with a selection, clips otherwise. Paste lands at the
playhead, keeps the internal timing of whatever you copied, and puts clips back on the tracks they
came from where those still exist. Pasting a phrase that would start before the beginning slides the
whole group forward together rather than stacking its first notes on top of each other.

Each paste is its own undo step, even one made immediately after an edit.

There are deliberately no keyboard shortcuts yet. A menu shortcut outranks text fields on macOS, and
this app still has an unexplained keyboard bug open, so the shortcuts wait until that is understood
rather than shipping on top of it.

## 2026-08-09 — Drag a box around notes in the piano roll

Selecting several notes meant clicking each one with shift held. There was no way to sweep a box
over a phrase and grab it, the way you already can over clips in the arrange view.

Now you can. Press on empty grid and drag: a band follows the pointer and selects every note it
touches, additively if you hold shift or command. A plain click still deselects, exactly as before —
the band only arms once the pointer has actually travelled, so nothing you already do has changed.

Dragging the selection also got fixed, and it needed to. Moving several notes at once used to snap
each note to the grid independently, so notes sitting slightly off the beat relative to each other
were quietly welded onto the same line — a groove flattened by moving it. The group now translates
rigidly: a phrase keeps its internal timing wherever you drop it. This was always broken; it was
just hard to notice while selections were built one click at a time.

## 2026-08-09 — Imported MIDI files keep their instruments, and drums get a step grid

Load a multi-part MIDI file and every track used to arrive on the same default poly synth, all
sharing the song's title as their name. A 13-part orchestration imported as thirteen tracks called
"Bohemian Rhapsody", none of which sounded like what the file said they were.

The file had been read correctly the whole time — the piano, the fingered bass, the string ensemble,
the drum kit, both distortion guitars were all sitting in the import report. They were just thrown
away before they reached your tracks. Instrument assignment was switched off by default, from a time
when nobody had measured what turning it on would cost, and the code that gives two parts distinct
names could never fire on the single-track file format that needs it most.

Both are fixed. An imported file now arrives with the General MIDI instrument each part asked for,
and tracks are named for what they play — "Alto Sax", "Timpani", "Standard Drum Kit", and where two
parts share an instrument, "Distortion Guitar (ch 9)" and "Distortion Guitar (ch 12)". Loading all
thirteen instruments takes 161 ms. Pass `instruments: "none"` if you want the old behaviour.

Separately, the clip editor has a second mode. Select a clip on a drum track and it opens as a step
grid instead of a piano roll: one row per drum, named for the drum ("Closed Hi Hat", "Acoustic
Snare"), one column per step. Click a box to place a hit, click it again to remove it — the same
gesture for both, so it is also a way to delete notes that does not depend on the keyboard. Any MIDI
clip can be switched to it by hand. It edits the same notes the piano roll does, through the same
undo history.

## 2026-08-05 — A typo in a song-generation request no longer costs you a generation

The three tools that generate things by calling an outside service — lyrics, a full song, an
image — took their settings without checking the spelling. A misspelled setting was quietly
thrown away and the job ran anyway, with that setting simply absent.

Ask for a song and misspell "lyrics" as "lyric", and you got a song generated with no lyrics
at all. No warning, no error, nothing to indicate the words had been dropped on the floor —
just a finished generation that wasn't what you asked for, and a real charge for it.

Every other operation in the app already refuses an unrecognized setting and tells you which
one it didn't recognize. These three were the last that didn't, because they talk to the
outside service directly and skipped the check everything else goes through. They now do the
same thing as everything else: the request is refused up front, before anything is generated
or charged, and the error names the setting it didn't recognize.

## 2026-08-05 — "I can't do word timings" and "I couldn't tell" are now different answers

Speech models come in two shapes on disk. One kind can be inspected: you can read what it
produces and know whether it can place individual words in time. The other kind cannot be
inspected at all — the file layout simply doesn't expose it.

Until now those two collapsed into the same optimistic answer. A model that genuinely could
not do word timings, and a model nobody could ask, both reported "yes, it can" — and if the
word list came back empty, there was no way to tell which had happened.

Transcriptions now say which of the three it is: the model said yes, the model said no, or
nothing could be asked. The optimistic default is unchanged on purpose — a model that cannot
be inspected is still treated as capable, because refusing to try on a guess would nag about
every model of that shape, capable or not.

The one case that used to be silent now speaks: when a model could not be inspected, produced
speech, and still returned no words, the transcription explains that this is exactly the
situation where the missing piece would show up. When there was nothing to transcribe, or the
words came back fine, it stays quiet — the note appears only when it would actually help.

## 2026-08-05 — Transcription now tells you when a model can't do word timings

Placing lyrics on the beat grid needs word-level timings, and those come from a piece of data
baked into some downloaded speech models but not others. When it was missing, nothing failed:
the transcription came back with no words at all, no error, and nothing in the log. For a
feature whose entire purpose is putting words on beats, that is a total failure wearing the
costume of an empty result.

The model you have installed does have it, so nothing was broken — the exposure was that
installing a different variant could silently take the feature away.

Speech models are now inspected when they are found, and each one reports whether it can
produce word timings. A model that cannot says so in plain language, naming the model, where
it was found, and what is missing. It stays perfectly usable for plain transcription; the
limitation is reported, never enforced.

One deliberate choice worth stating: when a model is packaged in a form that does not let us
ask the question at all, we assume it can. The alternative would warn on every model of that
kind, including capable ones, which teaches people to ignore the warning. The rule is that we
only ever say no when the model itself said no — so that shape remains uncovered, and we have
written it down rather than quietly counting it as handled.

## 2026-08-05 — A test that passed because it had nothing to check

One of our automated display tests watches the playhead — the moving line that shows where
you are in a song — and confirms it stays on screen while the music plays. It did this by
taking a burst of screenshots for fifteen seconds and then asserting that the line was
visible in *every* one of them.

The flaw is in the word "every". If the burst had captured no screenshots at all, then the
line was visible in every one of them, trivially, and the test passed while checking
nothing. The number of screenshots taken was printed in the log but never actually checked,
and how many get taken depends on how busy the machine is — each one is a full-resolution
capture plus six image crops, racing a fixed fifteen-second budget.

This was never observed happening: on an unloaded machine the burst captures around eight
screenshots, and it would take a severely overloaded one to starve it. We fixed it anyway,
because the failure is silent by construction — the test would have reported success, and
nothing in its output would have hinted that it had stopped looking. It now refuses to
grade the run at all unless the burst captured enough frames to be meaningful.

We also checked the rest of that test suite for the same shape. Four other places that could
have had this problem turned out to already guard against it, in one case with the reasoning
written directly into the test: "an empty scan passes everything." Roughly three dozen
further candidates remain unexamined and are queued for review; we are not claiming the
sweep is finished.

## 2026-08-05 — A developer script that erased your session by default

While widening the search described in the entry below, we found a test script in the
repository that connected to your *live* session unless you explicitly told it otherwise —
and the first thing it did after connecting was start a new project, discarding whatever you
had not saved. It then armed a track and recorded over it. This needed no unusual setup: it
was what running the script as documented did.

The script's own opening comment said it should be run against a scratch copy of the app.
The code directly beneath it did the opposite. It now defaults to the scratch copy, and it
refuses to target your live session even if explicitly asked. Both behaviours were checked
by running it — once with the dangerous setting, confirming it stops before opening any
connection, and once with nothing set, confirming it goes to the scratch port.

## 2026-08-05 — A test that could fail because you plugged in headphones

One of our audio-device tests asked the system for the list of output devices twice and
compared the two answers against each other. If a device appeared or vanished in the
fraction of a second between the two questions — a dock waking up, a headset connecting, a
call starting — the two lists came back different lengths and the test failed, even though
nothing was wrong with the app. It now takes a single snapshot of the devices and checks
that against itself, so a device list that changes underneath it cannot make it fail. A
second test in the same file had the same shape and got the same treatment.

Checking that fix turned up something more interesting than the flake. The repaired test
only actually caught the fault it exists to catch because of an accident of this machine:
it used the *first* output device as its subject, and on this machine the first device is
not the default one. On a machine where those happen to be the same device, the test would
have passed while checking nothing at all — a green light that certifies an empty room. It
now checks every device rather than one, so it no longer depends on what order your
hardware happens to be listed in.

## 2026-08-05 — Test scripts can no longer be pointed at your live session by accident

> **Correction, same day.** As first written, this entry claimed eighteen further checks
> were an unguarded route to your live session. **That was wrong — they are guarded, and
> always were.** Each one hands its port to the shared start-up code, whose second
> instruction is the very refusal we thought it was bypassing; running one with the
> dangerous setting stops it dead before it launches or connects anything. We verified that
> by actually running two of them. The genuine problem described in the entry above this
> one — a script that erased your session by default — was real and is fixed. The paragraph
> below has been corrected accordingly.

Our automated checks drive a throwaway copy of the app on a private port, never the session
you are working in. Three of those checks still carried an old switch that let a setting in
your shell choose the port instead. That switch could not actually have reached your work —
the shared connection code refuses your live session's port outright and stops — but it was
a loaded gun left on the table for whoever edited those files next, and it made searching
for the real version of this problem return false matches. It is gone.

Eighteen further checks read a *differently named* setting and open their own connection.
We initially read that as the same fault on a larger scale. It is not: every one of them
passes that setting through the shared start-up code first, which refuses your live
session's port before anything is launched or connected. Those checks are not read-only —
they add tracks, drag clips, select and delete — so we confirmed this by running two of
them with the dangerous setting rather than reasoning about it, and both stopped
immediately. Rewriting those eighteen to drop the setting altogether is still worth doing so
the next person does not lose a day to the same false alarm, but it is tidying, not a repair.

The lesson worth keeping cuts both ways, and we managed to land on both sides of it in two
days. It is about how the first three were cleared. That earlier check
asked "does anything here build a connection address out of this value?", found nothing,
and concluded the code was dead. It wasn't. The value was being handed to a shared helper
that built the address inside itself, where no search for that pattern could ever see it.
The conclusion happened to be right, but for a reason the check never tested — so the same
evidence would have produced the same reassuring answer over a genuine hazard. Follow the
value, not the shape of the thing you expect to find.

And then we did the mirror image of it. The eighteen were flagged as unguarded on exactly
the same kind of evidence — a search for the refusal's *name* inside each file, which found
nothing because the refusal is reached by handing the value onward, one layer down. Same
mistake, opposite conclusion, one day apart, inside the very item the first one created. A
rule you have just written down is not a rule you have learned; and a search you have
already corrected once is the one you stop questioning.

## 2026-08-05 — The voice-conversion engine's Stop had the same fault, and it is fixed too

The fix below, for the song-generation engine, turned out to describe the voice-conversion engine word
for word: its Stop control also looked only at the small file recording the process ID, and so also
announced "was not running" about an engine that was running, answering, and holding its models in
memory. Same fault, different engine.

Rather than repair it twice, both Stop controls now share one implementation — the same rule about
where to look, the same refusal to signal a process it cannot confirm, the same insistence on
reporting a failure as a failure. Only two things differ between them: how each recognises its own
engine, and the wording it speaks to you in. Recognising the voice-conversion engine needed more care
than the song one: its name is three letters that occur in plenty of unrelated programs, so it is
identified by the folder it was installed in and, failing that, by a much narrower pattern — never by
those three letters alone. If something on its port cannot be confirmed, it is named and left running,
not killed.

## 2026-08-05 — Stopping the song-generation engine actually stops it

The Stop control for the local song-generation engine could fail and tell you it had succeeded. If the
small file recording the engine's process ID went out of date — which happens after a crash, or when
the engine is restarted outside the app — Stop looked only at that file, decided nothing was running,
and reported "was not running". Meanwhile the engine was still there, still answering, still holding
tens of gigabytes of loaded models. The one screen that could have told you the truth, the status
readout, was looking somewhere else entirely and correctly showed it as healthy.

Stop now looks where the status readout looks. If the recorded process ID is missing or out of date, it
finds the process actually answering on the engine's port and stops that one, including the child
process holding the models. When it genuinely cannot stop something that is demonstrably running, it
says so and tells you the command to run, instead of claiming success. It will not, under any
circumstances, signal a process it cannot confirm is the engine — if something else is using that
port, it says which process and leaves it alone.

## 2026-08-05 — Test runs no longer leave the music model loaded in memory

One of the automated checks starts the local music-generation engine on purpose, to confirm the app
narrates the startup properly. It never stopped it again. That engine holds around 75 GB of memory
while the usual tools report it as using about one — so a check that took a few seconds could leave
your machine short of memory for the rest of the day, and nothing said so.

It now shuts down exactly what it started, and only that: if you had the engine running yourself, the
check leaves it strictly alone. The same check had also been reporting success no matter what it
found, so a genuine problem in this area would have been announced as a pass.

## 2026-08-05 — Development runs no longer share a folder with your work

DAW Pro keeps your autosaves, recordings, imported audio and diagnostic reports in one folder under
Application Support. Every automated test that launched a copy of the app was using **that same folder** —
your folder. Most of what it left behind was clutter, but one file was not: the small marker the app writes
while it is running, which is how it knows on the next launch whether it crashed. A test run replaced yours.
If you had DAW Pro open at the time, it could offer to recover from a crash that never happened, and
closing the app cleanly afterwards would not undo it.

A copy of the app launched for testing now gets a scratch folder of its own, so it cannot see or touch
anything of yours. Nothing about your installed app changes: with no test harness involved it reads and
writes exactly where it always did, and it refuses to start rather than quietly fall back to your folder if
it is ever pointed somewhere it cannot use. Nothing already in your folder was moved, changed or deleted.

## 2026-08-05 — Exporting audio is in the File menu, where you went looking for it

Rendering your song to a file was reachable from exactly one place: a small chip in the transport bar at
the bottom of the window. That is not where anyone looks for it, and it is not where any other DAW keeps
it — and the same bar is already carrying more controls than it comfortably fits.

**File ▸ Export Audio…** now opens the same export dialog. It sits next to Export MIDI…, and it greys out
when the project has no tracks yet, because there would be nothing to render.

It is the same dialog, opened by the same code path as the transport chip — not a second export that could
one day drift from the first. And it deliberately has no keyboard shortcut yet: there is an open question
about how key presses reach this app, and adding another key path before that is understood would make
both harder to diagnose.

## 2026-08-05 — An assistant can see how loud each track is without reading the whole song

Until now there was no cheap way to ask "how does this mix sit?". The levels existed — the engine has been
measuring every track all along — but the only place they surfaced was the full project snapshot, which is
enormous. An assistant orienting itself between edits either paid that cost or worked blind, and in
practice it worked blind. That is how a song can come back technically correct and musically wrong: the
master hits its loudness target while the kick sits thirty decibels above the lead, and nothing in the
loop notices until a person listens.

The lightweight project overview now carries a peak and RMS level for each track, in decibels. It is the
same reading the meters show, and it costs nothing extra to fetch.

One detail matters more than it looks. Meters go dark the moment you press stop — deliberately, because a
meter that stays lit when nothing is playing is lying to you. But an assistant reads the project *between*
actions, which is exactly when the transport is stopped, so the obvious version of this feature would have
reported silence on every track and looked like it was working. The overview therefore reports the last
level a track was actually heard at, which survives stopping. A track that has never made a sound reports
nothing at all, rather than reporting silence — "not measured" and "measured as quiet" are different
answers, and only one of them should make you reach for the fader.

The master bus reports its level the same way, next to the master volume it already carried. On their own the per-track numbers are just numbers — "the kick peaks at −6" is not a judgement about anything until you know where the song as a whole is sitting. With both, "the lead is at −41" becomes "the lead is thirty decibels under the mix", and the second one tells you to reach for a fader. Both readings come from the same single piece of arithmetic, so the master and the tracks can
never quietly disagree about what a decibel is.

## 2026-08-04 — The limiter can now count the peaks that matter for delivery

The limiter's ceiling has always been honest about one thing and silent about another. It guarantees no
single sample goes above the ceiling you set, and it does that by construction — it cannot fail. What it
never measured is what happens *between* samples, which is what a streaming service or a mastering house
actually checks. Those two numbers are not the same, and on dense material they can differ by nearly two
decibels.

That gap has a real cost. If you are trying to hit a delivery target, the only way to find the right
ceiling was to render, measure the file somewhere else, lower the ceiling, and render again — and the
number you converge on is a guess about how much headroom to leave, not a setting that means anything.

The limiter now has a true-peak mode. Turn it on and the ceiling counts the peaks a delivery spec counts,
so you can set it to your actual target and stop guessing. Measured with an outside tool rather than our
own meter: at a −1 dB ceiling, off it overshoots to +0.92, on it lands at −1.00.

It is off by default and every existing project is untouched — verified sample-for-sample against the old
algorithm, not approximately. Turning it on costs about a twentieth of a decibel of loudness and buys back
close to half a decibel of headroom.

One limit stated plainly, because a limiter that quietly over-promises is worse than one that does not
try: the detection is an approximation, and it is most accurate on normal musical material and least
accurate on material with a lot of energy right at the top of the audible range. On a deliberately
punishing test signal it reads about 0.4 dB low. That worst case lives in the test suite so the limit is a
number rather than a promise.

Also fixed while in there: the documentation described the limiter as having a true-peak ceiling when it
did not. That single wrong line is very likely what sent someone chasing an imaginary bug.

## 2026-08-04 — Two ways to delete anything, and sound that comes back the instant you press play

Deleting a clip or a note had exactly one route: the Delete key. If that key was not reaching the
editor — and there is reason to think it sometimes was not — there was no other way to do it. Not a
hidden one, not an awkward one. None. The most common destructive operation in the whole app rested on
its most fragile input path.

It now has three routes. Right-click a clip and Delete is the first thing in the menu, before any of the
fade and quantize entries, and it is there in the simple density too, where it is the only entry there
is. The note editor has a right-click menu for the first time. And the Edit menu has a Delete that knows
what you are looking at — it names the notes, the automation points or the clips it is about to remove,
and greys out and says so when there is nothing selected.

That Edit item deliberately has no keyboard shortcut. Giving it one would take Backspace away from every
field in the app where you rename something, which is a worse bug than the one being fixed.

Separately: pausing and resuming used to drop any note that was already sounding. On a long pad the
effect was that the sound simply stopped and did not return until the next bar started it again — which
on that kind of part can be a long, silent wait. Audio clips never had this problem, because resuming
one just seeks back into the file; only played notes did. Pressing play now picks up notes that are
already meant to be sounding, the way other DAWs do. Measured on a real rendered file rather than
inferred: the pad is audibly there on resume where before it was silence.

One gap left honestly open: this covers the play button, not dragging the ruler while the music is
already rolling. That case still drops the note, and making the two agree is a design question rather
than a copy-paste.

## 2026-08-04 — The same misspelling problem, found in a second place and traced to its root

Yesterday's fix covered one internal inspection command. Looking at its neighbours turned up the same
shape in the command that stages the generation-progress card — and this one was worse, because it did
not merely ignore the misspelled word. It substituted a different value and reported success.

Ask it to stage a row from an imported file, misspell the word "origin", and it would stage the row as
if it had come from somewhere else entirely, and tell you it worked. Anyone using that card to check
how generation was being tracked would have been reading a fact they had not asked for.

The root cause is worth saying plainly, because it is not really about that one word. A setting you
are *required* to provide gets checked for free — if it is missing, nothing can proceed. A setting
that is *optional* has a fallback, and a misspelling looks exactly like choosing not to provide it. So
every optional setting on that command had the same hole, not just the one we noticed. One of them is
worse still: leaving out the job identifier is a deliberate, meaningful choice, which made a typo
there indistinguishable from intent.

All of them now fail by name. Two related holes turned up while fixing it: passing the wrong *kind* of
value entirely was silently ignored, and — a problem the fix itself introduced — a request that was
about to be refused could still clear the card before refusing. That second one matters more than it
sounds. Adding a new refusal to the middle of an existing sequence can leave a request half-applied
when it was never half-applied before. Everything is now checked before anything is changed, and a
refused request leaves the card exactly as it found it.

Verified against a running copy: seventeen checks, including the specific misspellings measured
earlier, and — the part that matters — the card itself is inspected afterwards rather than trusting
what the command said about itself.

## 2026-08-04 — A misspelled setting now says so instead of pretending to work

The same internal inspection command we fixed yesterday had one more way to mislead. Ask it to scroll
to a particular track and misspell the setting name — `trackID` instead of `trackId`, a capital letter
apart — and it would answer "done" without doing anything. Not because it disagreed with you, but
because it had no idea the word was meant for it.

This is the milder half of a problem we fixed earlier: before that fix, a typo scrolled to the wrong
place, which at least you could see. Afterwards it quietly did nothing and reported success, which you
could not. Safer, and still wrong — a tool that answers "yes" to a question it did not understand is
worse than one that answers wrongly, because there is nothing to notice.

It now names the word it did not recognise and lists the ones it does. Asking with no settings at all
is still a plain read, and still changes nothing — that is a legitimate way to use it and it keeps
working exactly as before.

We checked the fix against a running copy of the app rather than only in tests: four kinds of
misspelling are now refused by name, and — the part that matters — the view provably did not move on
any of them. Checking that the command *reported* failure would not have been enough, since reporting
success while doing nothing was the entire bug.

Every other inspection command of this kind was surveyed at the same time. None of them can be made to
change something by accident, which was the serious version of this problem. One does have a related
rough edge — a mistyped option falls back to a default instead of complaining — and it is written down
to fix next.

## 2026-08-04 — Our own tests had been quietly filling your disk

Running the test suite wrote audio files into your real application-support folder — about three per
run, every run, for a long time. There are now 2745 of them there, taking 1.8 GB.

The cause was a small design slip. Tests are supposed to redirect that folder somewhere temporary,
and the code offered a way to do exactly that — but it was something each test had to remember to
switch on. Any test that forgot wrote to your disk instead, silently, and nothing ever complained.
The default now redirects itself when it detects it is running under test, so forgetting is no longer
possible. Outside of tests nothing changes: the app writes exactly where it always did.

We confirmed this by counting your folder before and after a full test run — 2783 entries both times,
where it used to grow — and then confirmed the files had *moved* rather than merely stopped, by
finding them in the temporary location. A fix that made the writes vanish entirely would have looked
identical on the first check and been a different bug.

**The 1.8 GB already there is untouched and is yours to decide about.** We have not deleted anything.
That folder also holds real material you generated, mixed in with the test spill, so it is not a
folder anything should clear wholesale — separating the two is a conversation, not a cleanup script.

One neighbouring folder was examined and deliberately left alone: the recordings folder has the same
shape of exposure but does not actually leak, and some of its contents may be your own aborted takes.
We could not tell for certain, which is exactly why we did not touch it.

## 2026-08-04 — A diagnostic that moved the thing it was asked to report

One of our internal inspection commands could be asked "where is the arrange view scrolled to?" — and
answering that question scrolled the view to the bottom. Anyone using it to check the state of the
screen was therefore changing that state, and then measuring the change they had just caused. It is
hard to imagine a worse property in a tool whose entire job is to observe.

Asked with no arguments it is now a genuine read: it reports where things are and touches nothing.
Asked to scroll, it still scrolls. It also now reports the horizontal position, which it never could
before, and says plainly that there is no numeric vertical position to report rather than quietly
leaving the field out. Each answer carries a counter that ticks only when something actually moved,
so "did that change anything?" is now a question you can answer by looking, instead of by trusting.

We checked every existing use before changing it; none depended on the old behaviour. One rough edge
remains and is written down rather than glossed over: a misspelled argument is currently treated as
a read instead of being rejected, so a typo fails quietly. Elsewhere in the codebase we already
reject unknown arguments by name, and this should match.

## 2026-08-04 — The export was rendering a sound you had never heard

A user wrote in about their AI-generated trance project: in the app it played back thin and quiet,
with barely anything but drums, while the WAV they exported sounded full and right. Their words were
the clearest possible statement of what a DAW owes you — *"I should hear the same true sound that
would be exported."*

They were hearing two different songs, and both of them were ours.

When you load a plug-in instrument like Surge XT, the patch it is playing lives inside the plug-in,
not inside your project file. Nothing copies it back as you work. Turn a knob in the plug-in's own
window, or have the AI adjust a parameter, and the project file still remembers whatever was there
the last time you saved. Live playback asks the plug-in what it sounds like. Every export — mixdown,
bounce, stems, and the loudness measurement the mastering tools rely on — asked the project file
instead. So the moment those two disagreed, which was most of the time, your export was a rendering
of a patch you had never listened to.

We proved it rather than reasoned about it. With a bass track playing, we turned that plug-in's
master volume all the way down and exported: the file came out at exactly the level it had before,
as if nothing had happened. Then we saved the project — saving *does* ask the plug-in — reopened it,
and exported again. Silence. The change had been real all along; the export simply could not see it.

Now every export reads the same source the save does. What you hear is what you get, by
construction. After the fix that same test exports silence, matching what the track actually sounds
like, and a full mix of the reference project measures within 0.04 dB of what the app plays through
your speakers.

There is a second thing this uncovered, and it is the reason the report took so long to run down.
When a track's instrument cannot be loaded — the plug-in isn't installed, or it fails, or it takes
too long — we quietly wired that track to silence and said nothing. No message, no warning, nothing
in the interface. The loudest track in a song could disappear with no explanation available
anywhere. That is over: a track that cannot host its instrument now tells you so by name, and tells
you what to do about it.

One correction worth recording, because it inverts the original diagnosis. We had assumed the
quiet playback was the broken one and the good-sounding export was correct. It was the other way
around: that export sounded good because the plug-ins were falling back to their factory default
patches. The quiet mix is the honest sound of the patches actually saved in the project. Fixing the
disagreement is the fix; it does not make the song louder, and we would have been wrong to make it.

## 2026-08-04 — A teardown that reported success and did nothing, and a bug report we have not solved yet

> Written earlier the same day. The quiet-playback problem described at the end of this entry was
> traced and fixed later — see "The export was rendering a sound you had never heard" above. This
> entry is left as written, because it records what we knew at the time and two of the explanations
> in it turned out to be wrong.

Our test harness has two functions that look almost identical at a glance. One takes a bag of
options — `startStaging({ gate, port })`. The other takes plain positional arguments —
`stopStaging(gate, pidfile)`. Anyone reading them quickly will eventually write the first shape
where the second belongs, and pass a bag of options where a name was expected.

When that happened, nothing complained. The teardown built a file path with the word
`[object Object]` in the middle of it, looked for that file, did not find it, and returned as
though it had finished cleanly. No process was stopped. No lock was released. The one guard meant
to catch this asked only whether the argument was *missing* — and a bag of options is not missing,
so it sailed straight through. The only reason no test run ever leaked a stray app is that a
separate safety net, written by someone else for another purpose, quietly did the real cleanup.

Both functions now refuse anything that is not a proper name, and say so loudly, naming the two
signatures so the next person sees the confusion immediately instead of debugging a phantom. We
checked all 79 places that call this and every one of them was already correct — this protects
future code, not existing code. We also confirmed the fix by running the *old* version alongside
the new one and watching it reproduce the bug, because a test that passes tells you nothing unless
you have seen it fail.

Closing it turned up the same flaw one argument over, in the second parameter, still unguarded and
reachable through the exact two-argument form much of the suite already uses. That is now written
down as its own piece of work rather than quietly patched, and Node already warns that a future
version may turn that silent shrug into a hard error.

The same flaw turned out to live in the next argument along, and then the one after that. Fixing
the first exposed the second; fixing the second exposed a third, where the consequence finally
escapes the test harness — a lock file that fails to be cleaned up can make the app later offer you
a recovery prompt for a session that ended perfectly cleanly. Two of the three are fixed and the
third is written down. We are fixing them one at a time and confirming each against a controlled
copy, rather than making three changes at once and hoping.

All three are now fixed. The third one turned out to need more than a stricter check on the way in.
We had been rejecting anything that was not a plain non-empty piece of text — but a piece of text can
still be an impossible filename, and one of those slipped through the check and crashed exactly the
same way. So the error handling underneath was split too: a genuine mistake in the code now surfaces
loudly, while the ordinary cases it was written for — a missing lock file, an unreadable one, a
garbled one — still behave exactly as before and still refuse to guess at ownership.

That last part was the delicate bit. The "garbled file" case happens to fail in a way that looks
identical to a programming mistake, so a careless split would have made the safe case start throwing.
It was kept separate deliberately, and we tested that a garbled lock, a lock owned by someone else,
and a lock whose owner is recorded oddly all still leave the file untouched.

One honest limit worth stating: about ten places wrap this teardown in a "ignore any error" block.
There, our new loud complaint is swallowed and becomes a different quiet failure. A guard is only
as loud as the place that calls it.

Separately, and more importantly: we are still chasing the reported problem where a project sounds
correct when exported but too quiet when played back in the app. We thought we had it this week and
said so. We were wrong — the measurement that convinced us was taken a fraction of a second after
opening the project, before the instruments had finished loading, so a counter that was merely
*early* was read as *never*. Reading the same counter a few seconds later showed everything
loading normally. The underlying complaint is real and reproducible to within a hundredth of a
decibel, and the investigation continues; we would rather say that plainly than offer a third
confident explanation.

## 2026-08-04 — A second timing check that was quietly grading its own homework, and what we found replacing it

Five days ago we raised how long a test process is allowed to wait for a plug-in to finish loading,
from 10 seconds to 60, because 10 was too tight for a slow instrument under a busy test suite. At
the time we added a note next to it: "60 seconds is roughly double the worst load we have ever
measured, so there is real headroom." That note was itself a test — it asserted the 60-second limit
was at least twice a fixed number written into the same file.

It turned out both halves of that check were made up. The "worst we have ever measured" was a
number typed in once and never updated; the "at least twice" comparison was two constants compared
against each other, which can never fail no matter what the app actually does — it wasn't measuring
anything. And when we went and actually measured, the real margin had already fallen under 2x:
the worst clean load we could produce came in at just under 31 seconds, leaving about 1.94x, not
2x. Nothing was broken by this — the 60-second limit itself is still nowhere close to being hit —
but the thing that was supposed to warn us before it got close had never been capable of warning
anyone about anything.

So we deleted it, the same call we made with a similar check three weeks ago, and replaced it with
something that actually watches the real number. Loading a General MIDI sound bank now prints how
long it took, how much horizon it had, and the ratio between them, on every test run. A new check
runs that measurement five times in a row and refuses to be quiet if the slowest run gets within
60% of the 60-second limit. A separate, permanent check confirms nothing in the app is allowed to
hold the interface hostage for a fixed stretch of time without being on a short, explicit list —
today that list has exactly two entries, both deliberate test scaffolding, each measured down to
the millisecond.

Turning that new check on told us something uncomfortable: run for real, twice, on this machine
today, it failed both times — the slowest load came in at 45–47 seconds instead of 31. Some of that
is very likely an unusually busy shared machine rather than the app getting slower; load was
running high enough during the second attempt that unrelated background activity is a real
suspect. But we are not going to wave that away either, and we are not going to raise the limit to
make the red go away — that is exactly the mistake that put us here in the first place. The honest
state is: the new check works, it catches slow loads for real, and whether today's slow numbers are
"the machine was busy" or "the margin has actually run out" needs a re-run on a quiet machine before
anyone concludes either way. That follow-up is filed, not skipped.

One more thing came out of building the check itself, which matters more than it sounds: the
guardrail meant to keep an unusually busy test run from being graded at all — skip the whole
result if the run as a whole took suspiciously long — let one of today's slow, failing runs through
as legitimate. That is a real gap in how the two limits were tuned together, also filed, and it is
better evidence that something needs re-deriving than either of the two failing runs was on its
own.

## 2026-08-03 — When a plug-in freezes the app, you can now find out which one, and for how long

A badly-behaved plug-in can freeze the app's interface while it loads. We've had detection for
that for a while: ask the app anything during a freeze and it answers, off to the side, "the
interface is wedged, and has been for N seconds." True, and not much use — it doesn't tell you
*what* it's stuck on.

Now it does. During a freeze, asking for AU prepare status returns which plug-in is currently
being loaded, how long it's been loading, and whether it has already blown its deadline. That
answer comes from a small record kept outside the frozen part of the app, so it stays readable
while everything else is stuck.

The gap this closes is sharper than it sounds: the command that reports plug-in loading health
was, until now, **unable to answer during exactly the freeze it would be most useful in** — it
had to go through the frozen part of the app to fetch its reply. Measured before the fix, that
request sat waiting out the entire freeze and answered a fraction of a millisecond after it
ended. It now answers in microseconds, while the freeze is still going.

**What this does not do.** It does not unfreeze anything, and we want to be blunt about that: you
cannot interrupt a thread that is sitting inside someone else's code. The app still waits for the
plug-in to let go. This is diagnosis, not rescue — the real fix is running plug-ins outside our
process entirely, which is a much larger piece of work.

It also doesn't announce itself yet. Right now you have to ask; nothing writes the fact to a log
on its own. That part is written up and deliberately left for a follow-up rather than half-built
here.

## 2026-08-03 — The five-second limit on opening a plug-in window now actually works

When you open a plug-in's window, we ask the plug-in to hand us its interface and give it five
seconds to answer. If it doesn't, we show our own generic panel instead, with a note explaining
why. That's the design: opening a plug-in should never hang the app.

The countdown was scheduled on the same queue as everything else in the interface. So whenever the
app was busy — which is precisely when a plug-in is slow to answer — the countdown couldn't run
either. It wasn't a five-second limit; it was five seconds of sleep *plus* however long it took to
get a turn. In practice it almost never fired. A slow plug-in didn't get cut off at five seconds,
it just made you wait, and then its window opened late.

The countdown now runs off to the side, on real wall-clock time, so it fires when it says it will.

**You may notice this.** A plug-in that used to open late will now sometimes give you our generic
panel and a "custom view request timed out after 5s" note instead of its own interface. That looks
like something got worse, so it's worth being clear: this is the limit doing the job it was always
supposed to do. We deliberately did not raise the five seconds to paper over it — a slower broken
deadline is not a fixed one.

One honest limit remains. We can now *decide* on time that a plug-in has taken too long, but
actually putting the window on screen still needs the app to be responsive. A plug-in that freezes
the app outright will still hold everything up until it lets go. That's a separate, harder problem
and it's tracked.

Internally this was the last corner of the app running its own private copy of this
timeout logic; there's now a single shared implementation, with tests that make it hard to
reintroduce a second one.

## 2026-08-03 — A measurement that would have reported success while the thing it measures was broken

Nothing you can see changed. This closes out a review of every timing check in our test suite, and
the last one had the same shape as the others: it could not fail.

The check measures how long it takes the app to hand a dense burst of MIDI — 512 controller
messages in a single audio block — to a hosted plug-in. It compared that against a generous upper
limit, and the number sat about two thousand times under it. So far, so harmless. But we tested what
happens if the app stops forwarding MIDI to the plug-in altogether — the exact failure the check
exists to notice — and it stayed green. With no messages being delivered, the measured cost drops to
nearly nothing, and "nearly nothing" comfortably satisfies a check that only asks for "not too much."

We nearly got the fix wrong in an instructive way. The obvious lower limit is "the cost must not be
zero." But when we actually broke the code rather than imagining it, the broken version did not
measure zero — it measured a small residual, because the app still walks the list of messages before
discarding them. A limit chosen against the imagined failure would have let the real one through.
The limit we shipped sits between the two measured values, with roughly equal room on either side.

A companion check turned out to need nothing at all. We deliberately broke the code it guards and it
failed loudly and immediately, which is all one can ask of it; we recorded how we broke it, next to
the check, so the next person does not have to work it out again.

Two things were filed rather than fixed in passing. One test crashes outright instead of failing
when its subject regresses, which silently cancels every test queued behind it — worse than an
ordinary failure, because the run looks short rather than truncated. And one measurement documents
a performance target that nothing enforces.

Across all six checks reviewed: one was deleted, three needed no change, and two gained the missing
half of their reasoning. None were converted to the comparison-based form we originally planned for
all of them — in every case, measurement said it would not have helped.

## 2026-08-03 — A safety check that would have blamed your machine for its own failure

Nothing you can see changed, but this one is worth reading, because the thing we found was hiding
behind a reassuring message.

Some background. When the app loads a plug-in, that work has to happen on the same single thread
that draws the interface. A badly-behaved plug-in can seize that thread and not give it back, which
is why we put a hard time limit on the operation. The subtlety is that the timer itself must not
need that thread — otherwise the timer cannot ring in exactly the situation it exists for. We fixed
that a few days ago, and wrote a test to make sure it never regresses.

We checked whether that test actually works, by deliberately re-breaking the code and watching what
it said. It failed — but it reported "the machine was too starved to run the experiment, which is
not the same as the experiment failing." In other words, faced with the exact fault it was built to
catch, the test blamed the computer it was running on. That is the kind of message that gets waved
through as a bad day on the build machine, and the real fault would have sailed past.

The reason is a little chain of consequences we had not followed all the way down. When the timer
is broken, no measurement ever completes in time to be counted, so the test ends up with an empty
set of results — and every check that examines those results is skipped entirely. All that remained
was a final complaint about not having gathered enough data.

Two smaller things came out of it. The test's own notes contained a claim and its refutation six
lines apart, each stated confidently. And the actual broken behaviour is not what either of us
predicted: we expected the timer to ring late, but it never rings at all, because the work it was
racing gets to the finish line first the instant the thread is released.

The test now recognises the real fault and says so, in its own words, before it says anything about
the machine. We confirmed that by breaking the code again and watching the new message appear, then
putting the code back exactly as it was. The old message is still there and still means what it
says — it just no longer speaks for a failure that is not its own.

## 2026-08-03 — A planned improvement, measured and then declined

Nothing you can see changed, and this time nothing in the code changed either. It is recorded
because the decision not to act was the work.

We had a plan to make several of our internal timing checks more robust, by measuring each one
against a reference task running at the same moment instead of against a fixed number of seconds.
The idea is sound: if the machine is busy, both slow down together, so the comparison holds steady
where a fixed number would drift.

Applied to one particular check — how long it takes to analyse a five-minute piece of audio for
tempo and key — it turned out to make things worse. The check was already steady: across fourteen
runs, some on an idle machine and some with the entire test suite running, its measurement moved by
about 8%. The reference task we would have compared it against is itself far less steady than that;
its own recorded wobble is roughly 40%, and over 100% when the machine is deliberately overloaded.
We would have been replacing a reliable ruler with a rubber one.

So the check was left exactly as it was, and the reasoning was written down next to it. The
general rule we took away: a comparison-based measurement is only worth it when the interference
you are cancelling is larger than the wobble you are introducing, and both of those are things you
can measure beforehand rather than assume.

One genuine gap was found along the way and filed rather than patched in passing: the same test
documents a target of "two seconds typical" that nothing actually enforces — only the five-second
hard limit is checked. Enforcing it looks feasible but needs a deliberate stress test first, on
exactly the principle above.

## 2026-08-03 — A test that was one bad run from crying wolf, deleted rather than retuned

Nothing you can see changed. This is about a timing check inside our own test suite, and it is
recorded because the reasoning is the kind that goes stale quietly.

One test measured how long it takes to load an instrument's sounds while deliberately hammering the
app from several directions at once, then asserted the typical load stayed under 8 seconds. That
8-second figure was not arbitrary — it was written as "four times the worst we have ever measured,
and still comfortably under the 10-second cutoff where a load gets abandoned."

Both halves of that sentence had quietly stopped being true. The cutoff is no longer 10 seconds
inside tests — it became 60 seconds five days ago, and the comment never caught up. And the "worst we
have ever measured" had crept from 2.0 seconds to 4.6. Re-applying the original rule to today's
numbers demands a limit of 18.5 seconds — but loads actually start failing outright somewhere
around 6 to 13 seconds. There is no number that satisfies both halves any more. The rule that
produced 8 seconds had stopped having an answer.

So the check was removed rather than given a fresh number. It was never the real safety net: a load
that genuinely hangs already fails a different, sharper check with a much clearer message. What it
was actually doing was sitting close enough to normal variation that one ordinary slow run would
have made it fail for no reason — and a test that fails for no reason teaches everyone to ignore it.

What replaced it is smaller and firmer. The remaining check watches the *fastest* load rather than
the typical one, which barely moves no matter how busy the machine is. And it now has a companion
test that deliberately breaks the code to prove the check actually catches it — because a limit
nobody has ever seen trip is a limit nobody has really calibrated. The measurement itself is still
printed on every run, so the history stays visible; only the brittle assertion is gone.

## 2026-08-03 — Clicking an empty track's header now says something

Clicking a track's header selects every clip on that track. On a track with no clips there was
nothing to light up, so the click looked like it had been swallowed — you clicked, and the app did
not move.

It had not been swallowed. That click quietly moved the keyboard onto the arrangement and took the
zoom keys (⌘+ / ⌘− / ⌘0) back from the piano roll, so the next key you pressed went somewhere new
without anything on screen saying so.

Now a brief line appears on the row you clicked, at its right-hand edge — "No clips to select" — and
fades after a few seconds. It is deliberately plain grey rather than the amber the app uses for
refused edits: nothing was rejected and nothing was lost, the click simply had nothing to select.

It only appears when there is genuinely nothing to show. Clicking an empty track's header while
clips are selected elsewhere clears that selection and closes the note editor — a large, visible
change — so no message appears there. Nor does one appear when you click a track whose clips are
already selected: those clips are on screen, selected, exactly as you asked.

Nothing about selection itself changed. A track is still not a thing you can select; the line is a
passing note, not a state, and it leaves nothing behind on the row.

## 2026-08-03 — A delete that gets refused now points at the clip that refused it

Select a whole track by its header, press Delete, and if any clip on that track belongs to a take
group the app refuses the whole delete — one comp member spares everything, including clips on other
tracks you selected at the same time. That part is deliberate: a delete that half-happened inside a
single undo step would be worse than one that did not happen.

What was wrong was where the app told you about it. The amber "this clip belongs to take group…"
bubble appeared over an essentially random clip in the selection — usually not the take-group clip
at all, and not even the same clip twice, since it changed from one launch to the next. You were
being pointed at an innocent clip and told it was the problem.

The bubble now appears on a clip that actually refused, and when several did, always on the same one
— the first, reading the arrangement top to bottom and left to right. Nothing else about the refusal
changed: the wording is identical, the delete is still all-or-nothing, and a single-clip refusal
behaves exactly as before.

One honest limit: if the clip that refused is scrolled off the side of the arrangement, the bubble is
correct but out of sight. The app does not scroll to it yet.


### Zoom keys now follow the editor you are actually working in

⌘+ / ⌘− / ⌘0 used to be routed by whether the piano roll held keyboard focus, which was not
something the app decided — it was the outcome of the arrangement and the roll competing for focus.
In practice the result flipped from one clip click to the next, and clicking the same MIDI clip
twice left the zoom keys aimed at the arrangement for the rest of the session.

The zoom keys now follow the surface you last worked in: click a clip and ⌘+ zooms the arrangement;
click into the piano roll and it zooms the roll. Closing the roll or switching to the mixer hands
the keys back to the arrangement. The piano roll's zoom-button tooltips now say "after you click in
the editor" instead of "while the editor is focused", which describes a rule the app no longer uses.

Deleting and nudging clips are unchanged — those still go to the arrangement after a clip click.

## 2026-08-03 — Selecting more clips while the note editor is open now hands the keyboard back to the arrangement

Open a MIDI clip, select some notes in the piano roll, then shift-click two more
clips in the arrangement and press the right arrow. Until now: nothing happened.
Delete was worse — it deleted the notes rather than the three clips you had just
selected. Both were the app doing exactly what it had been told, and neither was
what anyone meant.

The rule that caused it is a good one and it stays: while you have notes selected
in the editor, the arrow keys and Delete belong to the notes, so a stray keypress
cannot slide a whole clip out from under you. The problem was that selecting more
clips never took that claim back. Now it does — the moment your selection grows
past the clip the editor is open on, the editor drops its note selection and the
keys go back to the arrangement, where you were plainly looking.

The editor stays open, and nothing else about it changes. If you then select notes
again on purpose, with all three clips still selected, you keep them and the arrow
keys go back to the notes: at that point you have said what you want twice, and
the app should not argue. Selecting a whole track by its header behaves the same
way as shift-clicking, because it is the same thing — selecting more clips.

## 2026-08-03 — The up and down arrow keys move clips between tracks

Select some clips in the arrangement and press the up or down arrow: they move to
the track above or below, keeping their spacing and their positions in time. This
is the last piece of the cross-track move — the ability landed in the engine, then
on the agent-facing commands, and now on the keyboard where you actually reach for
it. Holding the key repeats, like the left and right arrows already did.

Modifier combinations deliberately do nothing yet. Shift-down and Option-down are
the standard shortcuts for "extend the selection downward" and "duplicate down" in
apps of this kind, and both are plausible next features on this exact surface.
Giving a modifier a meaning later is easy; taking one back is not.

When a move is impossible — a MIDI clip with an audio track below it, or a bus —
the arrow key is still consumed rather than passed on. Without that, the refused
keypress would fall through and scroll the whole arrangement out from under you,
which is a strange answer to a key that was trying to move a clip.

## 2026-08-03 — Agents can move clips between tracks now, and a half-track move is refused rather than rounded

The cross-track move landed in the engine room last time; this connects it to
everything that talks to the app. Two new commands: move a selection some number
of tracks up or down (keeping its shape), or gather it onto one named track. Both
are available to AI agents as tools, so "move the backing vocals down to the bus
below" is now a thing you can ask for.

One decision worth naming. If you ask to move a selection by *one and a half*
tracks, the app refuses instead of quietly moving it by one. There is no such
thing as half a track, and the alternative — rounding silently — would have
returned a cheerful success for something you did not ask for. When the app
reduces a move because you hit the top or bottom of the track list, it says so in
the response; there is no equivalent way to say "I threw away the fraction", so
refusing is the only honest answer.

The refusal that fires when a gathered move would stack two clips on the same
bars now names both clips over the wire, word for word the same message the app
itself would show.

## 2026-08-02 — Clips can move between tracks, and a move that would stack them is refused

Until now nothing in the app could move a clip from one track to another. You
could drag it along the timeline, duplicate it onto another track, or reorder the
tracks themselves — but the clip you already had was stuck on the lane it was
born on. That is also why the up and down arrow keys did nothing.

The underlying move now exists, in two shapes: move a selection *down two tracks*
(keeping the shape of a selection that spans several tracks), or move it *onto
one named track* (which gathers everything onto that lane). A move that would put
a clip somewhere it cannot live — a MIDI clip onto an audio lane, anything onto a
bus — is refused outright rather than half-applied, and running off the top or
bottom of the track list simply stops at the end.

The part worth explaining is what happens when a move would make two clips land
on top of each other. Gathering several tracks onto one can do that: two clips
that were perfectly fine on separate lanes want the same bars once they share a
lane. The app refuses the whole move and names the two clips, rather than picking
one and trimming it. Silently deciding which of your clips loses material is not
something a move should do, and there is no honest way to choose.

One deliberate exception: a pair of clips that already overlapped on the *same*
track — a crossfade — keeps overlapping when it moves. That overlap is yours and
predates the move, so the app carries it across intact instead of refusing a
gesture that changes nothing about the relationship.

This is the engine-room half. The arrow keys and the agent-facing commands that
use it arrive next.

## 2026-08-02 — Editing an automation curve no longer slides your clips out from under it

Open a track's automation lane, click one of the breakpoints on the curve, and
press the left or right arrow key. Until now that moved the selected *clips* —
a bar of your arrangement sliding sideways underneath the point you were trying
to nudge. The same surprise was fixed for the piano roll a few days ago; this is
the other half of it.

Now the arrow key is simply refused while a breakpoint is selected, and the
refusal is quiet and complete: the key is consumed rather than passed along, so
the timeline does not scroll sideways instead. Deselect the point and the arrows
go back to moving clips, exactly as before.

The rule the app applies is the automation editor's own. That editor already
decides whether to claim the Delete key by asking "do I have a live breakpoint
selected?", and the arrow keys now ask the very same question — the two now read
one shared answer, so they cannot drift apart and start disagreeing about who
owns a keystroke.

One wrinkle worth recording, because it decided the design. A project can have
several automation lanes open at once. A single yes/no flag would have been
overwritten by whichever lane spoke last — so a second, untouched lane quietly
reporting "nothing selected here" would have switched the protection off for the
lane you were actually editing. The app tracks the lanes individually instead,
and there is a test that opens two of them, silences one, and checks the other
is still protected.

## 2026-08-02 — The test that checked the hint was there, but never that it said anything

Internal only — no behaviour change, nothing a user can see.

An empty track lane shows the words "Double-click to add a clip". An automated
check has guarded that for a while, and it guarded it well: the words are drawn,
they are dim rather than glaring, they appear on exactly the lanes that should
have them, and they disappear the moment a clip arrives.

It never checked the words.

That is not a theoretical hole. Change the label to "Double-click to **odd** a
clip" — one letter — and the old check passed everything, perfectly green. It was
reading the value the app *intended* to draw, not the pixels it actually drew, and
its other measurements only bounded how tall and how bright the text was. A
different sentence of the same size satisfies all of them.

The gap is not closeable by measuring the label's width either, which is the
obvious idea: in this typeface `a` and `o` are the same width to within half a
point, so the exact mistake that motivated all this survives a width check.

So the new check reads the letters. It renders the sentence it expects, then asks
which of several near-miss sentences the real screen most resembles — including
that one-letter impostor. The real thing wins by a comfortable margin, and when
the impostor is compiled in, the two swap places. Both directions were run, so the
check is known to be capable of failing rather than merely observed to pass.

## 2026-08-02 — Two measuring tools that disagreed about where the window starts

Internal only — no behaviour change, nothing a user can see.

The app has a way for automated checks to ask "where on screen is this control?"
and a separate way to ask "give me a picture of the window." Both answered
honestly. They just answered in different units: the first measured from the top
of the workspace, the second from the top of the window, and those are 32 points
apart.

Nothing said so. A check that asked where a control was, then looked at that spot
in the picture, was looking 32 points too high — and 32 points up from a control
is usually some other perfectly normal-looking piece of the interface. So the
check did not crash or complain. It reported, confidently, that the thing it was
looking for was not being drawn. It was being drawn perfectly, one row down.

That already happened once, to the check that guards the "double-click to add a
clip" hint, and cost an afternoon of chasing a bug that was never there.

Now the first tool also reports where its own ruler starts, and the second
reports exactly which rectangle it photographed. A check converts between them
instead of assuming they match. The number is re-measured from the live window
every time it is asked for, never written down as a constant — a written-down
constant is precisely how this comes back the next time the layout shifts.

Measuring where the workspace starts meant attaching a small invisible marker to
the view that defines it. That marker sits behind the entire interface, so it was
worth proving it changed nothing about the interface itself. Two things were
checked by driving the real app rather than by reading the code: the little violet
"what does this do?" card still appears exactly against the control it explains —
verified by pointing it at two different controls and confirming the card moved by
precisely the distance between them, to the point — and the track area still
scrolls, and scrolls back. Both checks were then deliberately broken to confirm
they would notice.

## 2026-08-02 — A test that watched the playhead without ever checking it moved

Internal only — no behaviour change, nothing a user can see.

When you add a track while a song is playing, the audio engine has to be rebuilt
underneath you and playback has to pick up where it left off. A test has guarded
that for a long time. It turned out it could not see the one thing most worth
seeing: if the playhead froze for several seconds after the rebuild, the test
passed anyway. It asked "am I still getting position updates?" — and a frozen
playhead keeps sending updates, it just keeps sending the same number. Its second
check compared that number against itself, which is always true.

That is not a hypothetical failure. It is a bug this project actually shipped
once, and this test sat directly on the path where it happened.

It now measures something a freeze cannot fake: how far the reported position
drifts away from the wall clock over a fixed second of playing. A healthy resume
drifts by about a twentieth of a beat. A frozen one drifts by two full beats.
The threshold sits between them with room on both sides, and both sides were
checked by deliberately breaking the test in each direction — first freezing the
readings to confirm it goes red, then shifting them by a constant to confirm it
does *not*, because a rebuild that starts slightly late is normal and must stay
green.

The old check that compared the position against itself was kept, not deleted.
It is blind to a freeze, but it does catch the playhead jumping *backwards*,
which is a different bug and a real one. Two separate questions, two separate
checks.

## 2026-08-02 — Telling "the machine was busy" apart from "the audio stopped"

Internal only — no behaviour change, nothing a user can see.

Some tests watch the playhead move while audio is really playing. When the test
machine is busy running dozens of other tests at once, those tests can collect
almost no readings — three where they expected thirty-six. A test that then
says "I didn't see enough movement" is blaming the engine for the machine being
busy, and one that shrugs it off is worse: it can't tell a busy machine from
audio that genuinely died.

There's now a shared check that tells those two apart, by asking the audio
thread itself — which a busy machine cannot slow down. Busy machine: the test
says so, out loud and greppably, and stops rather than pretending to have
checked. Audio actually dead: it fails, every time. It is never allowed to
excuse the second as the first.

Two of the three tests didn't need the check at all, which was the more useful
finding. One was asking "did I see the playhead loop around at least once?" —
a question that needs many readings. It now asks whether the playhead is inside
the loop after enough time has passed that it must have gone around, which one
reading answers. The other was asking whether the playhead was still being
updated, which stays true even when the number being reported is frozen — the
exact bug this project shipped once already. That one was simply deleted.

## 2026-08-02 — A test recipe that pointed at the wrong line, and nearly at three

Internal only — no behaviour change, no new commands, nothing a user can see.
The sample-rate flip test carries a "mutant recipe": a deliberate one-line
break to the engine, so the test can prove it's able to fail. Its instructions
had gone stale — the code moved under them and the line number now landed
mid-comment. Re-resolved and, more importantly, re-run: the test still catches
exactly the two things it's supposed to catch, and still lets the two unrelated
ones through.

The catch worth naming: the obvious fix — "find the code by what it says
instead of by line number" — would have broken the test. The line the recipe
breaks reads identically in three places, and changing all three would have
made the run look like a *better* result while quietly destroying what the test
proves. The recipe now anchors on a neighbouring line that appears exactly
once, and refuses to run unless it matches exactly one place.

Also corrected: a figure this same test recorded last week as "557, not 558"
turns out to alternate between the two. Both readings were real. It now records
the derived value and both observed ones, which is the only form that stops the
number being "corrected" back and forth forever.

## 2026-08-02 — The sample-rate test now counts, instead of estimating

Yesterday's entry added a way for the app to report how many times it had
reloaded a plug-in. Today the test that matters most started using it.

That test is the one that protects you when your audio interface changes its
sample rate mid-session — you switch a device, something renegotiates behind
your back — and your loaded instruments are supposed to survive it untouched.
Until now the test proved that the indirect way: fire thousands of note requests
at every track and see whether any came back "instrument not ready".

The trouble with a test like that is you can't tell a quiet moment from a quiet
system. And we could measure the problem: when we deliberately broke the app to
make it reload everything, the old test counted **25 reloads one run and 41 the
next** — same bug, same machine. It was only ever able to report "a lot". So the
real test could only ever assert "none", and nobody could say how firmly.

Now it reads the counter directly, before and after, and subtracts. Broken, the
answer is **exactly 8 reloads and exactly 8 teardowns — one per track, every
time**. Working, it's exactly zero. The wobble was never in the app; it was in
how we were looking.

Two smaller things came out of it. We kept a deliberately-broken build around
long enough to prove the test can actually fail, because a test that has never
been seen failing isn't evidence of anything. And we found that the *check on the
check* was weaker than it looked: it confirmed the counter noticed a plug-in
being loaded, and noticed one being thrown away, but never the case that
actually happens here — a plug-in being swapped out and back in the same
instant. It does now.

We also started watching effect plug-ins the same way we already watched
instruments. That gap had been sitting there quietly, which is exactly the kind
of thing this whole line of work exists to stop.

## 2026-08-02 — The app can now tell you how often it reloaded a plug-in

Loading a plug-in is one of the few genuinely expensive things a DAW does, and
reloading one you were already using is pure waste — it can cost you a moment of
sound. So we care a lot about *not* doing it: switching your audio interface,
changing a sample rate, recovering from a glitch should all leave your loaded
instruments exactly where they were.

Proving that turned out to be harder than doing it. Until now the only way to
check was indirect: ask a track to play a note about eighteen thousand times in a
row and see whether any of those attempts came back saying "instrument not
ready". That works, but it's inference dressed up as evidence — the answer can
be hidden behind other reasons a note might not sound, and it depends on asking
fast enough to catch a window a few milliseconds wide.

There is now a direct reading. The engine keeps a running tally of how many times
it has loaded and torn down hosted plug-ins, and you can ask for it: read the
number, do the thing you're worried about, read it again, subtract. A difference
of zero is a fact, not a statistical absence.

Two details we thought worth getting right. The tally counts *attempts that did
real work*, so a plug-in that failed to load still counts — a session where every
load fails is the worst case, not a quiet one, and a counter that only tracked
successes would report zero for it. And loads and teardowns are counted
separately, because two numbers that must move together are much harder to break
silently than one.

Each track also reports a short fingerprint of the exact configuration it was
last loaded with. Compare it between two readings and you can see *which* track
changed rather than just that something did. It's deliberately opaque — you
compare it, you don't read it — and it never carries the plug-in's own saved
settings, which can be large and are none of the network's business.

## 2026-08-02 — A test that was watching the wrong thing

Also no behaviour change — this one is about how we know things work.

An earlier entry described a playhead that could freeze after the engine
restarted itself. That freeze is fixed. This is about the check that was
supposed to catch it and didn't — it watched for the playhead to move *at all*,
then declared success.

The problem is that a broken playhead still twitches once before it stops. Our
check needed the position to advance by a twentieth of a beat — about 25
milliseconds of music — and the twitch on a broken build was bigger than that.
So the check would announce "playback resumed after 44 ms" while the song sat
frozen for the next three seconds. It was measuring the wrong quantity: how
long until *something* happened, rather than how long *nothing* did.

It now measures the freeze itself — the longest stretch where the playhead sits
still — and fails if that exceeds a limit derived from what a healthy resume
actually costs. On a deliberately broken build the two readings sit side by side
in the same output: `advance=44ms` (the old check, passing) against
`plateau=2818ms` (the new one, failing).

One detail worth keeping: a detector that never reports a freeze would pass
everything forever. So there is now a check that stops the transport on purpose
and requires the detector to notice — proof that it can see the thing it is
looking for, which no amount of passing on the real cases would establish.

This also retired a number we had been repeating. Describing how bad the freeze
got, a note in our own records said that with repeating notes it recovered in
"about 100 ms" — a reassuring figure that made the whole thing look like an edge
case for held notes only. Re-measured on that same broken behaviour, with that
same repeating-note fixture, it freezes for nearly three seconds. The old figure
came from the blind check: an instrument that stops watching early makes
everything look fast, and it reports a confident small number rather than
admitting it didn't look.

## 2026-08-02 — Proving the held-note fix holds where you'd actually notice

No behaviour changed here. This is the safety net for a fix that shipped
earlier: changing something while the music is rolling used to permanently
silence any note that was already sounding. That was fixed, but only *one* of
the ways you can trigger it had ever been checked against real audio.

Three more now are, each driving the actual action against a real audio device
and listening to whether a held organ note is still there afterwards: **changing
the tempo mid-playback**, **moving the loop region mid-playback**, and **the
engine recovering itself after an audio device changes its sample rate**. That
last one means a rate change on the device you are already using — switching to
a *different* device is a separate path, and it is one of the two still
uncovered below.

The part worth stating is how they're trusted. A test that always passes is
indistinguishable from a test that cannot fail, so each one was deliberately
broken at its own source line to confirm it goes red — and red *only* for its
own trigger, leaving the other two green. The device-recovery check goes
further: it runs a second, repeating-note track through the identical device
change, so if the note vanishes we know it was the scheduling and not the audio
device being reconfigured underneath it.

Two remaining triggers are deliberately left uncovered for now, because they sit
on engine code that is still awaiting a decision.

## 2026-08-02 — Bouncing part of a song: what we measured, and an open question

Nothing changed in what you hear. This entry exists because we measured
something we had only assumed, and the result is worth stating out loud.

When you bounce a *region* — say from bar 5 rather than from the top — a note
that was already sounding before bar 5 is **not** in the file. A pad held from
bar 1 through bar 9 is simply absent from a bounce that starts at bar 5, even
though playing the same song through bar 5 you hear it plainly. We had believed
this from the name of an internal flag; it is now measured in samples, through
the same code path your bounce actually takes, and confirmed in the written WAV.

The same measurement turned up something we had not gone looking for: at
*identical* geometry, an **audio** clip that straddles the bounce start plays
(entered part-way through), while a **MIDI** note that straddles it is dropped
whole. The same musical edit behaves differently depending on which kind of
track it is on.

We are deliberately not "fixing" this yet, because it is not obviously broken.
Making a region bounce sound the held note means striking it at bar 5 — an
attack the song does not have there. So the choice is between a missing pad and
a phantom attack, and which one is right is a musical judgement, not a bug
report. Until that is settled, the behaviour is unchanged and now pinned by a
test that says in its own header that it records what we do rather than what we
endorse.

What did change is bookkeeping: the offline renderer now states its scheduling
intent explicitly instead of inheriting it silently, and the checks that guard
this decision read three source files where they previously read one — so the
next place that inherits it will fail a test rather than slip through review.

## 2026-08-02 — Recovering from a device change no longer rewinds the song

The companion to the fix below. With the playhead no longer frozen, what was
left was smaller but still wrong: when the engine restarted itself mid-song, the
music resumed *slightly behind where it had got to*. Not a freeze — a step
backward, between roughly a twelfth and a fifth of a second, and it stayed. Play
through a device change and every bar after it sat a fraction late against
everything you had already recorded.

The cause was an ordering problem rather than a slow step. Resuming has to
answer two questions — *which beat do we resume on* and *at what instant does
that beat become audible* — and the engine committed to the beat first, then
spent time restarting the device, rescheduling the clips and lining up the
players before the sound actually landed. The beat was therefore correct for a
moment that had already passed by the time it arrived.

Now a resume picks the instant first and derives the beat for *that* instant, so
the two agree by construction. If the work overruns the prediction the engine
moves the anchor forward rather than honouring a moment in the past — being a
touch late together is recoverable, whereas audio and playhead disagreeing is
the failure this whole area exists to prevent. Measured on the same project, the
step backward went from 0.27–0.38 beats to 0.14, which is the floor set by how
the playhead reads the clock rather than anything left to reclaim.

The trade is about thirty milliseconds of extra silence at the moment of
recovery, once, in exchange for the song staying where you left it.

## 2026-08-02 — The playhead no longer freezes after the engine recovers

When the audio engine has to restart itself mid-song — because the device
changed underneath it, or because the built-in watchdog caught a stalled engine
and bounced it — you kept hearing music, but the playhead stopped moving. It sat
still, then jumped and carried on as if nothing had happened. Everything that
follows the playhead sat still with it.

The freeze was not a fixed pause. It lasted exactly as long as the engine had
been playing before the restart: a bounce after one second froze it for one
second, after three seconds for three. Play for a minute and hit a device change
and the readout would have lied to you for a minute.

The cause: on restart, the engine asked the audio hardware "what time is it?"
and got back the *old* session's answer, because the new one hadn't produced a
sample yet. It anchored the playhead to that stale answer, which put the anchor
in the future — so the position clamped and waited for real time to catch up.
The engine already knew how to avoid this and does so in two other places; the
recovery path was the one that didn't, even though its own notes say the sample
timeline has just broken and it deliberately reads the wall clock instead.

Measured before and after: a one-second freeze is now 35 ms, a three-second
freeze 69 ms — the same as a healthy engine that never restarted at all. Both
routes into recovery run through the single line that was wrong, so both are
fixed; the measurements above were taken through the watchdog route, which is the
one that can be driven on demand.

One thing this fix does **not** cover, written down rather than left to be
rediscovered: recovery still resumes roughly 120 ms behind where it should — a
much smaller timing flaw in the same routine.

A related worry, now **settled, and the news is good**: if you have picked a
specific output device, that choice *does* survive a recovery. We had not
checked, and a silent return to the system default would
have been the kind of thing you only notice by wondering why the sound moved. It
was measured on the harshest route — the watchdog stopping and restarting the
audio hardware mid-playback — and the pinned device came back pinned, with the
system default untouched. No change was needed; what was missing was the proof.

## 2026-08-02 — Edit a note while the music is playing and the music keeps playing

If you were holding a chord — a pad, an organ, anything sustained — and you drew
a note in the piano roll, that chord stopped. Not faded: stopped, and never came
back until you restarted playback. It happened to *every* sounding note in the
project, including on tracks you hadn't touched — adding one new track was enough
to cut off a chord held on a different one. Fixed.

The same underlying rule reached several other mid-playback moments — dragging the
tempo, changing the loop range, switching audio devices — and the fix covers all
of them. To be exact about what we have actually watched happen, though: the
clip-and-note-edit path is verified end to end against a running app with a real
instrument sounding. The others are fixed and covered by tests, but have not yet
been exercised live one at a time. That work is scheduled, not assumed done.

The cause was a rule about how playback is scheduled. Whenever the engine has to
rebuild its schedule mid-flight, it works out what to play from the current
position onward — and it was only counting notes that *start* at or after that
point. A note you were already holding started in the past, so it was skipped
entirely, along with the instruction to release it. Audio clips never had this
problem: the same code resumes them partway through, which is exactly what notes
should have been doing all along.

Now the engine distinguishes between two situations. If you asked to move — you
pressed play, seeked, started recording — nothing changes; the existing behaviour
was right. But if playback was simply continuing and the engine rebuilt its
schedule for its own reasons, notes you were holding are picked back up and
carried through to their proper end.

One honest caveat: a note picked back up this way *re-attacks*. A slow-swelling
pad restarts its swell rather than continuing seamlessly. That is audible, and it
is not the same as never having been interrupted — but it is a great deal better
than silence for the rest of the song, and continuing a voice untouched would
mean preserving synthesiser state across a rebuild, which is a much larger change.

This was found while proving out last week's audio-device work, filed as a
device-switching bug, and turned out to be neither about devices nor rare.

## 2026-08-02 — We proved the device-swap claim, and found what it doesn't cover

Yesterday's note said swapping audio devices no longer disturbs your plug-ins.
That was the design's intent; now it is a measured fact. We built a test that
plays a real project through a real device, changes that device's sample rate
underneath it while the music is running, and watches what happens to the eight
loaded instruments. Nothing reloads. The engine holds its rate, the sound keeps
flowing, and every plug-in keeps its state.

To be sure the test could actually fail, we broke the engine on purpose — put
the old device-following behaviour back — and re-ran it. The instruments all
reloaded, exactly as they used to. That is the difference the change makes,
and now it is written down rather than assumed.

Two things we found along the way, both being fixed separately. **A note that
is already sounding when you switch devices goes silent and does not come
back** — a held pad drops out where a repeating part recovers in about a tenth
of a second. And the playhead can appear to freeze for a few seconds after a
switch even though audio is still playing. Neither is new; both were there
before this work and simply had nobody looking.

## 2026-08-02 — Your mix stops caring what you plugged in

Until now the whole audio engine ran at whatever sample rate your output device
happened to be using. Plug in a 44.1 kHz interface, or let a Bluetooth headset
drop into its 24 kHz mic mode, and everything downstream quietly moved with it:
the limiter's lookahead, the delay compensation between tracks, the timing math
behind automation. The mix you were listening to was subtly not the mix you had
set up, and switching devices mid-session could re-initialise every plug-in you
had loaded.

The engine now runs at a fixed 48 kHz regardless of your hardware, and converts
once, at the very last step before the sound leaves for the device. Your project
sounds the same on every output you own, and what you hear live now matches what
you get when you bounce, by construction rather than by luck. Swapping devices no
longer disturbs your plug-ins.

*Later note (same day):* we went back and proved that last sentence against the
running app, and it holds — but proving it turned up two things it does **not**
cover. A note you are *holding* when you swap devices can go silent and never
come back, and the transport clock can freeze for several seconds afterwards.
Both are open; see the entry at the top of this file.

The conversion is not free, so we measured it rather than assuming: **0.004 ms**,
about a four-thousandth of the threshold where anyone could notice. Doing the
same conversion in the wrong place would have cost 250× that, which is exactly
why it happens where it does.

Nothing to configure — this is how the engine behaves now. (48 kHz is the
setting for this version; per-project rates are a later change and the code is
already shaped for them.)

## 2026-08-02 — Choose where the sound comes out

You can now pick which audio device DAW Pro plays through, instead of it always
following whatever your Mac's default output happens to be. Send the mix to your
interface and leave notification sounds on the speakers — the two no longer have
to be the same place.

The important part is what it does *not* do: **choosing an output inside DAW Pro
never changes your Mac's default output.** System Settings stays exactly as you
left it, and every other app keeps playing wherever it already was. The app pins
its own playback and nothing else. There is a check in the test suite whose only
job is to prove this, run three times over, because getting it wrong would mean
picking an interface in a music app silently muted the rest of your computer.

Switching takes effect immediately, even mid-playback. It is refused while
you're recording — re-pointing the output restarts the playback engine, and a
take in progress is anchored to it.

Which device you've chosen is remembered for the session but is deliberately
**not** saved into the project file. Which speakers you're sitting in front of
is a fact about the room, not about the song, so a project opened on another
machine won't go looking for hardware that isn't there.

Available to AI agents too, as `output_list_devices` and `output_set_device`.

## 2026-07-30 — Groundwork: playing at the right speed on any audio device

Nothing you can see yet — this is a measurement that clears the way for
something you will.

Audio devices run at a fixed speed. Most run at 48,000 samples a second, but
plenty run at 44,100, and some hardware insists on its own. A project also has
a speed. When the two disagree, something has to convert between them, and
*where* that conversion happens decides whether it costs you anything.

We wanted to do the conversion at the very last step, on the way out to the
device, so everything before it stays at one clean speed. The open question was
the price: would it drift out of tune, arrive late, or fall over when you
switch headphones mid-song?

Measured, on a real loopback device: a 997 Hz tone through a 48 k project on a
44.1 kHz device comes out at **996.991 Hz** — 0.009 Hz off, where getting it
wrong would have landed at 1085 Hz. The conversion adds **0.004 ms** of delay,
which is at the limit of what the measurement can even resolve, against a
15 ms budget. And flipping the device between 44.1, 48 and 96 kHz *while audio
is playing* recovered correctly all ten times.

One genuinely useful surprise: conversion at the output is essentially free,
but doing the same conversion one step earlier in the chain — at the mixer —
costs about **0.94 ms**. Both are ways of building the same change, and the
difference between them is the whole finding. Nothing converts today: the app
currently just runs everything at whatever speed the device asks for, which is
why none of this has cost anyone anything yet, and also why the project has no
speed of its own to keep.

## 2026-07-30 — A Panic button, for when a note will not stop

**There is now a way out of a stuck note.** Every so often a note gets stuck
sounding and nothing you do makes it stop. It is almost never your fault: a
keyboard sends "key down" and "key up" as two separate messages, and if the
second one never arrives — you unplug the cable mid-note, the device drops off,
another app quits with a key held — the note is left hanging on. The DAW is
right to keep sounding it, because as far as anything can tell, the key is
still down.

What was missing was the exit. Pressing Stop did nothing, because Stop only
does something when there is something playing to stop. Nothing in the AI
copilot's vocabulary could clear it either. So the only fix was to quit the app.

There is now a **PANIC button in the transport bar** — the red octagon next to
Record. Press it and everything goes quiet. Your AI assistant can do the same
thing when you ask it to, using the new `transport.panic` command.

Two things about it are deliberate. It works **whether or not anything is
playing**, which is the whole point — a stuck note usually happens when you are
not playing anything. And it does **not** stop playback or recording, so if a
note jams in the middle of a take you can silence it and keep the take.

## 2026-07-30 — The sustain pedal holds for as long as you hold it

**Live MIDI thru: a pedalled note no longer dies after 8 seconds.** Hold the
sustain pedal, play a note, lift your finger — the note is supposed to ring on
until you lift the pedal. It did, for eight seconds, and then stopped dead in
the middle of the sound. Any pedalled phrase longer than a bar or two ran into
it.

The engine was watching the wrong thing. It kept a track awake while a *key*
was held down, which is the right rule right up until you use a pedal: under
the pedal your finger comes off the key while the sound keeps going. So the
engine saw nothing held, started its idle countdown, and cut a note that was
still sounding. It now watches the pedal as well as the keys.

Lifting the pedal still releases everything exactly as before — that is
checked, because "never stops" would have been a worse bug than "stops too
early".

## 2026-07-30 — Let go of the key and the note stops

**Live MIDI thru: a retrigger no longer strands the previous voice.** Play a
note, then play the same note again without lifting the key first — something
real hardware does constantly, and any source that drops a note-off does by
accident. The second press used to leave the first note stranded: nothing could
ever switch it off, so it sounded until the whole instrument was flushed, and
the note-off you eventually sent went to the *second* voice instead. The
retrigger now closes the first voice itself.

Under the hood this was a capacity change, not a one-line fix. Each incoming
note can now produce two outgoing events, so the render thread's fixed scratch
buffer was resized (768 -> 1280 events) and the drain loop was changed to count
*presses* rather than emitted events — bounding on emissions would have left
half a busy quantum's input queued a beat late, every beat.

Verified end to end through real CoreMIDI, not just in unit tests: a new gate
creates a virtual MIDI source, plays on/on/off into a sustaining synth, and
watches the master meter fall silent. Deliberately re-run against a build with
the fix removed, where it stays loud forever — so the test is known to be
capable of catching the bug it was written for.

One accepted trade: two MIDI devices holding the *same* note now replace each
other rather than stacking. That is the better failure — previously they
stranded a voice *and* mis-paired the key-up.

## 2026-07-30 — The last check that was quietly measuring a zombie

The internal check that proves your window-follow preference survives a restart of the app used to kill the app, wait, and ask "is it gone?" — and get back "no, still running" even when it had already exited. The answer was an artifact of how the check was being run, not of the app: nothing was left to notice the process had died, so the question kept returning the stale answer. That mattered more than it sounds, because that one question is what rules out the check accidentally re-connecting to the OLD app and congratulating itself on a setting that never actually persisted. It now measures what it claims, and the tooling around it says so out loud.

Two other things in the same area stopped being taken on trust. This check was the last one in the suite that ran against whatever copy of the app happened to be lying around rather than building a fresh one, and it measured the screen through a small helper program that had last been compiled by hand four days earlier. Both are now rebuilt every single run. And the audit that reports "nothing launches the app behind our back" turned out to have never been able to see this particular check doing exactly that — it was looking for a literal filename and this one used a variable. The audit has been taught to see it, and to refuse to stay quiet unless each case is justified in writing.

Separately, four genuine problems this check has been reporting for a while are now written down as their own task rather than living inside a wall of output — they all look like one cause, the same one already logged against a sibling check: the screen measurements are aimed at coordinates the layout has since moved away from.


## 2026-07-30 — An internal check that had been quietly testing a third less than it claimed

The resize sweep is one of our internal display checks: it resizes the app to four
window sizes and photographs the screen in each, so we can see that nothing overlaps
or gets cut off. It is meant to take 24 photographs.

It was taking 16. The last eight needed a project with some music in it — a few notes,
a volume curve, an EQ — and the check never made one. It expected whoever ran it to set
that up by hand first and tell it where to look. If you just ran it, it took the 16
photographs it could and stopped, without mentioning the eight it had skipped. That has
been true since the check was written in July, and the runs that did produce all 24
happened because a person staged the project by hand that day.

The check now builds that project itself, every time, so all 24 photographs get taken.
We recovered what the project should contain from the notes of the original 24-photograph
run rather than guessing, then confirmed by eye that the photographs really do show it:
the notes, the volume curve continuing past the end of the clip, the EQ panel.

Also fixed: this check read a setting called PORT to decide which copy of the app to
talk to. PORT is a name lots of tools set for unrelated reasons, so an unlucky value
could have pointed a 24-step resize sweep at the app you were actually working in and
resized your window out from under you. It now talks only to its own private copy.

Filed for a follow-up sweep: any other internal check that quietly does less than it
says when something optional is missing.

## 2026-07-30 — The two long-running stress tests start the app themselves, and the last of the risky `PORT` shortcuts is nearly gone

The two endurance checks — one that repeatedly deletes an audio file mid-playback
to make sure the app never wedges, and one that rebuilds a 40-track session five
times over to make sure the sound never silently drops out — now build and launch
their own private copy of DAW Pro. Verified over eight runs: identical results
every time, and the measured loudness of the 40-track mix came out the same to
four decimal places whether the check started the app itself or not.

These two carried the same hazard fixed yesterday, in a worse form: they defaulted
to a port that was neither the private one nor your live one, and still obeyed a
`PORT` setting from the environment. Pointed at your real session, one of them
would have deleted files during playback and the other would have rebuilt your
project forty tracks at a time. Both overrides are gone. One check still carries
this shortcut and is scheduled next.

## 2026-07-30 — Two more internal checks start the app themselves, and a stray `PORT` setting can no longer aim them at your project

The mixer-strip and piano-gutter layout checks now build and launch their own
private copy of DAW Pro instead of quietly attaching to whatever happens to be
running. Every picture they take came out **byte-for-byte identical** to the old
way — all 25 of them, across nine runs — so nothing they look at has changed.

The reason this mattered more than housekeeping: both checks used to read an
environment variable called `PORT`, which is one of the most commonly set names
on any developer's machine. If it happened to be set to the port your real DAW
Pro window listens on, these checks would have driven **your** session — and the
first thing they do is start a new empty project, discarding what you had open.
Their own instructions named a different variable entirely, so the setting people
were told to use did nothing while the dangerous one worked silently. The
override is gone; the checks now refuse your live app outright rather than
trusting a setting.

## 2026-07-30 — The two speed checks now start the app themselves, and it was proven not to change what they measure

Two internal checks measure how long it takes to add a track *while the project is
playing* — one with 40 audio clips rolling, one with them idle. They were the last checks
that still needed someone to launch DAW Pro by hand, and the awkward ones to change: they
assert on millisecond timings, so making them build and launch the app first could plausibly
have altered the very numbers they measure.

Rather than argue about it, it was measured. Each check was run nine times across three
setups: against an app left sitting idle for a minute with no build beforehand (how they
were originally calibrated), through the old hand-launched path, and self-launching. All
eighteen runs passed every timing band, and the self-launching average landed exactly on the
idle-app average. The startup work finishes about fifteen seconds before the first
measurement is taken.

Two side benefits. These two checks could previously be pointed at a different port by an
environment variable — including the one the user's real app runs on. That override is gone.
And a stray sixty-second override could no longer make a slow compile look like a hung check.

One thing to fix later, now written down: the active-players check requires its result to be
*at least* 330 ms, and the fastest run measured came in at 337. That floor means a genuine
speed-up in track creation would be reported as a failure.

## 2026-07-30 — The two biggest internal checks now start the app themselves

The spectrum pair — the check that the per-insert spectrum actually draws on a track's EQ
card, and the check that the vibe orb, goniometer trail and mono-safety readouts keep
running while DAW Pro is in the background — were the last two large checks still requiring
someone to launch the app by hand first. They now build and start their own copy, like the
rest. Between them they are the heaviest pair in the suite, which is why they were left
until the recipe had been proven on twelve smaller ones.

Both produced exactly the same result afterwards as before — 64 checks and 47 checks, all
passing, in the same order — so the change is in how they start, not in what they measure.

One of the two got quietly more trustworthy in the process. It works by holding focus away
from DAW Pro for its whole run, and its very first check confirms the app *is* in front
before that starts — otherwise the run proves nothing. Previously that depended on luck,
since whoever launched the app by hand would have had their terminal in front by the time
the check ran. Now the check starts the app itself, so the condition is guaranteed.

## 2026-07-30 — Three more checks start the app themselves, and one turned out to be looking at a blank patch of screen

Three internal checks — the reference-track panel, the off-clip playhead cue, and mixer
strip dragging — used to require someone to launch DAW Pro by hand first, then point the
check at it. Whatever build happened to be running is what got measured. All three now
build the app and start their own copy, so a check can no longer quietly report on
yesterday's code. The playhead check had a second version of the same problem: the small
Swift tool it uses to inspect pixels was also compiled by hand, once. It is now rebuilt on
every run too.

Two real problems surfaced while doing this, both of which predate the change and are now
written down rather than quietly fixed:

The off-clip playhead check has been examining a strip of the note grid that no longer has
anything in it. The cue it looks for sits about 165 pixels lower on screen than where the
check reads. Sixteen of its thirty-three assertions fail for that one reason, so a real
break in this feature would currently be invisible among them.

The reference panel's match-gain chip draws +24 dB and −24 dB identically. Everything in
between is distinct, so the readout is fine until you reach the extremes, where a large
boost and a large cut become indistinguishable at a glance.

One more thing worth recording: the app remembers its window size between launches, and
nothing in the checks pins it down. A check that compares screenshots can therefore change
its answer purely because the window came back a different size — which is exactly what
happened here, and it looked convincingly like a regression until the old version of the
check was re-run and produced the same result.

## 2026-07-30 — A check that times out no longer leaves a copy of DAW Pro running behind it

Twelve of the internal checks carry a stopwatch that gives up if the app stops responding.
When that stopwatch fired, the check quit — but left the copy of DAW Pro it had started
still running, invisibly, in the background. The same thing happened if you pressed Ctrl-C
to stop a check partway through.

That leftover copy is worse than untidy. Later checks would connect to it by mistake and
report on the wrong app: on one occasion in July, a single stray copy caused five checks to
pass that should have failed, and three to fail that should have passed. It is the reason a
run could look clean and mean nothing.

The shutdown now happens in the one place that starts the app, so it covers every way a
check can end — finishing normally, timing out, being interrupted, or crashing — and it
covers checks written in the future without anyone having to remember. Measured before and
after: with the old code the leftover copy was still running on every path tested; with the
new code it is gone on all of them, and the checks themselves report exactly what they did
before.

## 2026-07-30 — The four export checks now start the app themselves, and one of them stopped lying about stems

Four more of the app's internal checks — the ones covering the export window, exporting
MIDI from a track, and the stems dialog — now build and start DAW Pro themselves instead
of testing whatever copy happened to be open. All four came out the same before and
after: a hundred individual checks, none failing. The exported files landed on disk as
expected, which is the part that actually matters for export.

One of these had a real problem worth explaining. The export window remembers your
settings until you quit. The stems check tests what the window looks like *fresh*, so if
anything had opened that window earlier in the same session, the check would report
failures that looked exactly like a bug in the app — and that had already happened once,
in July, on a build with nothing wrong with it. It relied on someone remembering to
restart the app first. Now it starts its own, every time, so the situation can't arise.

We also found a piece of cleanup code that had never once run. It was written to release
resources when the check finished, but it sat in a place the program never reaches on its
way out. Harmless as written — but it is exactly where someone would later put "shut the
app down", and it would have quietly left copies of DAW Pro running after every
successful run. Fixed here, and we've made a note to check the rest for the same shape.

## 2026-07-30 — Three more checks now build the app they test, and one tool had stopped counting straight

Another three of the app's internal checks were converted so they build and launch
DAW Pro themselves instead of quietly measuring whatever copy happened to be running.
All three came out green before and after, matching step for step — so this is
plumbing, not a bug hunt. Nothing about the app itself changed.

Two things did turn up along the way.

The tool that runs a check "before" state — the reference point we compare against —
was silently dropping any arguments you gave it. Four of the checks still waiting to
be converted take a folder to write their output into, and three of those have no
fallback, so they could not have been measured at all. That is fixed, and it was
confirmed the blunt way: the same probe run through the old tool and the new one, one
losing the arguments and one keeping them.

The tool that keeps score of how many checks have been converted had started counting
one of our own tools as if it were a check. The number it reported was one too high
and had quietly stopped adding up against last week's. Also fixed, and the totals line
up again.

We also pulled two checks out of this batch. They measure how long the app takes to do
something, and they were calibrated against this specific machine on a quiet day.
Converting them would mean compiling the app immediately before timing it, which
disturbs the very thing they measure. They need a different approach and now have
their own entry, rather than being rushed through with the rest.

## 2026-07-30 — We started auditing the checks that were never really checking, and found three real problems

There is a group of 25 automated checks in this project that never start DAW Pro
themselves. They connect to a copy that is already running — one a person started
by hand, at some unknown moment, from some unknown version of the code. A check
like that can report a confident pass without having tested anything you would
recognise, and it has no way of noticing.

Rather than convert all 25 at once, this round did four as a probe, deliberately
mixed between checks that only talk to the app and checks that inspect what is
drawn on screen. All four now build the current code and start their own copy of
the app. Each was measured before and after to confirm the change itself altered
nothing.

**Two of the four were already failing before anything was touched.** That is the
finding, and it is why the probe was worth doing:

- **m23-fl / m23-fj — three tests that always said "pass" now say what they actually do, and a soak test can no longer pass without running.** Three of our checks are really screenshot tools: they capture frames for a human to look at and assert nothing. Their own notes said so, but only in prose, so an automated run counted them as passing tests indistinguishable from ones that checked something. They now declare it in a form the tooling reads — still succeeding, but recorded separately and required to state a reason. **Deliberately, no assertions were invented for them: the real check is someone's eyes.** Separately, a soak test that repeats an operation could be told to repeat it zero times, whereupon it printed PASS — measured directly, not theorised. It now refuses, and a sweep confirmed only two tests in the whole suite have a setting like that, both now handled.
- **m23-fk — the delete shortcuts now respond to the key you actually press, and fixing it nearly introduced something worse.** Three delete shortcuts were listening for the wrong character and had never fired. The obvious one-line fix turned out to be destructive: with the shortcuts re-armed, *holding* Delete deleted the selected notes and then, on the very next auto-repeat, deleted the clip containing them — because once the notes were gone the same keystroke was interpreted as targeting the clip. The repeat protection that should have caught this had been bypassed. The shipped fix declares explicitly that these shortcuts respond only to a key going down, never to a repeat, which was measured to hold the clip safe. **Also fixed: Delete now works on automation points in the Mix console** — three of the four links are measured, and the last one needs a real click, so it wants a human check. Two behaviour changes are flagged for you rather than decided quietly: Shift/Option/Command+Delete now delete where they previously did nothing, and the protection that stops Delete eating a clip while you're renaming something is now the only thing standing there.
- **m23-bn — a test that had been failing since the day it was written now passes.** One check sent a parameter by the wrong name, which the app correctly rejected, so that check had never once succeeded. Rather than fix it, previous notes recorded it as a known harmless failure — which is how a documented artifact outlives the bug it describes. Fixed and verified: the gate is now 20 for 20.
- **m23-fi — the Delete key's real explanation turned out to be a single character, and it wasn't what we'd said.** We had blamed keyboard focus. Measuring it directly showed focus was fine all along: the shortcut constant SwiftUI calls "delete" is actually the *backspace* character, while the Delete key on your keyboard sends a different one. They could never match, so three delete shortcuts had never once fired — no amount of focus work would have helped. The proof is that arrow-key shortcuts sitting on the very same view, with the very same focus, work perfectly. **One genuine bug surfaced that nobody had reported: in the Mix console, pressing Delete on a selected master-volume automation point does nothing** — the only way to remove one is to double-click it. That has never worked, and it's the one case the current Delete fix structurally cannot reach.
- **m23-fg / m23-fl — a suspected problem in our test suite turned out to be 111 false alarms and one real one.** A count of 116 suspicious exit points had been filed as a second class of tests-that-pass-without-testing. Classifying every one of them: 111 are ordinary failure exits, which fail in the *safe* direction. One is real — a test that prints "PASS" after running zero iterations when a setting is turned down to zero. And three others report success unconditionally: they take screenshots and exit, and nothing anywhere — no comparison step, no stored reference, no script — ever looks at the images.
- **m23-di-2a — you can now import someone else's voice model.** Point the app at an RVC `.pth` file (and its companion index, if you have one) and it becomes a real voice in your library, named and listed. The sidecar was always built to accept a voice folder dropped in from outside — its own code comment says so — but nothing in the app could put one there. Imports land in your Application Support folder, never inside the read-only engine checkout. **An imported model arrives honestly marked "needs prep": it can't be used for conversion until it's converted to the engine's format, and that step is a separate question waiting on you.** Verified end to end against a running app, including that the files genuinely land on disk rather than the command merely claiming success.
- **m23-fc — we nearly built a feature that the app is deliberately incapable of hosting.** Live voice conversion while you sing was on the roadmap as a large-but-doable job, and a first look suggested most of it already existed upstream. Measuring it changed the answer twice. The existing code turned out never to have run at all — it produces exactly silence, for a specific and provable reason. And even a perfect implementation would not have helped: converting a block of audio costs about 26 ms **no matter how small the block is**, so a round trip lands near 120–185 ms where singers need under 15, and that floor stays above the target even at an impossible zero processing cost. The decisive point came from our own code: DAW Pro has no path from a live input back to the speakers, and a comment written long ago says that's deliberate. So the feature was never a latency problem. **Recorded rather than attempted, with the measurements, so nobody re-opens it on optimism.**
- **m23-er / m23-fh — two pieces of our own record corrected.** A survey of which settings each debug command can quietly change had been done by asking which commands *mention* the setting by name; rebuilt around what the code actually calls, it found two more commands than the previous list named. And nine test files carried a claim that a certain kind of keyboard test was impossible in our harness — it never was; the failure they were describing was the real Delete bug. Seven were corrected and **two were left alone, because they had stated it accurately all along.**
- **m23-fa-1 — we found a test that passes by not testing anything, and it wasn't hypothetical.** An audit had established that most of our automated checks would report success if they somehow ran zero checks, but the expectation on record was that this was a theoretical hole nobody would ever fall into. The first real measurement disproved that: one existing check, entirely unmodified, reports **"PASS: 0/0 cycles audible"** and exits successfully when a documented setting is turned down to zero. It has presumably been doing that whenever anyone used that setting. **The fix is a single shared piece of code that every check will report its result through** — it refuses to call a run successful if nothing was actually checked, and distinguishes "nothing ran" from "something failed" so the two can't be confused. Three checks are migrated onto it as a pilot. **The proof that matters isn't that they still pass — it's that they now go red when their assertions are removed, while the old code stays green under exactly the same conditions.** A survey tool went with it, so migrating the remaining sixty-one is measurable rather than eyeballed. It also found a flaw in our own tally of the problem, and a third way the same failure can happen that nobody had named.
- **m23-cf — the Delete key does nothing, and the reason turned out to be that nothing was listening.** You reported that selecting a note or a clip and pressing Delete did nothing, while Delete inside a rename field correctly deleted text. That third result was the one that cracked it: the key was arriving at the app perfectly well, so the problem was never delivery. A probe over twelve consecutive selections settled which of the two remaining explanations it was — the delete handler was entered **zero times out of twelve** with the new routing disabled and **twelve out of twelve** with it live. It was never being asked, rather than being asked and declining. The underlying cause is that the arrange surface holds no keyboard focus at all for the modern key-handling path to attach to. **The fix takes the same route the space bar has always used** — a window-level key monitor that doesn't depend on that focus, feeding the existing, unchanged decision about what Delete should remove. An earlier attempt this week made all three delete handlers agree with each other, which was a real fix for a real inconsistency but could not have helped here: agreement between handlers is worth nothing when none of them is ever consulted. **Held-back note: this is verified by synthesized key events against a running app and by 27 checks that were each proven to go red when their guard is removed — but not yet by a human finger on a key.**
- **m23-ez — we were about to price a piece of work as an engine migration, and it turned out we already run that engine.** A note in the roadmap held some voice-conversion work out of scope on the grounds that the Apple-MLX voice-conversion project we'd want to build on was *a different backend* from the one our voice sidecar runs — a swap, with all the risk that implies. Reading our own installer settled it in three commands: it clones that exact project, at a pinned commit, and the sidecar reports it by name as its own engine. The confusion had a real source — the engine comes from one project and the neural assets it loads come from a different one, so the two names sit side by side in the same file. **Consequence: the live-conversion and voice-blending spikes are work on the stack we already run, not a migration, which is a materially lower cost than recorded.** No code changed; the whole finding was read-only.
- **m23-ee — the audit of our own test suite is finished, after about ten rounds.** The question it started from: how many of our automated checks can pass without actually checking anything? All 71 gate scripts were swept by a purpose-built tool, all 130 candidate sites were judged individually and in writing, and the tool itself was corrected four times along the way — including once where it had been quietly declaring a check "safe" on the strength of a stale measurement. Real faults found and fixed across the arc: nine, plus one in the auditing tool. **The two lessons are a matched pair and both were expensive:** a checker that can only see one function at a time mostly flags *careful* code, so a noisy report meant the tool was weak rather than the tests sloppy — twelve of fifteen flags in the final round were false alarms. And a checker that recognises only one way of writing a mistake will miss the same mistake written any other way: it found two instances of a problem that turned out to affect 57 of 71 files. Five sites remain flagged and all five are deliberate — three are the tool honestly reporting what it cannot see, which is how it was designed.
- **m23-ee-2c-3 — went to fix two lines, found that 4 out of 5 of our automated checks can report success without having checked anything.** The two lines were real: a gate that recorded no results exited with a success code, because "every item in an empty list passes" is true. Both are fixed, and the fix provably changes the outcome of exactly one situation — the empty one — so no existing result moves. **Then the same question asked of the whole suite: 57 of 71 gates have the same hole**, written eight different ways (counting failures, comparing a pass count to a total, and so on) — every one of which reads as "success" when nothing ran. That is now its own tracked item, with a note against fixing 57 files by hand. **The uncomfortable part is the detection rate:** the tool built to find this class found 2 of 58, because it only recognised one of the nine ways of writing it — and the 56 it missed are invisible precisely because they are written the idiomatic way.
- **m23-ck — the compressor gets a Mix knob, so parallel compression stops costing you a duplicate track.** New-York compression — blending the squashed signal back under the untouched one — is a daily move, and until now doing it here meant duplicating the track and balancing a send. There is now a Mix control on the built-in compressor: fully wet by default, so **every existing project renders bit-for-bit identically**, which was tested rather than assumed. At Mix 0 the compressor is a provable bypass. One note for later: the gain-reduction meter still shows movement at Mix 0, because it reports what the detector measured rather than what you hear — that is how other DAWs behave, but say the word and it can follow the blend instead. **(Follow-up, m23-ev: the AI-facing description of the compressor now names the Mix control and explains it, so an agent asked to set up parallel compression can discover it — previously the knob existed but nothing told an agent it was there.)**
- **m23-di-3 — we compared ourselves to VocalNet before building anything, and it changed the plan.** You asked for a plugin like VocalNet for RVC models. Most of it turned out to already ship here, and the obvious next step looked like adding model import. The comparison says otherwise: **import is real but it is the cheapest of three gaps, not the only one.** VocalNet also does live real-time conversion — the thing its relaunch was built around, and arguably what you actually asked for — and blending several voices together. Neither exists here. The report separates what was confirmed from a primary source, what rests on a single user's report, and what simply could not be checked, and it throws out two claims that turned up only in search-engine summaries with no traceable source.
- **m23-eu — the test-auditing tool was quietly declaring some checks "safe" on the strength of a measurement taken 130 lines earlier, of a value that had since been overwritten ten times.** Fixed, and the count of unexplained checks correctly went UP rather than down. Two more of the same family are now filed rather than silently carried.
- **m23-ca — the DAW now keeps a record of what AI agents actually did to your project.** You asked for this after a session where an agent rebalanced your mix and the only account of it was the agent's own written summary — which claimed the master fader had been at 1.0097 before it started, a statement about the past that nothing could confirm or deny. Every tool call an agent makes is now written to an append-only log in `~/Library/Logs/DAWPro/mcp/`: what was called, what was passed, **what came back**, how long it took, and — for anything that changes the project — **a snapshot of the relevant state beforehand**, which is the part that answers the master-fader question. API keys are stripped by two independent rules, and anything large is reduced to a fingerprint rather than dumped in. **Honest about its own limits:** roughly 57% of changing operations capture a genuinely useful before-value; the rest record that they could not, and why, rather than leaving a blank that reads like nothing happened. Logging can never slow down, break, or interfere with a call — if it fails, it gets out of the way.
- **m23-ee-2c-2b — taught the checker four more patterns it had been misreading, and the useful part is the one it refused to agree with me about.** The tool that has been auditing our tests kept flagging checks that were actually fine, because it could only look at one function at a time. Four of those blind spots are now closed, and the list of unexplained checks drops from ten to six. **The fifth was my mistake, not the tool's:** I had read one flagged check, satisfied myself it was properly defended, and then assumed the tool could be taught to see the same thing. It cannot — the defence lives inside a helper function, and reading across function boundaries is precisely what this tool deliberately does not do. Being able to see that something is fine and being able to prove it mechanically are different problems, and I had quietly treated them as one. **It also found a genuine fault in the tool that predates this work, and left it alone rather than fixing it on the way past:** in one test file the checker credits a check as "defended" by pointing at a measurement taken 130 lines earlier, of a value that has since been overwritten ten times. That is the dangerous direction of error — a false alarm gets investigated and dismissed, while a wrongly-cleared check is one nobody ever looks at again. Filed as its own item, and fixing it will make the number go UP, not down.
- **m23-ee-2c-2a — the one real one, and it was broken in two places rather than one.** After clearing twelve false alarms, this is the single genuine case in the batch. When you drag a MIDI file onto the arrangement, a check confirms every imported clip landed on the beat you dropped it at. It could report success in two different situations where it had checked nothing: if the import created no tracks at all, and — separately — if it created the tracks but put no clips on them. Either way the check found no beats to compare, and finding no problems in an empty list reads as "no problems". The audit tool only knew about the first of those two; fixing that alone would have looked complete while leaving the second open. Both are now pinned to what a correct import actually produces (two tracks, at least one clip each), cross-checked against a *second*, independent reading of the project rather than against the importer's own report of what it did. Proven both directions: the check now rejects all four broken situations, the old one accepted all four, and — the control that matters — a genuine wrong-beat error is still caught, so the fix hardened the check rather than watering it down. The gate runs 18/18 before and after.
- **m23-ee-2c-1 — we went to fix seven flagged checks and found nothing wrong with any of them.** The scanner that has been driving this audit reports a list of checks that *could* pass without testing anything. Seven of them were queued for repair. Reading the actual code, all seven turned out to be defended already — five cannot encounter the problem at all (the thing they inspect is built by a loop that always produces the same fixed number of items), and two are guarded by a neighbouring check that goes red first, so the situation could never pass unnoticed. In one case the person who wrote the check had anticipated exactly this and said so in the check's own title: *"asked first… otherwise every check below would be vacuous."* The scanner flagged the very line that sentence defends. Nothing in the gates was changed; the scanner was fixed instead, and it now understands three of the four patterns it was missing. The fourth needs it to read across function boundaries, which it deliberately does not attempt — instead it now says "a human should read this one function" rather than guessing. **Continuing through the rest of the list the same way: 12 of the 15 outstanding items are false alarms, roughly 2–3 are real, and the full reasoning per item is written down in `docs/research/2026-08-09-vacuity-tail-adjudication.md`.** The useful lesson is uncomfortable and worth keeping: a checker that can only see one function at a time will mostly flag *careful* code, because careful code puts its defences in the setup, one line up, or one function over. A noisy report meant the tool was weak, not that the tests were. **Now landed and re-checked against the finished tool: the list of unexplained checks drops from 16 to 10, and the three cases deliberately picked as "must NOT be cleared" are all still flagged.** One detail earned its own warning — the total read the same before and after the final correction to the tool, but it was not the same ten; only comparing the two lists item by item showed that anything had moved.
- **m23-ee-2b — the last three `?? []` vacuity sites hardened, and one of them had been failing for three weeks over its own fixture name** (`m17b:125→133`, `m23a2:360→359`, `m23k4a:176→181`). The filed plan offered two fixes for `m17b` as alternatives — pin the count, or pin the field's presence — and said to decide by reading the gate. Reading it answered *both*: the gate really does perform undoable edits before that point, and the reply really must carry the list. The separate discovery is the interesting one. That check asks "did zooming add anything to the undo history?" by searching the history for the words *zoom*, *ppb* or *row*. The track it creates for itself was named **`ZoomOrch`**, so the entry `Add Track 'ZoomOrch'` matched its own search and the check failed — every run, for the life of the gate, while the app was behaving correctly the whole time. It had been diagnosed correctly weeks ago and then written into the file's header as an accepted quirk rather than fixed, which cost one word to put right (`OrchA`). The same leg also printed nothing at all when it failed, so there was no way to see any of this without adding a diagnostic first. Both are now fixed: the check is green and a failure would say why. Verified in both directions — all three new conditions reject all four broken-response shapes, all three old ones accepted all four, and live runs give 19/1 (the single remaining failure is a separate known bug), 31/0 and 45/0.
- **m23-ee-2a — the three `devicesOf` vacuity sites hardened** (`m20d:262`, `m20e:1251`, `m23bp:846`). Each read `r.result?.devices ?? []` off `output.setDevice` and asserted an ABSENCE ("pin released"), so a renamed or missing `devices` field made the leg pass having checked nothing. Pinned on the response (`length >= 1`), not on the hardware. Verified both ways: the old condition passes on all four degenerate response shapes while the new one rejects them, and a live staging round-trip confirms the pin passes on a healthy run (3 devices, none selected, system default unmoved).
- **m23-ee-1 — the `every()`-vacuity census.** `[].every(f)` is `true`, so an assertion over a runtime-derived collection passes vacuously when that collection is empty. Swept all 71 non-harness staging gates with an acorn AST (`scripts/every-vacuity-census.mjs`) rather than a grep, because the filed scope counted comment prose: **130 code sites, 108 cleared, 21 actionable candidates across 16 gates**, tabulated per-site in `docs/research/2026-08-09-every-vacuity-census.md`. Polarity halves the axis — `some(…)` and `!every(…)` redden on empty and need no guard. The instrument was licensed against four known answers before any new result was believed; three failed first and each taught it a missing rule.
- One check **could never have reported a failure at all.** It always signalled
  success when it finished, no matter how many of its own tests had failed. It
  has been quietly failing two tests for some time while reporting a clean pass
  every single run.
- The same check also **spoils its own setup.** It tests how the app behaves when
  the AI audio generator is switched off — but starting that generator is part of
  what it does. So it passes the first time and fails every time after, until the
  generator is switched off again by hand.
- A second check **contradicts its own written rule.** A note at the top of the
  file says to clear text focus a specific way because the obvious way does not
  work. The code then does it the way the note warns against. Everything after
  that point fails in a chain.

None of these are new breakages and none were caused by this work — all three
were confirmed present beforehand. They are now written down as tasks instead of
sitting invisible.

Separately, while investigating: **the Stop button for the AI audio generator does
not reliably stop it.** If it loses track of the running process it reports "was
not running" and leaves it running. The status display, meanwhile, correctly shows
it as healthy — so the app contradicts itself. Also written up as a task.

## 2026-07-30 — The last two checks that could lie to you, and the last two that tested nothing

The previous entry ended by naming two automated checks that were still leaving
behind the false "you crashed" marker. Both are fixed. No check in the project
leaves that marker any more, so the app will only offer to recover your work when
something actually went wrong.

Those same two checks had a second, quieter problem. Every check is supposed to
rebuild DAW Pro before testing it, so that what gets tested is the code as it
stands right now. These two skipped that step and simply ran whatever build
happened to be sitting on disk — which could be hours or days old. A check like
that reports a confident pass without having looked at your current code, and
gives no sign that anything is wrong. It has bitten us before, on the very
feature these two checks were written to guard.

Both now rebuild before they run. That was the whole point of converting them,
and with it done, every check in the project that starts the app also builds it
first.

Nothing about the app itself changed here — this is entirely about whether our
own checks can be believed.

## 2026-07-30 — Our tests were leaving DAW Pro convinced it had crashed

When DAW Pro starts, it writes a small marker file to say "a session is running",
and deletes it on a clean exit. If that marker is still there at the next launch,
the app concludes the previous session crashed and offers to recover your unsaved
work. That is exactly what you want after a real crash.

Our automated checks launch DAW Pro and then stop it abruptly, which skips the
clean-exit path — so every check run left that marker behind. The next time you
opened the app for real, it would offer to recover from a crash that never
happened. Test tooling has no business telling you that.

The teardown step now removes the marker, and does it in one shared place rather
than leaving each check to remember. The safety rule is that it only ever removes
a marker it can prove belongs to the copy it started: it compares the recorded
process against its own, and if there is any doubt at all — the file is missing,
unreadable, malformed, or names a different session — it leaves the file alone.
Your real recovery marker is never a candidate for deletion.

Two things worth being straight about:

- **A check run started while you have DAW Pro open will still disturb this.** The
  app writes that marker to a fixed location, so a second copy overwrites the
  first one's. The cleanup cannot undo that, so the check now refuses to run at
  all if it sees DAW Pro already running. The deeper fix — giving test runs their
  own private data folder instead of sharing yours — is written up as its own
  task, because test runs currently share your recordings, autosaves and
  generated-audio folders too.
- **Two checks are not covered yet** (`m23o1`, `m23o2`). They still stop the app
  their own way and still leave a marker. They are next.

While verifying this we also found that our leak detector — the thing that
reports whether a check left a stray copy of the app running — was reporting
stray copies that did not exist, by matching against its own search command. It
had already been wrong in the other direction last week. It has been rewritten
and moved into the repository so it stops being re-invented.

## 2026-07-30 — Our own test tooling was quietly checking the wrong app

Nothing in DAW Pro itself changed here. This is a fix to the automated checks we
run against the app before calling a feature done — and it is worth writing down
because for a while those checks could pass without proving anything.

The checks work by launching DAW Pro and driving it like a very fast user. Eight
of them were launching it *without rebuilding first*, so they were testing
whatever version happened to be lying around from earlier — possibly hours old,
possibly missing the very change being tested.

While fixing that we found something worse. Four of the eight never shut their
copy of the app down when they finished. The abandoned copy kept holding the
connection, so the *next* check would fail to start its own copy and silently
talk to the leftover one instead. We watched this happen: five checks reported a
clean pass against an app they had not launched — one of them finishing in a
single second — and three others reported failures that were not real, caused
purely by inheriting leftover state. False passes and false failures from the
same root cause.

All eight now build first, and every one shuts down after itself, on success and
on failure alike. We also replaced the tool that audits these checks: it had been
looking for a specific line of code that an earlier cleanup had replaced with a
shared helper, so it had stopped being able to see the very thing it was built to
count. It now checks itself against a known-good list so it cannot go blind
again without saying so.

Two things this left on the machine while we were fixing it, both now cleaned up
and worth knowing about:

- **Three copies of DAW Pro were left running.** They had no window and no
  connection — they were the copies that lost the race for the connection and
  kept running anyway — so our own "did anything get left behind?" check, which
  looked at the connection, reported all clear. It only looks at connections; a
  leftover copy without one is invisible to it. It now looks for the copies
  themselves.
- **A stale recovery marker.** Shutting a copy down abruptly leaves behind the
  file DAW Pro uses to detect a crash, so the next launch can offer to recover
  from a crash that never happened. If you have seen an unexpected recovery
  prompt, that is where it came from. Only one of these checks currently cleans
  that up after itself; making all of them do it is the next task, and it will
  always leave alone any marker belonging to a copy you are actually running.

## 2026-07-30 — More insert slots on the master and bus strips, and they stay put

You asked for this one: the master and bus strips now hold **five** insert slots
by default instead of three, the slots are drawn whether or not you've filled
them, and a longer chain scrolls inside its own space.

The master strip is where the difference is biggest, because it never had any of
this. Until now it simply grew as you added effects — so every insert pushed the
volume fader, the loudness meters, the stereo display and the reference row a
little further down. Measured on the real window, an eight-effect master chain
moved the fader **205 points** down the strip. Add a compressor and the fader
you were reaching for had moved. Now the insert area is a fixed size: the fader
and everything under it stay exactly where they were, and effects past the fifth
scroll within the insert list rather than shoving the rest of the strip around.

Bus strips already held their shape; they were just cramped at three slots. A bus
is where a glue chain lives — compressor, EQ, saturation, limiter — so they now
get five as well. Ordinary channel strips are unchanged at three, deliberately:
they're the most numerous strips in the console and they don't need the space.

Two honest notes. On the master, holding five slots open costs the room the strip
used to give the fader when the chain was short, so the master now scrolls a
little sooner than it did — it already started scrolling at the third insert
before this change, so the difference is small, but it's real. And on a short
window a bus quietly gives slots back rather than squeezing the fader, dropping
to four or three; every bus does it at the same moment, so the console stays
even with itself.

## 2026-07-30 — Making the checks that guard the app check the right app

No change you can see in the DAW today. This is work on the machinery that
verifies it, and it was overdue.

Alongside the automated tests there are 42 "gates" — scripts that launch the
app for real and drive it the way a person would, because some things only a
live run can see. The trouble was that most of them never launched anything.
They connected to whatever copy of the app happened to be running, which might
have been built hours earlier from different code. Run one after a change and
it would report a confident pass that meant nothing at all.

The build-and-launch steps that a handful of gates did get right had been
copy-pasted seven times over, so there was no single place to fix. There is now:
one shared module that builds the app, launches its own private copy, and shuts
it down afterwards. Getting a connection without a fresh build is no longer
possible, and the rule that these scripts must never touch the copy of the app
you have open is enforced in that one place instead of being remembered
separately in every file.

All seven gates that already launched their own copy now use it, each checked
assertion-by-assertion against a recording of its previous run to prove nothing
changed in the process. The last two needed the shared module to grow a little
first — they start the app in a different mode, and a shared thing that cannot
accommodate real differences just gets worked around, which is how seven copies
came to exist in the first place. Still ahead: the eleven gates that launch
without building, and the twenty-four that never launch at all.

One of the gates turned out to have been failing quietly for several days — it
counts the app's commands and had not been told about two that were added on
purpose. A check nobody runs is indistinguishable from a check that passes.

## 2026-07-29 — The safety net for a stuck plug-in was never actually attached

Yesterday's investigation turned up a defect in the code that is supposed to
stop a misbehaving plug-in from hanging the app. Today it is fixed, and the fix
is smaller and stranger than it sounds.

When the app loads an instrument or effect plug-in, it starts a ten-second
countdown alongside it. If the plug-in has not finished by then, the app gives
up and reports it as stalled instead of freezing. That was the design. The
problem was that the countdown itself was scheduled on the same main thread the
plug-in runs on — so the alarm could only ring once the main thread was free,
which is to say once the problem had already gone away. It was a smoke detector
wired to the light switch in the room it was watching.

This was not theoretical. Measured side by side under identical conditions, with
the main thread deliberately held busy for one second and a 200-millisecond
countdown: the old arrangement fired zero times out of six, always returning
"finished successfully" a full second later. The new one fired six times out of
six, every time within about 201 milliseconds. An intermediate version — which
changed everything *except* moving the countdown off the main thread — also
scored zero out of six, which pins the cause precisely.

The countdown now runs independently of the main thread, so the deadline is a
real deadline. The mechanism lives in one place with its own tests rather than
being hand-rolled at each site.

**What this does not fix, stated plainly.** The app now *decides* on time that a
plug-in has overrun. It still has to get back onto the main thread to record
that decision — so a plug-in that is actively holding the main thread hostage
can still freeze the app, which is the worst case this guard was imagined for.
Genuinely solving that means running plug-ins outside the app's own process, and
that is a much larger piece of work; it is written down rather than glossed over.
No timeout can interrupt code that is already running.

One honest side effect. Several audio-plug-in tests had been passing on what
turned out to be a coin flip — the old countdown lost the race most of the time,
so a load that genuinely took twenty-odd seconds was recorded as success. With a
working deadline they started failing truthfully. The cause is the test machine,
not the app: the same load takes about half a second when run on its own, and
twenty-six seconds when several hundred other tests compete for the same thread.
Test runs now get a longer allowance while the shipped app keeps its ten-second
limit, and a new test pins that shipped value so it cannot quietly drift upward.

Full suite: 4421 tests across 448 suites, green on eight consecutive runs.

## 2026-07-29 — Chasing the last "flaky" test found a real bug in a safety net

The last of four intermittent test failures was measured rather than guessed
at, and the measurement turned up something more important than the test.

The numbers: loading a General MIDI sound bank takes about 45 milliseconds when
that test runs alone, and about 20 to 24 seconds when the full suite runs
around it — a 400-fold difference. Deliberately starving the machine of CPU
did *not* reproduce it, which rules out plain slowness. Strangest of all, the
test passes most of the time despite always exceeding its own 10-second limit,
and how long it takes doesn't predict whether it passes: a 19.6-second run
failed and a 23.8-second run passed.

The reason is a real defect, now filed. The 10-second limit is implemented as a
timer that has to get back onto the app's main thread to fire. When the main
thread is busy, the timer is stuck behind whatever is holding it — so it isn't
really a deadline at all, and whether it or the actual work finishes first is a
coin flip. That matters well beyond tests: this limit exists to stop the app
hanging on a plug-in that has seized up, and seizing up the main thread is
exactly what a bad plug-in does. The safety net fails in the precise case it
was built for.

The test itself now reports one clear failure naming the timeout, instead of
three that looked like three unrelated problems.

Suite: 4413 tests / 446 suites.

## 2026-07-29 — Two more "flaky" tests fixed, and one of them was lying

Two tests only ever failed when the whole suite ran at once. Both were
measuring something that belongs to the entire machine rather than to the code
under test.

The first checked that redrawing an EQ curve finishes in under a millisecond —
a fair thing to want, but an absolute stopwatch reading taken while every core
is busy measures the machine's mood, not the code. It now times a fixed
reference calculation in the same run and checks the curve redraw stays within
a multiple of it, so the answer no longer depends on how loaded the machine is.
The multiple was chosen from measurements across idle, full-suite, and
deliberately overloaded conditions rather than picked to make one run pass, and
a companion test deliberately triggers a slowdown to prove the budget still
catches one.

The second checked that a real-time audio path never allocates memory. It used
two probes, and the noisy one turned out to be worse than noisy: under load it
reported a *negative* number of retained allocations on a loop that only ever
retains — impossible, and caused by other threads freeing memory at the same
time. It was also blind to exactly the kind of allocation it was supposed to
catch. Removed. The surviving probe watches only the calling thread, catches
both transient and retained allocations, and was confirmed to fail when a test
allocation was deliberately added.

Suite: 4413 tests / 446 suites, verified across three consecutive clean runs.
One genuinely intermittent test remains and is being worked separately.

## 2026-07-29 — A "flaky" test turned out to be a real bug about sample rates

One of four tests we'd written off as randomly failing wasn't random at all. It
checked that the limiter reports 240 samples of lookahead delay — but 240 is
just 5 milliseconds at 48 kHz. Plug in an audio device running at 44.1 kHz and
the correct answer is 221, so the test failed every single time at that rate.
It only *looked* intermittent because the engine follows whichever audio device
is active, and this machine has several installed.

The rule that turns 5 milliseconds into a sample count now lives in exactly one
place, and both the limiter and the tests read it from there, so they cannot
drift apart. A new test pins the derivation at 44.1 kHz, 48 kHz and 96 kHz
directly, without needing any audio hardware.

Worth stating plainly: every past run that shrugged this off as "the known
flake" was mis-attributing a genuine rate-dependence bug. Three genuinely
intermittent tests remain and are being worked separately.

Suite: 4412 tests / 446 suites.

## 2026-07-29 — Running the tests no longer litters your recovery sessions

Running the test suite used to write crash-recovery snapshots into your real
application-support folder, and the app would then offer that junk back to you
on next launch as sessions to recover — empty projects with names like
`Recovered` and `T`. Merely running the tests dirtied your data.

Test processes now write their recovery bundles into a throwaway temporary
folder instead. The shipped app is unaffected: it still uses the real location,
and the rule that decides where files live is unchanged and still has exactly
one definition, so the autosave writer and the recovery scanner cannot drift
apart.

The five stray bundles already in your folder were deliberately left alone —
deleting things in your data directory is your call, not the fix's. They are at
`~/Library/Application Support/DAWPro/Autosave/` if you want them gone.

Verified by running the whole suite twice and confirming the real folder was
untouched both times, while the redirected temporary folders were confirmed to
have actually been created — proving the writes were diverted rather than
simply not happening. Suite: 4411 tests / 445 suites.

## 2026-07-29 — Voice training: use any voice you have the rights to

The rule that you could only train a voice on your own recordings is gone, on
the project owner's instruction. Train on whatever dataset you supply, or drop
in a third-party voice model — the app does not check whose voice it is, and it
will not refuse one on provenance grounds. **Responsibility for holding the
rights to a voice sits with you**, including if you choose to use one you are
not authorised to.

The app, the control surface and the MCP tool descriptions were already
relaxed. What was still contradicting the policy was documentation and agent
guidance, which is now aligned: the AI-agent wire reference no longer instructs
agents to refuse third-party voices, and the voice sidecar's README and
voice-store comment no longer claim voices can only come from your own
recordings. No behaviour changed and no logic was touched — the sidecar edit is
comment-only.

Unchanged: nothing is bundled — the voice store still ships empty, and `base`
remains an untrained smoke-test target rather than a voice. Importing a model
file you supply is supported; going out and finding voice models at scale is
not something the app does.

## 2026-07-29 — Note-level vocal pitch correction: design spike says GO

No user-facing change. This is a decision, not a feature.

We investigated what it would take to build Melodyne/Auto-Tune-class pitch
correction — split a vocal into notes and edit each one's pitch and timing —
and the answer is **GO**. The expensive half turns out to be already built: the
time-stretch library we ship for clip stretching can also shift pitch while
keeping formants intact (so a corrected vocal still sounds like the same
singer, not a chipmunk), and it can do it on a curve that changes over time
rather than one fixed amount per clip. The missing half is a pitch detector,
which we can write ourselves on an FFT already in the app, adding no new
licensing obligations.

First shippable piece is an automatic tuning pass an AI agent can drive,
estimated 4.5–5.5 weeks; the full note-by-note editor is 14.5–19.5 weeks. The
largest genuine unknown is how it sounds on real voices — a listening test that
is scheduled as the first half-week of work rather than assumed away.

Two documents landed in `docs/research/`: a survey of pitch-detection
algorithms and note segmentation, and the design with the GO/NO-GO. They were
written independently, and comparing them surfaced an open question — the
design picked a hand-written detector without having seen a small MIT-licensed
model that may do the job better. That is filed as `m23-ap` and must be settled
before implementation starts.

## 2026-07-29 — Click a track header to select everything on it

Click a track's header in the sidebar and every clip on that track is selected —
ready to move, nudge, or delete as one. Hold Shift (or Command) and click a
second header to add its clips to what you already had, and click it again to
take them back off. Mix and match freely: a header click, then a Shift-click on
one more clip, and the whole lot deletes in a single undoable step.

Selecting a track selects its *clips* — a track is not a separate thing you can
select, so group delete never has to guess whether you meant "these clips" or
"this whole track". Clicking the header of an empty track simply clears the
selection, the same way clicking empty space in the timeline does.

One deliberate quiet moment: selecting a track does **not** open the piano roll
on any of its clips. A header has no one clip you pointed at, and opening the
note editor on whichever happened to sort first is the kind of surprise that is
worse than doing nothing. Clicking a clip still opens it, exactly as before.

## 2026-07-29 — Arrow keys nudge clips in the arrange

Select a clip — or twenty — and tap the left and right arrow keys to walk them
along the timeline. Each press moves the selection by one grid step, so what the
arrow does always matches the grid you can see. Hold Shift for a whole bar,
Option for a fine 1/32-beat step, and hold the key down to slide something into
place; a burst of presses collapses into a single undo rather than forty.

A nudge MOVES your clips, it does not tidy them up. A clip sitting deliberately
off the grid keeps its offset and simply travels — and a group keeps its internal
spacing exactly, including when it runs into the start of the song, where the
whole selection stops together instead of stacking up at beat zero. If snapping
is off, the arrows still work, one beat at a time.

Arrows stay out of the way when they belong to something else. Renaming a track,
typing in any field, or working with a modal open, the arrow keys do what they
always did. And while you have notes selected in the note editor, the arrows are
left alone rather than sliding the clip out from under you.

Up and down do not move clips between tracks yet — that needs groundwork we have
not built.

## 2026-07-29 — AI assistants can now delete and move clips in groups, as one undo

Ask the assistant to delete four clips and it used to issue four separate
commands, leaving you four separate undos to walk back. Now it sends one, and one
Cmd-Z puts everything back — the same single-step behaviour you already got when
you selected and dragged clips by hand.

Group moves also report what actually happened. If you ask to shift a selection
eight beats earlier but the leftmost clip is only two beats from the start, the
whole group stops at the edge together, keeping its spacing, and the assistant is
told it moved two beats rather than eight — so it can adjust instead of quietly
compounding the mistake on its next move.

## 2026-07-29 — A new instrument track now tells you what to do with it

Add an instrument track and its lane no longer sits there blank. A quiet
"Double-click to add a clip" appears on it, and stays until the lane actually has
a clip. Add one and the hint goes; delete it and the hint comes back.

The double-click itself has worked since the previous round. The problem was that
nobody could tell — a gesture you cannot see is not an affordance, and the report
that prompted this used exactly that word. So the fix is the sentence, not the
behaviour.

It only appears where it is true. Audio and bus lanes refuse MIDI clips, so they
never show it; the hint asks the same question the refusal does, rather than a
second one that happens to agree today. And it is about the lane's contents and
nothing else — add a track while the transport is rolling and it still appears,
because an empty lane is empty either way.

It is deliberately dim and deliberately not clever: no arrow, no exclamation, no
animation. In a project with four fresh tracks you see it four times at once, and
anything louder would read as clutter rather than help.

## 2026-07-29 — Hold a key after pressing stop, and it no longer goes quiet on you

Play something, press stop, then hold a key down on your MIDI keyboard. Until now the note
sounded for eight seconds and then died underneath your finger, while the key was still
down. Nothing you could do brought it back except letting go and pressing again.

This was filed as an obscure corner case — supposedly it needed a freshly-launched app and a
track that had never played. That turned out to be wrong, and a comment inside the engine
asserting the false version is what kept it filed that way. Every stop, seek and tempo change
unpublishes the track's schedule, so the affected state is simply "the transport is stopped":
the ordinary condition for practising, auditioning a sound, or noodling between takes.

The engine now counts how many thru keys are actually held down and keeps the instrument
rendering while any of them are. A note held for a minute sounds for a minute. Releasing it
still lets the tail ring out and then genuinely goes idle, so a stopped project costs nothing.

Two limits are documented rather than hidden. A note sustained by the pedal alone — key
already released — is still cut, because the count tracks keys rather than voices. And if a
note-off is genuinely lost (a cable pulled mid-note), the note stays stuck, which is honest —
the voice really is stuck — but there is still no panic button to clear it. Both are filed.

## 2026-07-29 — The note editor's BAR readout stops pretending to be the playhead

In the note editor's header, beside the buttons that add or remove a whole bar, sits a small
`BAR 1` readout. It was drawn in the same glowing cyan the app uses everywhere for "here is
where playback is" — so if the playhead was sitting four bars away from the part you were
editing, the header still lit up `BAR 1` in playback cyan. It looked like a position. It
never was one: it is simply the bar those two buttons will act on.

It now reads in the same quiet grey as the zoom percentage a few chips to its left. The
words and the number have not changed, and neither has what the buttons do — the only thing
that was lying was the colour. Cyan in the note editor means the playhead, and now it only
ever means the playhead.

## 2026-07-29 — Your effects have their names back

Insert slots in the mixer used to eat their own labels. A compressor read `Compr...`, a
limiter read `Lim...`, and the newest effect read `Bass Enh...` — which is worse than it
sounds, because `Co...` is not obviously a compressor rather than a chorus. You were being
asked to recognise your effects by their first few letters.

Every built-in effect now shows its full name, on every strip, whether or not it is working.
There are only ten of these names and we know all of them, so there is no good reason for
any of them to be cut short.

Making the room meant moving the little activity meter on compressors, limiters and gates.
It used to be a small bar squeezed in beside the name; it is now a thin line running under
the whole row, lighting up the same way. It is a fair trade but it is a trade: the meter is
easier to miss at a glance than it was, and in exchange the name it was crowding is
readable. Built-in slots also lost their small "edit" glyph — clicking anywhere on the slot
opens the controls, which it already did.

Plug-ins are different and stay different. A third-party plug-in's name comes from its
maker and can be any length, so those still shorten with a `…` when they have to. A name we
chose is a label; a name someone else chose is data.

## 2026-07-29 — The bass enhancer tells you what it is doing

The knobs are in the mixer now. Add **Bass Enhancer** from a channel's "+" menu and you get
the three controls: **crossover** (set it to the low limit of the speaker you are worried
about), **amount**, and **mix**.

The card also tells you something most plug-ins in this category do not. Above the knobs,
before you touch anything, it says: **adds harmonics that are not in your recording**. Both
things about this effect are true at once — it makes bass audible on small speakers, *and*
what it makes audible is new sound rather than something uncovered. A beginner should not
have to work that out from a spectrum analyser. So the card says it plainly, says the
harmonics print into your bounce, and explains what the knob ranges cannot. Where to
put the crossover — the lowest note your speaker plays. That amount sets how loud *and* how
bright the harmonics are, and that the character holds whether the part is quiet or loud.
That mix trims how much of them you hear and never turns your own signal down.

None of that is a tooltip. It is drawn on the card, in plain type, and it carries no
numbers: a number sitting an inch above the real readouts would read as a measurement of
your track, and it is not one.

If you want to hear the point of the effect, play a sub-heavy bassline on a laptop speaker
with the enhancer bypassed and then active. Rendered through a simulated small speaker, the
dry part loses around 31–40 dB of what it started with, and the enhanced part still delivers
11–17 dB more than the dry one does — most where the note is lowest, which is where the
speaker is worst.

## 2026-07-29 — Bass that survives a phone speaker

A laptop speaker cannot move enough air to reproduce a 50 Hz note. It never will. But
your ear will happily *infer* that note if it hears the harmonics that sit above it — the
missing-fundamental effect, and the reason a bassline can still read as a bassline through
a phone.

There is now a bass enhancer that does exactly this. It listens to the low end below a
crossover you choose, generates the harmonics that low end *would* have produced, and mixes
them back in above the crossover. Your original low end is untouched; the harmonics are
added on top. On a big system you hear the real bass, on a small one you hear the
harmonics and infer the rest.

It is not a distortion or a saturator, and the difference is audible. A saturator shapes
everything you feed it, so it colours the whole track. This works on the low band alone,
and it normalizes that band's level before shaping it — which means the effect sounds the
same on a quiet passage and a loud one, instead of getting harsher as the part gets louder.
Two controls do the work: **amount** sets how much harmonic content is generated and how
bright it is, **mix** sets how much of it you hear.

Turn either control to zero and the audio is bit-for-bit what went in — not "almost the
same", byte-identical.

You will find it in the "+" menu on any mixer insert slot, alongside the other effects, and
your AI assistant can add it for you by name.

One thing we want to be straight about, because it is easy to sell this the wrong way: this
effect **adds sound that was not in your recording**. It is not uncovering bass that was
hidden in there — it is manufacturing new overtones and printing them into your bounce. That
is the honest description of what every enhancer of this kind does, and the effect's own
panel says so above its controls rather than leaving you to find out later.

## 2026-07-29 — The EQ now shows you where the instrument lives

The frequency reference stopped being something only the AI assistant could read. Open the
EQ on a bass or a guitar track and the plot itself now shows you two things: a soft shaded
band where that instrument's notes actually sit, and a dashed line at the frequency below
which there is nothing worth keeping. You can see, while you drag, whether you are cutting
rumble or cutting the instrument.

The guidance deliberately does not look like your settings. Everything bright on that plot
means something true about *your* track right now — the cyan curve is what you built, the
green is what is actually being measured. A reference is published advice about a *kind* of
instrument, so it is drawn in neutral dashes, and its labels read `TYPICAL 41–98 Hz` and
`CUT BELOW 30 Hz` rather than borrowing the wording of the real controls. Advice should
never be able to pass for a readout.

Where the app does not know, it says so plainly instead of inventing a range. A recorded
audio track gets "the app cannot know what was recorded"; a track with no instrument chosen
asks you to choose one; a drum kit points out that each piece has its own range and suggests
asking the Copilot about the kick or the snare specifically. And where the underlying
research is soft — a drum's pitch is a tuning choice, not a physical constant — the row says
so on the face of it.

Being straight about the reach: today this draws for pianos, guitars and basses. Other
instruments are in the reference the assistant reads, but cannot yet be identified from the
track alone well enough to draw on your plot.

## 2026-07-28 — Your AI assistant now knows where an instrument actually lives

Ask an assistant to "clean up this bass" and until now it was guessing. It could add a
high-pass filter and it could measure the result, but it had no idea where a bass guitar's
lowest note actually sits — so it had no way to tell a cut that removes rumble from a cut
that removes the instrument.

There is now a built-in frequency reference the assistant can read: for each instrument
family, the range its fundamental notes occupy, the regions that make it sound like itself,
the regions engineers usually clean up, and a recommended high-pass corner it can act on
directly. Ask for the vocabulary with no arguments and it lists every family it knows. Point
it at a track and it works out the family from the instrument, or from the drum note you
name. When it cannot tell, it says so and tells you how to be specific — it never guesses.

**Every number is cited to a source, and the sources were checked.** Each entry carries the
verbatim sentence it came from, the page it came from, and the date it was read. Where the
honest answer was "no reliable source says this", the entry was **removed rather than filled
in with something plausible** — seven instrument families were dropped for exactly that
reason, mostly because no trustworthy source gives an instrument-specific filter setting for
them. Three drum entries ship with an explicit note in the text the assistant reads, saying
their pitch is a tuning choice rather than a fixed property, because that is true and
pretending otherwise would be the kind of confident-sounding advice that ruins a mix.


## 2026-07-28 — An AI assistant can now hear what an effect is doing

Until now an agent working on your mix could read the master output and nothing else. It could
add an EQ, change its settings, and have no idea what came out the other side — it was mixing
with its eyes shut. `fx.spectrum` lets it measure any single effect on any track, or on the
master, and get back the same twenty-four frequency bands the master analyser has always
reported.

The measurement tells you where it was taken, because that turns out to matter. An effect on a
track is measured *before* that track's fader, so moving the fader does not change the reading.
An effect on the master is measured *after* the master fader, so moving that one does. The two
numbers mean genuinely different things, and a reading that did not say which it was would make
a strip and the master look like they disagreed when both were right.

Measuring costs something, so it is leased rather than left running: a measurement stays live
for three seconds and lapses on its own if nobody asks again. Eight effects can be measured at
once. Ask for a ninth and it says no, and tells you the limit, rather than quietly switching one
of the others off. If you have an EQ window open on the same effect the assistant is measuring,
neither one can turn the other off — they each hold their own.

## 2026-07-28 — Your meters keep moving when you click away from DAW Pro

Three more live displays used to freeze the moment DAW Pro stopped being the frontmost window:
the vibe orb in the transport bar, the goniometer's trail, and the stereo correlation numbers
beside it. Click into your browser to look something up, or into a plugin window, and they
stopped where they were — still lit, still showing a number, just no longer telling you the
truth. Come back and they'd jump to catch up.

That is the same freeze the master EQ analyser had, and this is the sweep that found the rest
of them rather than fixing one and hoping. They now update continuously: the orb sixty times a
second, the goniometer trail twenty, the correlation readouts ten.

If you are wondering about battery: while DAW Pro is in front, nothing costs more than it did,
and the orb actually costs less — it had been running at the display's own rate, 120 times a
second, and now holds a steady 60. The whole of the added work is in the background, which is
exactly the work that was missing. That is the difference between a meter that tells you the
truth and one that lies to you, which is not a trade a DAW gets to make. Deliberately absent:
any "pause it when the window is hidden" behaviour. That idea is what caused this in the first
place.

## 2026-07-28 — Channel strips stop shuffling when you add an effect

Every channel strip now keeps a fixed space for three inserts. The fader, the dB number, the
Mute/Solo/Arm buttons, the sends and the output all sit at the same height on every strip, and
they stay there whether a track has no effects or twelve. Add a fourth insert and the list
scrolls inside its own little window instead of shoving everything below it downward.

Before this, a strip grew as you added effects. Five ordinary inserts pushed that strip's pan
row, fader and dB readout down by 121 points while the strip next to it stayed put, so the
console never lined up and the controls moved under your cursor as you worked.

Folding the inserts away still gives the fader more room — it hands back the whole reserved
space, not just the rows you were using, because a fold that kept three empty rows would be a
button that does nothing.

The reserved space explains itself rather than sitting there blank. A strip with no effects
shows a dashed outline saying "No inserts"; a strip with one or two shows the effects you have
and then dashed outlines for the rest, so it reads as "three slots, one filled" instead of
looking like something failed to appear. The outlines are deliberately faint — a hairline, not
a grid of boxes competing with the effect names.

Two honest notes. Compressors and gates are taller rows than the others, so two of them fill
the space and start scrolling sooner — the controls below still do not move. And adding a
*send* can still nudge the rows beneath it; only the inserts are pinned so far.

## 2026-07-28 — The EQ on any track now shows the frequencies, not just the master

This is the one you asked for. Open the EQ on any track and the moving green spectrum is
there behind the curve, exactly like the master EQ has always had. Before today only the
master showed it, because only the master had a meter running; the last three rounds of
groundwork built one that any effect can borrow, and this turns it on.

One thing on the card is worth reading once. The green fill on a track's EQ is measured
*before* that track's fader — so if you pull the fader down, the picture does not move.
That is correct, not a broken meter: it is showing what the EQ is working on, not what is
leaving the channel. The master EQ's fill is measured *after* the master fader, so that one
does follow its fader. The two look identical, so each card now says in plain words which
one you are looking at when you hover it.

If the meter cannot run for some reason, the card shows a flat floor and tells you it is not
running, rather than drawing something that looks like silence. Nothing is ever invented.

Only the EQ card you have open is measured — closing it, or switching the card to the knob
view, stops the measurement. Nothing is running in the background on inserts you are not
looking at.

**Also fixed, and it was there before today:** the master EQ's spectrum froze whenever DAW Pro
was not the frontmost app — click your browser, and the green fill stopped moving while still
looking like a live meter. It has been that way since the curve editor shipped. It now keeps
running whether or not the window has focus, which also matters because an AI agent driving
the app leaves the window in the background most of the time.

## 2026-07-28 — Proving the chain probe works everywhere, not just somewhere

No visible change again — this is the last groundwork entry before the feature surfaces.

The probe was attached to effect chains in the previous entry. The question this one answers
is whether it works on *every* kind of track, or only the one that happened to get tested.
Instrument tracks, audio tracks, buses and the master output are built differently inside the
app, and a probe that quietly worked on three of them would look fine right up until someone
tried the fourth.

All four are now covered, along with the awkward moments: switching one effect for another
while the probe is running, a plugin being swapped underneath it, changing the audio device's
sample rate, and turning an effect off and back on. In each case the reading has to keep
working without a gap, and now has to keep working, because a test fails if it doesn't.

There is also a limit on how much this can cost. A probe that made playback stutter would be
worse than no probe. Eight can run at once, and the measured cost of all eight together is
about 0.7 microseconds per audio block — roughly one part in fifteen thousand of the time
available. The ceiling is enforced by a test rather than by hope.

One thing worth knowing came out of the measurements, and it will be visible when the
displays arrive: a probe on a track reads the sound *before* that track's volume fader, while
a probe on the master output reads it *after* the master fader. Both are correct and useful,
but they answer slightly different questions, so the two displays will say which is which.

## 2026-07-28 — Connecting the chain probe, without disturbing the sound

Still nothing visible, and still deliberately so. The previous entry built the piece that
carries audio safely off the processing thread. This one attaches it to the effect chains
themselves, so any single effect on any track can be asked to report what it is hearing.

Two things had to be true, and both are now proven rather than assumed. The first is that
turning the probe on cannot change your audio in any way — not the sound, not the timing,
not a single sample. Switching it on and off mid-session leaves the output bit-for-bit
identical, and none of an effect's internal state is disturbed, so nothing clicks and no
reverb tail gets cut short when you open or close a display.

The second is subtler. When the audio engine restarts itself — which it does on its own
after certain changes, without telling you — everything gets rebuilt from scratch. A probe
that was switched on before that point has to still be switched on after it. Otherwise the
display stays open showing a reading that stopped updating, which is worse than showing
nothing at all: it looks like silence rather than like a failure. That case now has a test
that fails loudly if it ever breaks.

One unrelated improvement came out of the work. Measuring the audio path closely enough to
prove it never pauses for memory revealed that the effect-chain loop itself had been asking
for small amounts of memory on every pass — harmless in practice, but exactly the kind of
thing that becomes a click under load. It no longer does.

## 2026-07-28 — Groundwork for seeing inside an effect chain

Nothing changes for you in this release. This is the first piece of a feature that will let
you watch the spectrum at any point in an effect chain — before the compressor, after the
EQ — instead of only at the master output.

The hard part is that audio processing happens on a thread that must never be interrupted.
It cannot wait for anything, and it cannot ask the system for memory; if it stalls even
briefly, you hear a click. So the measuring cannot happen there. What landed here is the
handover: the audio thread does nothing but copy samples into a fixed buffer it already
owns, and all the actual analysis happens elsewhere, on the same code that already draws the
master spectrum. Not a copy of that code — the same code, so the two readings can never
drift apart.

The buffer has a fixed size, which means it can fill up if the display side stalls, such as
when the window is hidden. Rather than lag further and further behind or show a torn
half-updated reading, it keeps the newest audio, discards the oldest, and counts exactly how
much it dropped — so the display can be honest about what it missed instead of quietly
lying.

None of this is wired to anything yet: no meter, no menu, no visible change. It ships now,
tested on its own, because getting the handover wrong is the kind of bug that shows up as an
occasional click during playback and is nearly impossible to trace later.

## 2026-07-28 — The commands that quietly accepted anything

Twenty-six of DAW Pro's 161 commands used to ignore options they didn't recognise. Ask one
for a project overview and misspell an option, and it would hand back the overview as if
nothing were wrong. Nothing was corrupted — every one of the twenty-six only *reads* — but
a typo looked exactly like success, which is the one response that teaches you nothing.

All twenty-six now answer the way the other 135 already did: they name the option you got
wrong, and either list the ones they accept or tell you they take none. The check runs
before the command does any work, so a mistyped request never reaches a sidecar, a plugin
scan, or the telemetry counters it would otherwise have reset.

This one reversed a decision rather than filling a gap. Six tests asserted the old
permissive behaviour on purpose — one called it "house style", which it had stopped being
some time ago, once 135 commands did the opposite. Those tests now assert the new
behaviour and say why it changed.

The safeguard is that a command can no longer be added without this check: a test reads
the source, compares it against the command list, and names any command that slipped
through. Worth noting what that test *can't* do — it proves the check exists, not that it
runs first. So the ordering is verified separately, by confirming a rejected request never
touches the engine at all. Moving the check later in one command left the source test
perfectly green and only the ordering test caught it.

Because stricter input checking can break whatever was already sending the old, sloppier
requests, the AI-agent bridge was checked too: every one of the twenty-six sends either no
options at all or exactly the ones now allowed, and its test suite passes unchanged.

## 2026-07-28 — A comment that said the work was done

Eighteen commands in DAW Pro take no options at all. Misspell an option on one of them
and it tells you so by name. That behaviour was only actually *checked* for one of the
eighteen — the other seventeen were running on trust.

They are all checked now, from a single table, with the exact sentence pinned rather than
a loose "does it mention the word I typed". Adding a nineteenth such command is a one-line
addition, and if someone forgets, a test reads the source and fails — it no longer depends
on anyone remembering.

What made this worth doing was finding *why* the gap survived. A comment in the test file
announced itself as a completed survey and listed eight commands as covered. Three were.
The other five had never been tested anywhere, and every later count — including the one
that scheduled this work, and the one this session took to double-check it — inherited the
claim without re-deriving it. The comment has been corrected to say what it actually
covers. A comment is not coverage.

Verified on the live control port: four of the five untested commands were driven over the
real connection and answered exactly as pinned, including one that starts a background
process — it refused the bad option without starting anything.

One more thing surfaced while measuring: twenty-six other commands accept misspelled
options *silently*, with no complaint at all. They are all read-only, so nothing can be
damaged, but an assistant that typos an option gets a cheerful success instead of being
told. That is filed as its own item.

## 2026-07-28 — Packaging the app somewhere other than on top of your copy

The script that assembles DAW Pro into a real `.app` could only ever build it in one
place: `dist/DAWPro.app` — the copy you actually launch. That made the packaging path
awkward to test. Checking that a bundle with the speech-model weights sealed inside it
still passes Apple's signature check meant overwriting your app with a 1.5 GB version of
itself, so the check kept getting deferred instead of run.

It now takes `--output`, so a throwaway bundle can be built off to the side and verified
without your copy being touched at all. Both modes were exercised that way and both pass
the stricter signature check.

Two details worth naming. The script registers the bundle with macOS so "quit DAW Pro"
resolves by name — and that registration is machine-wide and outlives the folder, so a
throwaway bundle would leave a ghost entry competing with your real app. Registration is
now skipped for any non-default output. And because the new flag feeds a path straight
into `rm -rf`, an empty path or one that doesn't end in `.app` is refused outright.

The check that mattered most was the one asked before any of this: does the app actually
look inside its own bundle for those weights? It does. But nothing tested that it did —
the neighbouring tests covered every other location, so that one could have quietly
disappeared and left them all green while every weights-bundled build shipped a gigabyte
and a half the app then ignored. That test exists now.

The bundled mode was exercised with a small stand-in for the weights rather than the real
1.5 GB. That proves the payload lands inside the signature and the app finds it; it does
not prove a copy that size completes. That run is filed and waits for you.

## 2026-07-28 — An error message that trailed off mid-sentence

Ask the DAW to play, and misspell one of the options you pass it, and the error you got
back stopped in the middle: "unknown parameter 'bogus' — valid keys are ". Nothing after
"are". That happened for the eighteen commands that take no options at all — there were
no valid keys to list, so the sentence simply ended. Commands that do take options were
always fine.

Those eighteen now say what is actually true: "transport.play takes no parameters."
Commands with real options are untouched, down to the byte.

The interesting part is what the tests said. The change to the wording should have
broken every test that checked the old sentence — and it broke none of them. Not because
the tests were weak, but because for these particular commands there was nothing
checking that part of the message at all: eight of the eighteen checked only that an
error happened, and ten had no such test whatsoever. The message had been wrong for a
while with nothing to notice.

There are now checks on the corrected wording, including the plural form, which turned
out to be unguarded even after the first fix. The ten commands with no coverage are
written down as work rather than left as a quiet gap.

## 2026-07-28 — The voice tools no longer refuse what the product permits

The voice panel and the voice tools carried a rule that had been withdrawn. They said
you could only train and convert with your own voice, never anyone else's — and that
line was still being shown to you in the app and told to any AI agent connected to the
DAW, long after the decision had gone the other way. An assistant asking what it could
do with voices was reading a prohibition that no longer existed.

The product now says what it actually does: third-party voice models are supported, and
you are responsible for having the rights to any voice you train or convert with. That
is a statement about who carries the responsibility, not about what you are allowed to
attempt. One phrase survived the change untouched — "a voice you have the rights to
use" — because what was withdrawn was the prohibition, not the requirement that you
have the rights.

The old wording lived in fifteen places, which is roughly twice as many as anyone had
written down. Two tests were guarding the old copy; both were pointed at the new copy
rather than deleted, so the words stay guarded. A new check now walks the entire family
of voice tools and fails if the withdrawn rule reappears in any of them — and it earned
its place immediately, catching a description that a hand-written search had missed.

One layer still disagrees: the local voice-conversion sidecar's own documentation
continues to assert the old rule. Those files are on a do-not-touch list, so that
correction is filed and waiting rather than quietly skipped.

## 2026-07-27 — Starting a speech-model download and checking in on it, instead of waiting on it

The speech-model installer from the previous entry could only be driven from inside the
app itself. Now an agent can ask for a model by name and get an answer back immediately
— not the finished model, just an acknowledgment that the download has begun. Checking
whether it succeeded is a separate question, asked as many times as you like, with no
consequence to asking again.

That split matters because the honest cost of this download is unknown in advance: it
could be forty megabytes or a couple of gigabytes, and the network could be fast or
slow or unavailable. A command that waited for the answer would either time out on a
slow connection or hold a conversation hostage on a fast one. So starting the download
and checking on it became two different questions, the same way an audio time-stretch
already works: kick it off, then look in on it whenever you like.

The one rule that had to be enforced rather than assumed: only one of these downloads
ever runs at a time. Nothing before this stopped two requests from both deciding a
model wasn't installed yet and both writing into the same folder at once — the kind of
mistake that only shows up the day someone actually asks twice, which an agent that
doesn't remember asking already might well do. A second request while one is already
running is turned away, told which one is currently in progress, rather than queued or
silently merged with the first.

Checking in on progress meant confronting a small annoyance in how progress normally
gets reported: it arrives on its own schedule, from code that has no idea an agent is
waiting, and there's no guarantee it arrives in order if you're not careful about how
you listen to it. The fix was to always keep only the latest update rather than a
running log — a poller doesn't want history, it wants "where are things right now," and
that question has one right answer at any moment, however the updates arrived.

## 2026-07-27 — Downloading a speech model, and the folder nobody would have looked in

DAW Pro can now fetch a Whisper model for itself instead of expecting one to already
be sitting on disk. The download is WhisperKit's own — we do not own an HTTP client
for this, the same way we do not own a resampler.

The whole item was one mismatch. WhisperKit hands its download to Hugging Face's Hub
client, which files things away as `<base>/models/<repo-id>/<variant>/`. Our catalog
scans the *immediate children* of the models folder. Point one at the other and you
get a complete, correct, multi-gigabyte download that the app reports as "no speech
model installed" — no error, no warning, nothing to search for. So the download is
staged and then moved into the shape the catalog actually reads, and the installer
refuses to call itself finished until the catalog's own scan can find what it just
wrote.

Staging happens inside the models folder as a dot-prefixed directory, not in a temp
folder. Two reasons: same volume means the move is a rename rather than a second copy
of 1.5 GB, and the scan skips hidden files, so a half-finished download can never
show up as a broken model. It is deleted on failure, which was confirmed the hard way
— a real fetch timed out mid-install and left nothing behind.

The tokenizer turned out to be a second download from a different repository
altogether: the WhisperKit model folder contains no tokenizer at all. Without it the
first transcription would quietly go online, which is the one thing on-device
transcription is supposed to avoid. It now lands per-variant, because an English-only
model cannot borrow a multilingual model's tokenizer.

One behaviour is now written down rather than merely true: the model used when nobody
names one is the first in alphabetical order. Install `base` next to `large-v3-turbo`
and every transcription silently switches to `base`. That is pinned by a test so the
decision to change it is a decision, not an accident.

The MCP server's test command used to name its 24 test files one by one. That works
until someone adds the 25th: it compiles, it produces output, and it never runs. The
suite reports all green and the exit code is zero, because nothing was ever told the
file existed.

It now globs the directory instead. A list is something you maintain; a query is
something that stays true.

This was proved rather than assumed, by putting one deliberately failing test on disk
and running both versions against it. The old command: **exit 0, 262 passed, 0
failed**. The new one: **exit 1, 263 tests, 1 failed**. Same file, sitting there
compiled, in both runs — the old gate simply never looked at it.

The glob matches `*.test.js` specifically rather than sweeping the whole directory,
because Node treats *anything* under a folder named `test/` as a test file. A future
shared helper would have been executed as a suite — which is the same class of
surprise, just pointing the other way.

## 2026-07-27 — Transcription is now something you can ask for

`clip.transcribe` (and the `clip_transcribe` MCP tool) turns a clip on the timeline
into words with beats attached. An agent can now ask "what is sung here?" and get an
answer it can edit against.

The interesting decisions were about what to *refuse*.

**A time-stretched clip is refused, not mapped.** A stretched clip's audio no longer
lines up with its source file, so every returned timing would be wrong — but
plausibly wrong, which is worse than an error. It now throws and names the ratio,
telling you to run `clip.setStretch ratio 1` first. The refusal triggers on exact
identity: a ratio of 1.0001 is refused too, because "close enough" silently
reintroduces the drift. Pitch-shift alone is *not* refused — it doesn't move the
timeline — and there is a test whose only job is to hold that line, because the
neighbouring `isStretchIdentity` property bundles the two together and would have
been the easy, wrong guard to reach for.

MIDI clips and unknown clip IDs are refused the same way, with errors that say what
to do instead rather than just what went wrong.

**It blocks rather than returning a job handle.** That follows the precedent already
set by `vc.convertVocals`, not a fresh preference. The MCP timeout is a new 300-second
tier, sized off the measured ~94-second first-run cost on a cold machine — a one-time
Neural Engine compilation, not a per-length cost, so it sits between the render tier
and the voice-conversion tier rather than scaling with clip duration.

The clip-window-to-file-range mapping reuses the existing rule rather than restating
it, and WhisperKit turned out to already clamp a range that overruns the end of a
file, so a clip whose window extends past its source degrades to "read to the end"
instead of reading out of bounds.

One hazard found in passing and **not** silently absorbed: the MCP server's test
script is a hand-maintained list of files rather than a directory glob, so a brand-new
test suite can compile, produce output, and never run — passing green by omission. The
new suite was added to the list; making that structural is filed as its own item
rather than folded in here.

## 2026-07-27 — The DAW can hear words, and knows which beat each one lands on

`WhisperTranscriber` turns an audio file — or a sub-range of one — into text with
**segment and word timings expressed in beats**, not just seconds. Local, on-device,
nothing leaves the machine.

Beats are the point. Seconds are what a speech model returns; beats are what a DAW
can act on. The mapping goes through the project's existing `TempoMap`, so a
transcript stays correct across a tempo change instead of drifting after the first
one.

Three things were measured by running the path rather than reading documentation,
and each changed the work:

- **The resampling was already handled.** The plan called for converting audio to
  16 kHz mono ourselves. WhisperKit does that, and accepts a time range while it is
  at it. Writing our own would have been a second copy of a rule it already owns.
- **Word timings depend on the model, not just the flag.** They require alignment
  heads in the compiled decoder; ours has them, confirmed before a line was written.
- **First transcription on a machine costs ~90 seconds; every later one ~1 second.**
  That is one-time CoreML compilation for the Neural Engine, cached afterwards. It
  is why the transcriber holds a single loaded model rather than constructing one
  per call — and why the forthcoming control command has an explicit decision to
  make about whether it may block.

Two bugs found by running rather than assuming: raw transcripts came back full of
`<|startoftranscript|>` markers because that stripping is off by default; and the
first concurrency test was blind — three simultaneous jobs returned correct text
even with the lock disabled, so "the results agree" could not observe the bug at
all. The invariant is now counted and asserted instead.

Not user-visible yet: there is no command to call this. That is the next step.

## 2026-07-27 — One home for "where DAW Pro keeps things on disk", and an autosave bug that was never going to announce itself

The rule for `~/Library/Application Support/DAWPro/<Category>/` was open-coded in
**nine places across six files in three modules**. It now lives once, in
`DAWCore/AppDirectories.swift`, behind a `Category` enum whose raw value *is* the
on-disk directory name — so renaming a case can no longer orphan a user's files.

**The refactor was the excuse; this was the actual find.**
`ProjectStore.defaultAutosaveDirectory()` and `AutosaveManager.defaultDirectory()`
each computed `DAWPro/Autosave` independently. The manager *writes* the rolling
autosave there; the store *scans* that directory for recovery bundles. Nothing
made them agree — they simply happened to. Had either drifted, autosaves would
have been written faithfully and never offered back, and the failure would have
surfaced only to someone who had already lost work.

They now agree by construction: one producer, the other delegates. A test pins
the equality.

Worth stating plainly, because it is the argument for having done this at all:
when that delegation is deliberately broken, **the new test is the only thing in
the suite that notices**. Fifty tests across eight suites ran against the broken
version and every pre-existing autosave and recovery test stayed green.

Also preserved deliberately: the fallback expression
`systemBase ?? URL(…).appendingPathComponent("Library/Application Support")` binds
as `first ?? (home + "Library/Application Support")`, because member access binds
tighter than `??`. A well-meant parenthesis would silently make the fallback the
bare home directory. That behaviour is unchanged and now has its own test.

Not covered, on purpose: the scratch paths under `NSTemporaryDirectory()/DAWPro`
and the sidecar logs under `~/Library/Logs/DAWPro` are a different rule with a
different lifetime — purgeable rather than durable user data — and folding them in
would let a change to one silently move the other.

## 2026-07-27 — Speech-model weights move out of the repo, and the app learns where to look

The 1.5 GB of Whisper weights no longer live in the working tree. They now sit in
`~/Library/Application Support/DAWPro/Models/`, beside `SoundBanks/`, `Autosave/`
and `VoiceDatasets/` — the same place the rest of the app already keeps large
user-managed assets.

**The app no longer has one place to look; it has an ordered list.**
`WhisperModelCatalog` walks candidates highest-priority first and takes the first
that actually *holds* a usable model:

1. `DAWPRO_WHISPER_MODELS_DIR` — wins outright when set, even if empty, so
   pointing the knob somewhere deliberate yields that place's teaching error
   instead of quietly resolving elsewhere.
2. `~/Library/Application Support/DAWPro/Models` — user-installed weights.
3. `<App>.app/Contents/Resources/Models` — a copy sealed into the bundle.
4. `<repo>/Models` — the dev walk-up, anchored on `Package.swift`.

Application Support deliberately outranks the bundle: it means a small model can
ship inside the app and still be upgraded to large-v3-turbo by dropping the
bigger one in, with no reinstall. The rule is "first **stocked**", not "first that
exists" — otherwise an empty Application Support folder would shadow a perfectly
good bundled copy.

**Packaging is now a choice, defaulting to slim.** `scripts/bundle.sh` ships a
small app and expects the weights to be installed separately;
`./scripts/bundle.sh --with-weights` instead seals them in for a self-contained,
offline-capable bundle — the right call behind a restrictive proxy, at the cost of
re-shipping and re-notarizing ~1.5 GB on every update. The copy happens before
`codesign`, so the weights land inside the seal rather than breaking it.

Not user-visible yet: nothing transcribes. This is the plumbing that decides where
a model comes from, ahead of the capability that uses one.

No shipped behaviour today — this is a design cycle, and the tree's audio path is untouched.

**m23-r (per-insert spectrum tap) is designed and split into r1 → r2 → r3 → r4**
(`docs/research/design-m23r-per-insert-spectrum-tap.md`), superseding
`design-m22b-eq-curve-editor.md` §4.3.

The headline correction: **the FFT does not have to run on the render thread, and it
must not.** The old design assumed that because the tap *point* is on the render thread,
the *analysis* had to be too — and then spent its cost argument on that premise. Only the
sample capture is render-side. The tap becomes two bounded `memcpy`s into a preallocated
lock-free ring; the FFT, band fold and ballistics run on the consumer inside an
**unmodified `MasterMixAnalyzer`**. Track and master spectra are then comparable because
they are literally the same implementation, not because two band tables agree.

Two further corrections, both found by reading the current code rather than the old doc:

- The tap hook belongs in the **chain walk loop**, not in `processActive` — a steadily
  bypassed unit calls `processActive` not at all, and a crossfading one calls it *before*
  its equal-power mix. The old anchor was not merely stale, it was the wrong host.
- **The gate this item was going to be judged by could not see the change it was
  guarding.** The cited EQ null pin builds an `EQEffect` directly and never touches the
  chain walk. Replaced with the real chain-walk pin plus an armed-vs-disarmed
  byte-identity discriminator.

Also filed: **m23-n (WhisperKit transcription) is split into n1 → n2 → n3 and BLOCKED on a
user decision.** The dependency door was measured and the 0-warn build gate survives it
unchanged; what is outstanding is consent, not information. See ROADMAP `## Blocked`.

## 2026-07-27 — Export your stems, and a mastered mix beside them

**REBUILD REQUIRED** — this lives in the source tree only; the copy in `dist/` predates it.

The Export sheet now starts with a choice: **SONG** or **STEMS**. Song is exactly what you had — one file, the whole mix. Stems writes one file per part into a folder you pick, which is what you send to a mixing engineer, a collaborator, or a mastering house.

Two extras ride along with stems, both optional. **A reference mix** — the same sum as your stems, so whoever receives them can check their rebuild against it. And **a mastered mix**, which is the real deliverable with your master chain and loudness target applied. They're independent; take either, both, or neither.

**The card tells you exactly which files you're about to get**, by name, and updates as you change your mind. That list is worth reading, because stems don't map one-to-one onto your track list: **a bus is a stem, and a track routed into a bus is not.** Route a guitar into a reverb bus and you won't see a guitar stem — its sound is inside the reverb bus's file, which is the only way the bus's own effects stay correct. The card says so, and the numbering closes up rather than leaving a gap.

Your depth and container choices apply to both modes, so a 24-bit AIFF song and 24-bit AIFF stems come from the same two controls. And if nothing in your project can produce a stem, the export button stays off rather than handing you an empty folder.

## 2026-07-27 — Save one track's MIDI straight from the track header

**REBUILD REQUIRED** — this lives in the source tree only; the copy in `dist/` predates it.

Right-click any instrument track's header and there's now an **Export MIDI…** item. It writes just that track out as a `.mid` file — the part you're looking at, not the whole arrangement. File → Export MIDI… still writes the whole project; this is the one-track version, and it lives on the track because that's the only place the app knows which track you mean.

The item only appears on instrument tracks. Audio and bus tracks don't have notes to write, so rather than offer you something that would refuse, we don't offer it — the same way "Bounce in Place" hides where it can't work.

Two things worth knowing. **An instrument track you haven't played into yet will still export**, giving you a valid MIDI file with no notes in it — that's a real file, not an error, and it's occasionally what you want as a starting point. And if the file can't be written where you pointed it, **you'll get told**: this is the first action in the track menu that reports a failure rather than quietly doing nothing.

Nothing about the whole-project export changed, and no existing file you export will come out any different.

## 2026-07-27 — An export window: pick your file type and quality before you save

**REBUILD REQUIRED** — this lives in the source tree only; the copy in `dist/` predates it.

The EXPORT button used to go straight to a save box and give you a 32-bit float WAV, every time, with no say in it. Yesterday's release made bit depth and file type choosable, but only an assistant could reach them. Now you can.

EXPORT (or ⌘E) opens a window first:

- **Quality** — 32-bit float (what the app works in), 16-bit (CD quality, smallest files), 24-bit (the usual depth for delivering a mix), or 32-bit integer. WAV or AIFF.
- **Leave tracks out** — untick a track and it's gone from the file. This is how you get an instrumental, and **your project is not changed** — nothing is left muted afterwards, and there's no edit to undo. A track that leaves takes its reverb and delay tails with it, so the result is genuinely clean rather than a vocal-shaped hole full of the vocal's ambience.
- **Match a loudness target** — off by default. Turn it on to land the mix near a chosen LUFS with a peak ceiling, the way streaming services expect.

Three things worth knowing rather than discovering. **The window remembers your choices for the rest of the session** — pick 16-bit AIFF once and the next export is 16-bit AIFF too, and the filename it suggests changes to match; it goes back to 32-bit float WAV when you next open the app. **The name it offers already carries the right extension**, because the extension is what actually decides the file type — take the name it gives you rather than retyping one. And **no loudness number is shown anywhere in this window, deliberately**: the figures we can measure describe the mix *before* it is converted to 16 or 24 bit, so a number beside a 16-bit choice would be describing a different file than the one you're about to get. Rather than print a caveat next to a misleading figure, we print neither. If your mix peaks above 0 it will still be clipped on the way to an integer file — turn on the loudness target, or stay on 32-bit float.

Nothing about the old behaviour changed underneath: open the window, touch nothing, export, and you get exactly the file yesterday's build would have written.

## 2026-07-27 — Choosing the file type and quality you export at (and a silent bug fixed)

**REBUILD REQUIRED** — this lives in the source tree only; the copy in `dist/` predates it.

Until now every export came out as a 32-bit float WAV, with no say in the matter. That is the right *working* format — it is lossless and it keeps peaks that go above 0 — but it is not what most people want to hand over. Bouncing, mixing down and exporting stems now each take two optional choices:

- **Bit depth** — 16 (CD, small files), 24 (the normal delivery depth for mixes and stems), or 32. Leave it alone and you get today's 32-bit float exactly as before.
- **File type** — WAV or AIFF. AIFF is written in the AIFF-C form macOS produces; every DAW reads it.

Two things worth knowing rather than discovering later. **The file extension is what actually decides the file type**, so if you ask for AIFF the name you get back may differ from the name you sent — always use the path the app reports. And **integer depths clip at full scale where 32-bit float does not**, while the loudness numbers in the response describe the audio *before* it is converted — so a mix peaking above 0 will be clipped on the way to disk without the report mentioning it. Normalize first, or stay on the default. Conversion is honest but undithered in this version, and the response says so rather than claiming otherwise.

**A silent bug, now fixed.** An export to a path ending in `.WAV` or `.Wav` — any capitalization other than all-lowercase — wrote a **CoreAudio Format** file with a `.WAV` name on it. No error, no warning; it would simply refuse to open properly elsewhere. This was verified against the last committed build, so it is not new breakage. Such a path is now corrected to `.wav` and you get a real WAV file. The one consequence: the path reported back to you may be spelled slightly differently than the one you gave.

## 2026-07-27 — Handing your song to someone else: a mastered mix beside your stems, and an instrumental

**REBUILD REQUIRED** — this lives in the source tree only; the copy in `dist/` predates it.

Two things you can now ask for when exporting.

- **A mastered mix delivered alongside your separate tracks.** Exporting stems already gave you one file per track plus a plain reference mix. You can now also ask for **"00 Mastered Mix.wav"** — your song with the master chain and master fades actually applied, the same way the mastered bounce makes it. It arrives *next to* the stems rather than printed onto each one, and that is deliberate: when your master chain squeezes or saturates the mix, printing it onto every track separately does **not** add back up to the mix you approved. Logic, REAPER and Studio One all hand it over the same way. Your separate tracks stay clean and still sum back to the reference mix (measured null, not a promise of bit-identical arithmetic), so whoever receives them can rebuild your balance and hear your master.
- **An instrumental, without touching your project.** Bouncing or mixing down now takes a list of tracks to leave out — mute the vocal by hand and you get the same file, but this way your project is not edited, nothing is left muted if the render fails, and there is no dirty document to explain. Worth knowing what leaves with an excluded track: **its reverb tail goes too**, and so does its effect on anything keyed off it (a compressor ducking under the vocal stops ducking). That is what makes an instrumental genuinely clean, and it also means this cannot give you "instrumental but keep the vocal's reverb" — that would be a different feature.

## 2026-07-27 — Planning note: what a complete export set should look like (no app changes)

**Nothing changed in the app in this entry** — this was a research step, and it is recorded here only so the decisions behind the next one are not invisible. We looked at how Logic Pro, Ableton Live, REAPER and Studio One structure exporting, and wrote down what DAW Pro should offer: your song as a `.mid` file (done — see below), separate files per track, a mastered mix, an instrumental with the vocal taken out, and the choice of file type and quality that every other program gives you.

Two things worth knowing from it. **You can already make an instrumental today** — mute the vocal, bounce, unmute — so what we owe you is a single button that does it without touching your project, not the ability itself. And **"mastered stems" is a trap in the obvious form**: printing the master chain onto each track separately does not add back up to your mastered mix, which is why we will ship the mastered mix *alongside* the separate tracks rather than baked into each one, as Logic, REAPER and Studio One all do. One question that would have surfaced as a bug got settled while checking the research: muting a track also removes its reverb tail from a shared reverb, so an instrumental will genuinely leave the vocal's ambience behind rather than half of it.

## 2026-07-27 — MIDI files: open them, save them, drag them in

**This is the one you'll be able to use once the app is rebuilt** — everything below lives in the source tree only; the copy in `dist/` predates all of it. **REBUILD REQUIRED.** DAW Pro now reads and writes `.mid` files — the format every other music program speaks. Drag one onto the timeline and it becomes tracks and clips at the spot you dropped it; hand your song to someone using Logic, Ableton or anything else with File → Export MIDI…. It took five steps to get here and the account of all five is below, newest capability last.

- [x] **Reading the format.** DAW Pro can now make sense of a Standard MIDI File's bytes: notes and how hard they were played, tempo and time-signature changes, mod wheel, pitch bend and aftertouch, and both of the layouts `.mid` files come in — one track per part, or everything on a single track that has to be pulled apart by channel. Broken files say what's wrong instead of looking empty: a truncated or corrupt file gives a clear error naming the problem, rather than the quiet failure where a damaged file opens as though it simply contained no music.
- [x] **Writing the format.** DAW Pro can now produce a Standard MIDI File as well as read one — notes with their velocities and how hard they were released, tempo and time-signature changes, mod wheel, pitch bend and aftertouch, in either of the two layouts (`.mid` files that keep each part on its own track, or the single-track layout that packs everything together). macOS's own MIDI reader opens what we write and gets back the music we meant. Where the format simply cannot express something — a note played at zero force, which in a `.mid` file means "stop the note" rather than "play it quietly", and would make the note vanish from a file that still opened fine — DAW Pro refuses and says so, instead of writing a file that looks healthy and is silently wrong. At the time this landed it was the engine and not the button; the button is the last step below.
- [x] **Importing one into your project.** A `.mid` file now becomes tracks and clips in your song: one track per part, each with its notes, their velocities, and the mod wheel, pitch bend and aftertouch that went with them. A file that packs several instruments onto one track is pulled apart into one track each, so a piano and a bass never end up sharing a fader — or overwriting each other's mod wheel. What happens to your tempo is a choice you make: by default the file sets the grid only when your song is still empty, so your first import establishes the tempo and a later one never silently moves everything you have already recorded; you can also say "always take the file's tempo" or "never touch mine". Either way **the notes land on exactly the same beats** — a `.mid` file measures time in beats, not seconds, so its tempo governs how fast it plays and never where the notes sit. The whole import is one undo. Anything the file asks for that DAW Pro cannot represent is reported rather than quietly dropped — an impossible tempo, a time-signature change that lands mid-bar, more controller lanes than a clip can hold, per-note aftertouch — so you always know what you did and did not get. At the time this landed you needed an assistant to trigger it; the last step below is the part you reach yourself.
- [x] **Handing your song to another program.** DAW Pro can now write your project out as a `.mid` file — the whole song, or one track on its own. Every instrument track becomes a part with its notes, velocities and controller moves, your tempo and time-signature changes ride along at the front of the file, and drum tracks land on the channel every MIDI player treats as drums. Audio tracks are left out and *named*, so "where did my vocal go" has an answer in the report instead of a mystery. What you get is what you *wrote*, not what you currently hear: a muted track is still in the file, and so is a note that runs past the end of its clip — export saves your work, it does not mix it down. macOS's own MIDI reader opens what we write and reads back the notes and tempo we meant. Anything the format cannot hold exactly is reported before it happens (run it as a rehearsal first and nothing is written): a note nudged off the grid by a fraction of a millisecond, two notes of the same pitch that overlap, a clip's fades and gain, a tempo the file's own units can't name to the last decimal. **One honest gap, said out loud rather than buried:** the file does not yet tell the receiving program *which* General MIDI instrument each track wants, so it will use its own default sounds; the instrument each track asks for is listed in the report, and making it land in the file is the next small step. At the time this landed it was reachable only by an assistant; the last step below is the part you reach yourself.
- [x] **The ways you actually reach it.** Drag a `.mid` from Finder straight onto the timeline and it imports where you dropped it — on the beat the drop line showed you, not near it. Snapping applies, so a file dropped roughly at bar 3 starts exactly at bar 3. The File menu has **Import MIDI…** and **Export MIDI…** alongside the audio entries. You can drop a `.mid` and a `.wav` together and both land on the same beat.
  - **A `.mid` used to be accepted and then quietly ignored.** macOS classifies MIDI files as audio, so the timeline and the ⌘I panel already took them — and then the import, which only understands real audio, dropped them with a note you never saw. Dragging a `.mid` in looked like it worked and did nothing. That is what this step actually fixed, and it is why ⌘I no longer offers `.mid` files: Import MIDI… is where they belong.
  - **The timeline stops promising a landing it won't honour.** Dragging a single audio file over an existing audio track highlights that track, because that is where the file will go. A `.mid` never lands on an audio track, so it no longer lights one up — the drop line still shows you the beat.
  - **Two things worth knowing.** A `.mid` dropped into an *empty* project sets your tempo from the file, the same rule imports have always used; drop it into a project that already has clips and your tempo is left alone. And a mixed audio-plus-MIDI drop is **two** undo steps, not one — press undo twice to take back the whole gesture.
  - **Still missing, and worth saying:** a `.mid` that fails to import from a *drag* does not raise an alert — the two File-menu entries do. And exported files still don't name which General MIDI instrument each track wants, so another program opens them on its own default sounds.

## 2026-07-26 — Drag your tracks into the order you want

- **Tracks reorder vertically.** Grab a track's header in the arrange page and drag it up or down; the list parts to open the slot you're aiming at, and a line marks the edge the track will land against. Until now track order was fixed at creation — the order you happened to add things in was the order you were stuck with.
- **The preview is the result, not an impression of it.** The rows that slide out of your way move by exactly the distance the committed reorder will move them, so what you see mid-drag is where things end up.
- **It's one undo.** A reorder is a single step in the history, labelled with the track's name, and undoing it restores the exact previous order. Dropping a track back where it started does nothing at all — no stray entry in your undo history.
- **Nothing about your mix changes.** Sends, output routing, automation and clips all follow their track, because they were never bound to its position. Reordering is purely visual; it cannot alter what you hear.
- **Agents can reorder too.** New `track.reorder` control command and `track_reorder` MCP tool, so an assistant can tidy a session's track order the same way you can.

- **And now the mixer's strips drag too.** Grab a strip by its name and slide it along the rack; the console parts to open the slot, and a line marks where it lands. There is only ONE track order in the project, so a strip you move in the mixer moves in the arrange page as well — the two views never disagree about what order your tracks are in.
- **The mixer draws channels first, buses after the divider** — and a strip you drag stays in its own group.
- **Because there's only one track order, moving a strip in the mixer can shift where a bus sits in the arrange list.** That's deliberate: both views read the same order, so they can never disagree about it. If you'd rather buses held their place, say so and we'll make the mixer refuse those drops.
- **A drop that wouldn't change what you can see does nothing at all** — no line while you drag, no entry in your undo history.

## 2026-07-26 — Drag a box around clips to select them

- **The timeline has a rubber band.** Drag across empty space in the arrange page and a translucent cyan box follows your pointer; every clip it touches is selected when you let go. This is the piece the multi-select release said was still missing: shift-clicking six clips one at a time works, but drawing a box around them is what you actually reach for. Hold shift while you drag and the box *adds* to what you already had.
- **It selects what the box touches, and it gives clips back when you shrink it.** Sweep too far, pull back, and the clips you overshot are released again — the box re-decides from the selection you started with, rather than accumulating everything it has ever crossed.
- **A drag with no width or height selects nothing.** That sounds like a triviality and it is not: without it, a click that wobbled by a pixel would silently replace your whole selection with whichever clip happened to be under the pointer.
- **The bug this could most easily have shipped with, and did not.** Rows in the timeline are *not* evenly spaced — a track with its automation lane open is 64 points taller than its neighbours. Work out which track a box covers by dividing by the row height and you get the right answer in every project that has nothing expanded, and the wrong track in every project that does. The box asks the timeline where each row actually is instead, and the code that does the maths is physically incapable of dividing by a row height: it is only ever handed the real positions. We proved the test can see the difference by computing both answers and confirming they disagree before checking which one the app gives.
- **Clicking to move the playhead, and double-clicking to start a new part, both still work.** They share the same surface as the new drag, and the way they are layered together was chosen deliberately once before to keep clicks feeling instant. The most interesting check reproduces the exact sequence that broke a similar feature two releases ago: click empty space (which moves the playhead to that point), then start dragging a box from that same point. A "safety check" that seemed sensible would refuse the box there, and would have passed every other check in the file.
- **Selecting is not opening.** Boxing a single clip does not fling the note editor open, even though clicking that clip would. A box has no one clip you pointed at, so choosing one for you would open an editor on a clip you never clicked — and since the box updates as you drag, the editor would flicker from clip to clip as it swept.
- Verified against a running app: **38 checks**, plus **two picture-based ones** confirming the box is genuinely drawn on screen and genuinely gone afterwards — the window with a box standing looks different from the window at rest, and returns to it pixel for pixel on release. Six deliberately broken builds were each caught by the right check. Suites: Swift 3578/378 zero warnings, agent-server 212/212. **No new commands and no new agent tools.**
- **Three things we learned the hard way and are recording rather than glossing.** A check that *skips itself* when conditions are awkward is a check that passes — the picture checks originally stepped aside on an unlucky frame, and the very first broken build we tried sailed through with the box never drawn at all; they now fail instead of skipping. Restoring a file is not restoring the program built from it, which cost a confusing round of debugging when a "clean" run was quietly testing the previous broken build. And the system's own rectangle type silently tidies up backwards drags, so an entire set of checks about dragging right-to-left passed against code that did no tidying at all; that guarantee is now checked where it can actually be seen.
- **Not claimed:** these checks drive the app's own handlers, because macOS gives no way to synthesise a real mouse drag or a real click from outside. They prove the handlers are correct and reachable; a human with a mouse still has to confirm that clicking and double-clicking feel unchanged now that a drag shares the surface. **Not included:** selecting whole *tracks* by boxing their headers is separate work and is not part of this.

## 2026-07-26 — Drag a selection and the spacing between clips survives

- **Selecting several clips and dragging one now moves all of them**, which is the piece the last release said was missing. Grab any clip in the selection and the whole group travels together, across as many tracks as you have selected.
- **The spacing between them is preserved exactly, and that is the entire point of the feature.** The obvious way to build this quietly destroys your arrangement: if each clip snapped to the grid on its own, a clip on the beat and a clip half a bar later would both land on the *same* beat — welded together, one of them eaten by the other. So snapping is treated as a property of the *drag*, not of each clip: the clip under your pointer snaps, once, and everything else moves by exactly that much. We proved this the hard way, by building the broken version too and keeping it in the test suite forever, where it demonstrates on every run that clips at beats 0 and 2.5 collapse onto beat 4 and one of them is cut from two beats down to half a beat.
- **Dragging a group into the start of the song no longer scrambles it.** When the leftmost clip reaches the beginning, the whole group stops there together. Previously, the rule that stops a *single* clip at the start would have stopped only that one clip while the rest kept going — so a shove to the left would silently squash your spacing. The trade we chose, deliberately: in that one case the clip you grabbed can end up off the grid. Keeping your spacing intact matters more, and the timeline's readout tells you where the clip actually landed rather than where you asked for it to go.
- **A data-loss bug that this feature could easily have shipped with, prevented by design.** Select two clips far apart on the same track — say bar 1 and bar 9 — and drag them. The straightforward implementation treats "bar 1 through bar 9" as one span and clears everything inside it, which would have deleted a clip sitting at bar 5 that neither of your clips ever touched. Each moving clip now only claims the space it genuinely lands on. There is a check that reconstructs the wrong version and confirms the innocent clip is destroyed by it, so this cannot quietly regress.
- **A whole drag is one undo.** Moving three clips and pressing ⌘Z puts all three back, along with anything they trimmed on the way. Dragging a *single* clip reads in the Edit menu exactly as it always did.
- **Grabbing a clip that is not selected selects it first and moves only it.** Otherwise a selection you had forgotten about would come along for the ride.
- Verified against a running app: **38 checks** reading positions from the project itself rather than the app's own report of them, plus **six deliberately broken builds** — per-clip clamping, the one-big-span version, a non-incremental drag, a missing undo key, split-up undo, and unsorted processing — each confirmed to fail the checks that are supposed to catch it. The last of those initially passed everything, which is how we found that the ordering only matters for crossfaded clips; a test for that case now exists. Suites: Swift 3553/377 zero warnings, agent-server 212/212. **No new commands and no new agent tools** — agents could already move clips one at a time; group moves on that surface are filed as separate work.
- **Not claimed:** these checks drive the app's drag handler directly, because macOS gives no way to synthesize a real mouse drag from outside — a human still has to confirm the pointer feel. **Still missing:** dragging clips *up and down* between tracks does not exist yet, for one clip or for many, and this change does not add it. Arrow-key nudging is the next piece. **One rough edge we did not smooth:** if a clip is already sitting off the grid and you nudge the group by a hair, the clip you grabbed snaps onto the nearest grid line and everything moves with it — your spacing survives, but the group shifts slightly more than you asked. That is how dragging a single clip has always behaved.

## 2026-07-26 — Select several clips at once, and delete them as one undo

- **The arrange page finally has multi-select.** Shift-click or ⌘-click clips to build up a selection across as many tracks as you like, and click a selected clip again to drop it back out. Until now only the note editor could select more than one thing, so on the main timeline you could act on exactly one clip at a time.
- **Deleting a selection is ONE undo step, not one per clip.** Delete three clips and a single ⌘Z brings back all three, with their notes, at their original positions. This is the whole point of the feature and it is the thing we tested hardest: we deliberately rebuilt it the naive way — a loop that deletes clips one at a time — and confirmed our checks caught it, reporting three undo steps where there should be one. Worth knowing *why* that matters: under that broken version, checks like "the clips are gone" and "one undo looks right" **still passed**. Only counting the actual undo history told the truth.
- **A bug we introduced, found, and fixed before shipping — and it is worth being plain about it.** The first version listened for the Delete key too broadly, so this could happen: select some clips, then open a panel such as Quantize, then press Delete. The clips were destroyed behind the panel you were looking at, in one silent edit. We measured it doing exactly that. Delete is now refused whenever a panel is open, whenever you are not on the arrange page, and whenever you are typing in a name field — and we verified the refusal by proving the same key press *does* delete when no panel is open, so it is a real guard and not a dead code path.
- **Your rename fields got their focus rings back.** Fixing the above also removed a stray setting that had been suppressing the focus outline on every rename box, Copilot input and Settings control in the app.
- **Renaming a clip still can't delete it.** Delete is a plain key press on the timeline rather than a menu shortcut, on purpose: menu shortcuts are handled *before* text input, which would have made Backspace destroy clips while you were editing a name.
- Known limits, stated rather than glossed: **deleting is currently the only thing a multi-selection does** — selecting three clips and dragging still moves only the one you grabbed, because group dragging is the next piece of work. Shift and ⌘ both mean "toggle this clip" for now; proper range-select needs the rubber band, which comes after that. And closing the note editor clears a whole multi-selection, not just the clip you were editing.

## 2026-07-26 — Dropped audio lands where you aimed, and the line goes away

- **The stranded line is gone, and we found out what it actually was before touching it.** It was the cyan drop indicator — the guide that shows where a dragged file will land. It is armed by the system's drag messages and cleared by them too, so when one of those messages never arrived, the guide simply stayed: a full-height glowing line you could not click, drag, or delete, because it was never a real object in your song. It was identified by measuring it, not by guessing: 224 pixels tall, which is the exact full height of the lane area and more than twice what a stray clip could have been.
- **The fix does not depend on knowing which message the system dropped** — we could not determine that, and we are not going to pretend otherwise. Instead there are three independent layers, and the important one is this: **your next ordinary mouse move over the timeline clears any leftover guide.** Even if the system misbehaves in a way we have never seen, you are one mouse movement away from a clean screen. It cannot cancel a guide during a real drag, because that check only runs when no mouse button is held.
- **Dropped files now magnetise to the places you actually aim for** — the very start of the song, and the start and end edges of clips already on that track. Those edges are often *off* the grid (a clip you trimmed by ear, a generated part with an odd length), which is exactly why the grid alone was not enough. The pull has a small, fixed radius on screen, so it feels the same at every zoom and can never drag your drop across a whole beat at normal zoom. **If you have turned snapping off, nothing magnetises** — off means off.
- **The guide and the drop can no longer disagree.** Before, the line you saw and the beat the file landed on were worked out twice, in two different places, and matched because they happened to use the same inputs. Magnetism would have broken that, because the timeline knows where clip edges are and the import machinery does not. Now one piece of code decides the landing beat, once, and the answer is carried through to the file — the second calculation does not exist any more. This was not just tidied and hoped for: we re-broke it on purpose to check, and found that with the old two-calculation design, one snap setting still agreed by coincidence while the rest fell apart. That is precisely the kind of bug that hides for months.
- **A second, unrelated way to get an unremovable mark was found and fixed on the way.** An audio file with no sound in it at all imported as a clip of exactly zero length — a sliver you could not grab or delete. It now lands at the same minimum length anything else can be trimmed to.
- Verified against a running app: **29 independent checks** on top of the 24 the change shipped with, reading where clips actually landed from the project itself rather than trusting the app's own report of it. Drops were confirmed landing exactly where the guide promised at four different snap settings, and the magnets were tested against a deliberately off-grid edge so that a version which quietly fell back to the plain grid would fail. Both check suites were also run against **deliberately broken builds** to confirm they can still fail. Suites: Swift 3496/373 zero warnings, npm 212/212; **no new commands and no new agent tools.**
- **Two things are not proven and are not claimed:** that macOS delivers its drag messages in the order tested here, and that a real drag from Finder is correctly detected as "button held" inside this app. Both need a human with a real file and a real drag. Dragging **several** files at once is unchanged for now — it is waiting on multi-selection, which is the next piece of work.

## 2026-07-26 — Double-click an empty lane to start writing notes

- Adding a track used to leave you nowhere to go. The note editor only ever opened on a clip you already had, and a brand-new track has none — so the only ways to start writing were to ask an agent or to know a command. **Double-click any empty spot on an instrument track** and a clip appears there, with the note editor open on it and the grid ready.
- It starts **where you double-clicked**, not at the beginning of the song, and it snaps to the same grid a single click already seeks to — so the clip's start and the playhead land on the same beat whichever of the two clicks the system decides to honour. That is by design rather than by luck: both read the same one piece of arithmetic.
- The clip is **one bar long**, and one bar means one bar of the meter actually in force at that spot — seven beats in a 7/8 section, not a fixed four. If there is already a clip to the right, the new one stops where that one starts instead of running over it. That is not tidiness: writing over a neighbour would have quietly trimmed the notes already living there, from nothing more than a double-click on empty space.
- **Double-clicking a track that cannot hold notes says so.** An audio or bus lane answers with the same sentence the app gives an agent for the same request, in an amber note right where you clicked — never a click that simply does nothing, which is the complaint this whole item exists to fix, one surface over.
- One undo removes the clip and leaves the track. Double-clicking an existing clip still splits it, exactly as before.
- A flaw in the app's own **self-checking** machinery was found and fixed alongside this, and it is the kind worth naming. The channel automated checks use to ask "what happened?" was answering one question late — it reported the result of the *previous* request instead of the one being made. That does not usually break a check; it does something worse. Because the stale answer is a real answer from a real earlier action, a check can read it and **pass on the wrong evidence**. It now waits — briefly, and with a hard stop — for the screen to actually catch up before it answers, so the request that causes a change is the one that reports it.
- Verified against a running app: 38 checks including the clip landing on the double-clicked beat at two different zoom levels, the editor opening on **that** clip rather than merely being open, the audio-lane refusal reading identically to the wire's answer, the neighbouring clip keeping its note, a 7/8 section yielding a seven-beat clip, and a sweep down the height of a lane confirming that the hover hint and the double-click always agree about which track you are on. **One thing is not proven and should not be claimed:** these checks drive the app's own double-click handler directly, so they cannot show that a real two-click sequence reaches it on a surface whose single click already moves the playhead — a human has to close that. Suites: Swift 3468/372 zero warnings, npm 212/212; **no new commands and no new agent tools** — the app already knew how to make a clip, the screen just had no way to ask.

## 2026-07-26 — You can hear the note you are dragging

- Drag a note up or down in the note editor and you now **hear the pitch** as it moves, on that track's own instrument. Click a key in the piano keyboard down the left edge and it sounds too; slide up the keys and it glissandos. Nothing is written, nothing is recorded — it is a preview, and the note goes quiet the moment you let go.
- It works with the transport **stopped**, which is the case that matters when you are editing, and it works **while the song is playing** without touching a single note of the playback. That is not a promise made in prose: audition reaches the instrument on its own path, with its own bookkeeping, and its own answer to congestion — if audition ever floods, only the audition notes are cut, never what the song is playing. The alternative, which would have been one line shorter to write, silences the whole track.
- **A held note cannot get stuck**, and the reason is worth stating plainly. Every 500 ms the app tells the audio engine "yes, still holding this." The audio side gives it three seconds; if that reassurance stops arriving — the app froze, crashed, was suspended — the note is released from inside the audio engine itself, with no app involvement required. A key you are genuinely holding down is never cut short, because the reassurance arrives six times over in every window.
- Two notes of the same pitch from two places used to be the classic way this feature ships a bug: press C on a MIDI keyboard, drag a note onto C, release the drag, then release the key — and one of the two voices sustains forever. Audition and your hardware keyboard keep entirely separate books here, so each release ends the note it actually belongs to. There is a test that fails on purpose if they are ever merged.
- Agents can audition too: one new command, `note.audition`, sounds up to eight pitches for a set duration and releases them itself. If the track is muted or its plugin is still loading it says so in the answer — `audible: false` with a reason — instead of failing or pretending.
- If you would rather edit in silence, there is a switch; it is on by default, and it stays how you leave it. The agent command deliberately ignores it, because "don't make noise while I drag" is not the same instruction as "never make sound."
- **A take starts silent.** Starting a recording while a note is held now releases it. Refusing to start *new* auditions during a take was never enough on its own: a note already sounding would have carried straight through the recording, re-asserted every 500 ms, audible to you and invisible to the recorder — heard and not captured, which is exactly the lie the refusal exists to prevent.
- One design defect was found and fixed during the build rather than after it: the safety-release path could write past the end of its own event buffer when the song was dense enough — a real memory fault on the audio thread. It was reproduced with a failing test first, then closed, and the design note was corrected.
- A second defect was caught in verification, before this ever reached a build you could run, and it is the one that mattered: with the transport stopped the note **spoke for an instant instead of being held**, and then spoke a second time when it was released. The cause was a single shortcut deep in the audio engine — when a track has nothing scheduled and nothing new arrives, it skips the instrument entirely and writes silence, which is right for an idle track and wrong for one holding a note you have your finger on. The instrument is now kept running while anything is held, and for long enough afterwards that a note's natural fade-out is never chopped off mid-tail.
- Verified as **sound**, not as a successful reply — and the checks were rebuilt after the miss above, because the original ones could not have caught it. It is not enough to ask "did it make a noise" and "did it stop": a note that sounds for a fraction of a second passes both. So the test now asks whether the level stays **flat for the whole time the note is held**, and whether the note **starts exactly once**. Against a real running app with the transport stopped: the master bus rises from a −80 dB floor to −6.8 dB and holds within **2.6 dB across the middle of a three-second note**, with **exactly one** onset, then releases to the floor. While the song played, the audition added 7.5 dB on top of the running mix, the playing notes never dropped below −14.4 dB underneath it, and after the audition released the mix returned to within **0.8 dB** of exactly where it had been — the measurement that shows an audition ending does not disturb the song. Both new checks were confirmed to fail on the broken version before being trusted on the fixed one. Suites: Swift 3456/371, npm 212/212; commands 152 → 153, MCP tools 155 → 156.

## 2026-07-26 — The view can follow the playhead now

- Press play and the arrangement used to sit still while the music left the screen. There is now a **FOLLOW** switch in the arrange toolbar: with it on, the timeline and the note editor both keep the playhead in view for as long as the transport is rolling. It is off until you ask for it, and it stays however you left it — including after a restart.
- It turns pages rather than gliding. The view holds still while the playhead crosses it, and when the playhead nears the right edge the whole view jumps forward one screen and drops it back in a little way from the left, so you can still see the bar it just played. That was not a taste call: both behaviours were built and driven through the same eight bars of the same session, and the gliding one asked the view to re-lay itself out **262** times where paging asked **4**, taking the app's main thread from 15 ms to 49 ms per round trip. Forty-nine milliseconds is longer than the gap between two playhead updates — the smooth-looking option was the one that could not keep up.
- **If you scroll while it is following, it stops following and says so.** The switch changes to an unfilled outline: still armed, not currently driving. Nothing fights your mouse, nothing snaps back a third of a second after you let go. Press play again, or click the switch, and it picks the playhead back up. Scrolling the note editor stands down the note editor only — the arrangement keeps following.
- The note editor follows on all three of its bands at once, so the notes, the velocity lane and the controller lane never disagree about where you are. Following moves the view sideways and only sideways: the pitch range you scrolled to stays exactly where you put it.
- Verified under real playback rather than by jumping the transport around: eight samples of each surface across half a minute of rolling, with the playhead measured in the actual pixels of each band, plus the switch turned off through identical playback to confirm the view stays put, plus the preference surviving a genuine relaunch of the app. Suites: Swift 3402/365, fully green, npm 207/207, zero new commands.

## 2026-07-26 — The note editor tells you where the playhead went

- "The playhead doesn't move" was the report. It moves — but only while the transport is inside the clip you happen to have open, and outside that span the editor drew nothing at all. Open a clip at bar 5, hit play from the top, and for the first eight seconds the note editor sat perfectly still. That silence was deliberate once: a playhead is a claim about where the transport *is*, so rather than park a line at the edge and lie about it, the editor said nothing. Honest, and completely unhelpful.
- Now the absence is annotated instead of silent. When the transport is outside the clip, the edge it lies beyond carries a soft cyan wash and a small readout — `◀ 3.5 BARS`, then `◀ 2.9 BEATS` as it closes in. It brightens as the transport approaches, so the editor visibly moves the whole way in and you can see the music coming before it arrives.
- The distinction that made this safe to add: the old rule forbids a *playhead* parked at an edge, and it still does — the line's behavior is untouched. What is new is not a playhead. It is pinned to the window rather than the timeline, so it stays put when you scroll, which is something a real playhead can never do; it is never a hairline, never wears the playhead's glow, and it states a direction and a distance rather than a position. It also never rounds down to "0" — a zero distance would read as "at the edge," which is exactly the claim it exists to avoid making.
- The line and the marker are driven by the same single test, so exactly one of them is ever on screen and the hand-off at the clip's edge is exact — no flicker, no moment where both draw. Both the note grid and the velocity lane get the marker, because a playhead that spans both bands and a marker that doesn't would leave the two disagreeing about where the transport is.
- Verified on the actual complaint: real playback into a clip at bar 5, sampling the off-clip stretch that used to be pixel-for-pixel frozen — every frame now differs. Suites: Swift 3383/364, npm 207/207, zero new commands.

## 2026-07-26 — The piano roll has actual piano keys now

- The keyboard down the left of the note editor was reported as reading "gray," and it was: both key colors were dark. The white keys were a dark slate barely distinguishable from the black ones, so the column that is supposed to tell you at a glance which row is which pitch told you almost nothing. White keys are now a real ivory, and the alternation reads instantly — it looks like a piano, because it is one.
- Turning the keys light meant everything drawn *on* them had to change too, and that is most of the work here. The app's chrome is built for dark backgrounds: its separator lines, octave rules and label text are all pale, and pale-on-ivory is invisible — measured, they landed between 1.0:1 and 2.2:1, which is to say gone. So the gutter became the app's one light surface with its own set of inks, each measured against the ivory: octave labels went from 4.1:1 to **10.1:1** and read identically at every octave from C-1 to C9, and the line between two neighbouring white keys — the only thing that makes the E|F and B|C pairs read as two keys rather than one tall one — is now a real key gap instead of a whisper.
- Middle C is still marked, but neutrally: a bold label over a short dark anchor bar at the key's edge, instead of the cyan it used to wear. Cyan means active transport in this app — it is the playhead in this very view — and spending it on a landmark that never moves was borrowing meaning the color needs elsewhere. On ivory it measured 1.07:1 and would have been invisible regardless.
- The note grid itself is deliberately **unchanged**. It stays dark so note blocks keep popping against it; its lane alternation was measured as already above the threshold where the eye separates two tones, and note contrast doesn't vary between lanes. Lightening it would have bought nothing and cost legibility. Suites: Swift 3378/364, npm 207/207, zero new commands.

## 2026-07-26 — Mixer strips stop eating themselves: the fader is always there, and there's a knob now too
- A user report — "in the Mix tab, when it adds inserts and other instruments or effects it eclipses the volume scales" — turned out to be worse than it read. A channel strip's fader carried a hard minimum height, and a hard minimum is something the strip hands up to the whole console; the console has no vertical scroll, so once a track collected a full effect chain the mixer started demanding more height than the window had. At a 760 pt window it pushed the app's own header row and the transport bar clean off the screen; at 640 it also cut the dB readout and the Mute/Solo/Arm buttons away entirely, with no way to reach them. Fixed properly rather than nudged: a strip now reserves its fader region — the knobs, the fader, its meter, the dB number and the Mute/Solo/Arm row — as space that **never** yields, and the effects chain above it becomes the one part that gives way, hugging its content while it fits and scrolling inside its own bounds when it doesn't. Whatever you stack on a track, the volume controls stay put, and the window's chrome stays on the window.
- Two things arrived with the fix. The INSERTS heading grew a **fold arrow** and a count, so you can tuck an eight-effect chain out of the way for a round of manual fader work and still see that it's eight effects long (the setting sticks across relaunches, and starts expanded so nothing disappears on you). And every strip grew a round **volume knob** beside the pan knob — the same level the fader sets, in a control that always fits, for exactly the moment the report described. It is deliberately in *both* Simple and Pro: volume is the most beginner-primary control on a strip, and hiding the compact one in Simple would remove it precisely where a newcomer benefits most. It wears the app's volume cyan (pan stays neutral white — pan has no meaning-color), sweeps from silence with a tick at unity so it can never disagree with the fader about where "0 dB" is, and shares one gain-to-angle calculation with everything else in the mixer. Making room for it, the pan number moved up beside its own label (`PAN L64`) instead of sitting on a line of its own — a strip's vertical space is contested, and that one line was the difference between a full effect chain fitting at the default window and its OUTPUT row being cut in half.
- The master strip needed a different answer and got one: its anatomy — chain, automation, fader, loudness, stereo image, reference row — genuinely cannot fit the smallest window the app allows, so it now scrolls internally instead of clipping, and stretches back out to fill whenever there's room, so at ordinary window sizes it looks exactly as it did. Nothing on it is unreachable any more. Pure view work throughout: **zero** new commands and zero new AI tools, verified byte-for-byte. Proven with staging captures across three window heights, both densities, and four chain lengths — every one checked for the bottom-most control actually being present, not merely for the fader being visible. Suites: Swift 3378/364, npm 207/207.

## 2026-07-26 — The reference track gets its face: A/B on the strip, the whole comparison in one panel
- The reference-track workflow is now something you can *see and press*, not just something an agent can drive. Load a finished song you trust and the master strip grows a compact REFERENCE row — the record's name, a MIX | REF chip pair, and the level-match number — that appears only when a reference is loaded and shows in both Simple and Pro, because "does my mix hold up against that record?" is a beginner question. Press REF and the mix mutes while the reference plays, turned up or down to sit at *your mix's* measured loudness, so the comparison isn't won by whichever is simply louder. That is also the app's core teaching moment here, and the in-app help says it out loud: the reference can sound quieter than it does on a streaming service, and that is deliberate.
- Clicking the row opens the REFERENCE panel: the file and its length, the A/B cluster with a plain-language line explaining exactly what the match is based on (your mix's loudness, or a standard streaming level when nothing has played yet, or an amber "turned down to protect your speakers" when a full match would have clipped), timing OFFSET and TRIM steppers, a two-curve spectrum — the reference's whole-song average in plain white under your mix's live curve in glowing cyan, on one shared frequency scale — and a row of differences (loudness, peak, range, width, phase) with a beginner sentence under it: "Your mix is 3.4 loudness units quieter than the reference." Where the mix has no evidence yet, the numbers read a dash rather than a fabricated zero, and the mix curve really is a rolling average, exactly as its label claims.
- Design discipline held throughout: **no violet anywhere** — a reference is a record you chose, not AI-generated material — the panel adds **zero new commands** (every button routes to the same store method the `reference.*` wire verbs call, so a reference imported by hand and one imported by an agent are byte-identical), and the meters use the always-ticking poll pattern rather than the one that freezes when the app isn't frontmost. The in-app copilot learned the workflow as a curated four tools (catalog 61 → 65) with the other four verbs taught inside their descriptions, so "compare my mix to the reference" is now a first-class AI move. Pixel review caught and fixed three real layout defects before landing (an empty panel padded out with dead glass, the missing-file banner pushing the caption past the card edge, and frequency labels sitting off their own gridlines — a label that doesn't point at its line lies about where the energy is). Verified on a live app: a real WAV imported and analyzed over the wire, the level match matching the law exactly, the deltas reproducing reference-minus-mix to the last digit, and two captures three seconds apart proving the panel keeps repainting while the app sits in the background. Suites: Swift 3367/363, npm 207/207. With this, the reference-track workflow (m22-g) is complete.
- One more defect fell out of independent pixel review after that: on the master strip, a wide level-match number (`+11.4 dB`, ordinary when the reference you're chasing is a quiet demo) squeezed the MIX | REF chip beside it down to an unreadable `M… | R…`, while a narrower `-5.8 dB` left it intact. The row had room the whole time — the layout was splitting its width rather than running out of it — so both the chip and the number now hold their own size instead of competing, and the reference's name stays the one thing in the row allowed to shorten. Confirmed at every value the level match can physically produce, right out to ±24 dB, in both the strip and the panel.

## 2026-07-26 — Opus 5 lands: the copilot can pick the new flagship
- Anthropic shipped Claude Opus 5, and the in-app AI copilot's model picker now offers it: `claude-opus-5` joins the curated catalog as the flagship-reasoning row (128K output ceiling, adaptive thinking with summaries visible in the transcript, same as its siblings), with Opus 4.8 and 4.7 renamed to "previous" and "older" flagship rather than dropped — anyone who already selected one keeps it instead of being silently reset to the default. Fable 5 stays offered above it as the highest-capability tier, and Sonnet 5 remains the balanced default nobody has to think about. Additive throughout: no new commands, no new MCP tools, both existing `ai_copilot_*_model` tools surface the new row automatically. Suites: Swift 3338/362, npm 207/207.
- The request-shaping side needed no change, which is the point of keeping one table: `AnthropicModelCatalog` already routes per-model max-tokens and thinking config from a single array, so Opus 5 was one row plus its pins. Also refreshed the development-side routing table in the project constitution to match the agent definitions — the whole design-and-implementation fleet (architect, DSP, app, UI) now runs on Opus 5 at half Fable 5's price, with the narrow test-gated lanes staying on Sonnet 5 and docs on Haiku 4.5 — plus the model-selection notes in the AI-integrations doc.

## 2026-07-20 — The delay learns musical time: tempo-synced divisions
- The built-in delay now thinks in note values, not just milliseconds: flip SYNC on and pick from 18 divisions — 1/1 through 1/32, each in straight, dotted, and triplet flavors — and the effective delay time derives from the project tempo (a 1/8 dotted at 120 BPM is exactly 375 ms). Change the tempo and every synced delay retunes automatically; bounces resolve the same math at the render's start tempo, so live and offline can't disagree. The free-run milliseconds value is preserved untouched underneath — switch sync off and you're exactly where you left it, and old projects load byte-identical.
- The seams are engineered honestly: all tempo math lives in one tested DAWCore home (the delay's real-time code is byte-untouched — the control plane substitutes the derived time, so the render thread never does tempo lookups), sloppy numeric division values snap to the nearest musical division rather than pretending precision, and sync/division deliberately refuse automation lanes instead of shipping lanes that couldn't work. Agents get the full vocabulary through the existing params path — no new commands — with the exact formula and snapping rules taught in the effect's self-description. Proof in the suite: impulse echoes measured at exactly the predicted sample positions across two tempos, live and through a full offline bounce. Suites: Swift 3277/354, npm 207/207.

## 2026-07-20 — Dynamics stop mixing blind: gain-reduction metering everywhere it matters
- Every built-in compressor, limiter, and gate now shows how hard it's working, live: the wire snapshot carries a per-effect `gainReductionDb` (positive dB, instant attack with a 20 dB/s held-peak release — the same ballistics convention as the level meters), published real-time-safe from the render thread as a single atomic store. It's additive on the effect entries agents already read — zero new commands — and honest to the bone: non-dynamics effects and hosted AUs simply omit the key (never a fabricated 0), bypassing re-zeros it, and a fully closed gate reads the engine's exact 80 dB cap. The suite pins the math: 8.88 dB measured against 9 expected on a 4:1 overshoot fixture, release slope exactly 20.0 dB/s.
- In the app, dynamics editor cards grow a GAIN REDUCTION ladder — 24 glowing segments on a saturating scale that gives the musical 1–6 dB region most of the travel (ticks at 0/3/6/12/24; deeper readings pin the bar while the number stays honest), zone-colored green/amber/red on compressors and limiters ("you're crushing it" is a teaching signal) but uniformly green on a gate, whose deep attenuation is its job — a closed gate says CLOSED in plain language, never an alarming "80.0". Insert chips get a five-cell mini activity bar so you can see which insert is working without opening anything. En route, pixel review caught the new meters freezing solid whenever the app wasn't the focused application (a DAW's meters must keep moving while you work elsewhere — and an AI-driven app must stay observable); the polls now use the loudness readout's proven always-ticking pattern, re-proven live in captures: a card reading 35.7 dB mid-playback with the ladder pinned. Suites: Swift 3258/352, npm 207/207; wire and MCP surface counts unchanged.

## 2026-07-20 — The mix gets eyes for stereo: correlation, width, and a real goniometer
- The master analyzer is stereo-aware at last: `mixer.masterAnalysis` now reports L/R correlation (−1…+1 with broadcast-meter 300 ms ballistics), stereo width, and left/right balance — honestly floored (+1/0/0) in silence, with a deliberate convention that a hard-panned mix reads "in phase" because mono-summing it cancels nothing, which is the question the meter answers. AI agents get taught the red flags in the MCP tool description, so "will this collapse to mono?" is now a measurable copilot question. The existing spectral analysis is byte-untouched.
- On the master strip, a STEREO IMAGE block joins the loudness readout: a glowing goniometer (mono = vertical line, anti-phase = horizontal, hard-left rides the L diagonal like the hardware scopes do), a plain-language verdict — IN PHASE / VERY WIDE / OUT OF PHASE — with one semantic color across trail, word, and bar, plus width/balance numerics in Pro. Simple mode keeps the beginner-relevant verdict and drops the pro instrument. Deterministic debug seeding makes every figure capturable headlessly. Verified end-to-end: suites 3240/350 Swift + 206/206 npm, an 11-check wire gate through real panned playback, a 15-check capture gate, and pixel-reviewed figures for mono, anti-phase, hard-pan, window-floor Simple, and live audio.

## 2026-07-20 — The master bus gets a real loudness meter, live
- The DAW now measures loudness the way broadcast and streaming platforms do, *while you play*: the master strip carries a live BS.1770 meter — momentary and short-term LUFS, the running gated integrated value, loudness range (LRA, new to the app and also added to offline measurement), and 4×-oversampled true peak, with DC-offset and crest-factor riders for diagnosis. It behaves like a hardware meter left running: stopping the transport never erases the running program, only an explicit reset starts a new measurement, and values honestly disappear (dashes, not zeros) until enough audio has been analyzed to mean anything — including a floor that keeps a fading synth tail's floating-point dust from ever masquerading as a reading.
- Trust is the feature: the streaming engine reuses the exact same math as the offline `render.measureLoudness` truth, and the suite holds live-vs-offline identical to within a billionth of a dB (true peak bit-exact) on the same program. AI agents get the same eyes — a new `mixer.liveLoudness` wire command and `mixer_live_loudness` MCP tool (granted to the plugin's mix engineer; the finisher deliberately keeps verifying its work against offline renders). Verified end-to-end on a live app: a real playback round converged with the offline measurement of the same project, stop/start accumulation and reset semantics held over the wire, and the on-strip readout tracked the wire values in a reviewed capture. En route, a test-build-only performance collapse that could wedge the full test suite was root-caused and fixed (hot loops rewritten; the whole suite runs in ~65 s again). Suites: Swift 3213/348, npm 202/202.

## 2026-07-20 — The EQ gets its face: the interactive frequency-curve editor
- The EQ is now shaped the way Logic and Pro-Q users expect: a log-frequency plot with a glowing composite curve, six draggable band handles (drag for frequency and gain, ⌥-drag or scroll for width, ⇧ for fine moves, double-click to switch a band off), a band strip with ON toggles and 12/24 slope chips, and — on the master strip — the live spectrum breathing behind the curve at its true band positions. The Simple density is the curve; Pro flips back to the full knob table. Track EQs honestly draw no spectrum yet (the per-insert analysis tap is a filed follow-up rather than a render-thread cost smuggled in).
- The curve provably cannot lie: the biquad coefficient math was extracted into one shared DAWCore unit consumed by both the audio engine and the drawn curve, the pre-existing bit-exactness pin still fingerprints the DSP identical to the pre-change engine, and a new test renders sines through the real EQ and holds the drawn curve to within four millionths of a dB of what the DSP actually does. Verified live over the wire: probe points matched textbook filter identities (−3.01 dB at a high-pass corner, exact gain at a peak's center), and undo steps stay per-parameter. No new wire/MCP surface — the editor is a new face on the already-agent-controllable EQ. Suites: Swift 3186/344, npm 196/196.
- Drop a finished song into the timeline and the AI can now *measure* it instead of guessing: the new `clip.analyzeAudio` command (and `clip_analyze_audio` MCP tool) reads an audio clip's musical key (with ranked alternatives and an honest `tonal: false` for percussion-only material), its tempo (nullable when no steady pulse exists, with a `steady` flag and half/double-time alternates, plus the offset of the first beat), and its spectral balance (24 analysis bands, six plain-language macro bands like "bass" and "air", and a brightness centroid). Confidence fields everywhere are margin-gated and deliberately never fake certainty — a null BPM is an answer, not a failure. Stretched or pitched clips also report a derived `playback` block for what the clip sounds like *now*, and results are cached so repeat calls are instant.
- The in-app copilot and the music-team plugin's composer and arranger were all taught that analysis is the first move on imported audio — proven live: asked about an imported song, the copilot called the analysis tool unprompted and reported the measured key and BPM (A minor, 120, steady) instead of guessing. Accuracy was pinned against fixtures before shipping: 7/7 known-key pieces exact, click-track tempo within ±0.05 BPM, a 60 BPM pulse honestly folded to 120 with 60 offered as the alternate, and pink noise correctly reporting "no tempo". Analyzing five minutes of audio takes ~1.2 s. With this, the instrument-control-depth milestone (M21) closes. Suites: Swift 3150/341, npm 196/196.
- The built-in EQ gains the most-used tools in mixing that it simply didn't have: high-pass and low-pass filters with selectable 12 or 24 dB/oct slopes, adjustable Q on both shelves, and a true per-band on/off switch (bypassing a band is mathematically identical to the band not existing — not a gain trick). The editor grew matching controls: filter knobs, 12/24 slope chips, and band ON toggles, and `fx.describe` now teaches AI agents the new parameters' exact semantics, including that a filter with no corner set is off.
- Compatibility is engineered, not hoped for: every new field is optional, old projects decode to byte-identical settings, and a regression test pins the new DSP against an exact replica of the old math — verified bit-equal against the actual pre-change build before the change shipped. Measured proof in the suite: a 100 Hz high-pass attenuates 50 Hz by 12.3/24.1 dB on its two slopes, corners sit at −3.01 dB, and a fully-bypassed EQ nulls to literal zero. Suites: Swift 3111/338, npm 191/191. Next up on this surface: the interactive frequency-curve editor.
- The arrange grid learned finer trim divisions (1/8- and 1/16-beat, matching the engine's real precision) — and more usefully, clips can now snap themselves to their material: "Fit to Content" (right-click a clip, or the new `clip.fitToContent` command/tool for AI agents) trims a MIDI clip to exactly its last note's end and an audio clip to its remaining source length, tempo- and stretch-aware. It's honest about edge cases: a clip that already fits reports `changed: false` and writes no undo entry, an empty clip is a safe no-op, and a note hanging past the clip edge pulls the clip *out* to cover it — fit means "match the content," not "shrink". Simple mode keeps its beginner-safe Bar snapping untouched.
- The whole convention shipped in one stroke: store operation with undo, wire command, MCP tool, copilot catalog entry, context-menu affordance, and the distributable music-team plugin's arranger now carries the tool. Verified live over the wire: an 8-beat clip with notes ending at beat 2.37 fit to exactly 2.37. Suites: Swift 3096/336, npm 191/191.

## 2026-07-20 — The tour gets its art — and the glass-cockpit pass closes
- The guided tour's welcome and done cards now open with real artwork: a dark console under a hovering cyan waveform greets first-run users, and a glass turntable whose groove is a glowing waveform ring closes the loop when their first song is saved. Both images are GPT-generated in the house design language, shipped as neatly inset media wells (the five task coach-marks deliberately stay art-free — art belongs where the app frames a moment, not where it teaches a control). A deliberate engineering choice underneath: the images load through a resilient custom loader that works identically in dev runs and the signed app bundle, and degrades to a text-only card rather than ever crashing over a missing file.
- This closes the full glass-cockpit pass — compliance audit, app icon, asset scoping (verdict: the app needs almost no generated art, which is the design language doing its job), and these two heroes — and with it, the entire Design & simplicity milestone (M8).

## 2026-07-20 — Third-party plugins open up: the AU parameter surface
- Until today, a hosted plugin was a black box to the AI — it could load Dexed or Surge onto a track but couldn't read or turn a single knob, and it would honestly tell you so. Now two new wire commands ask any hosted Audio Unit for its full parameter tree (`au.describeParams` — every parameter's name, unit, range, and current value, paged honestly for synths that expose thousands) and set any parameter by address (`au.setParam` — out-of-range values clamp, and the response echoes the value the plugin actually accepted, since some quantize what you send). Plugins that keep their state opaque (Kontakt-style) get an honest "publishes no parameter tree" answer pointing you at the plugin's own window, never a fake error. Matching MCP tools ship to AI agents, and the distributable music-team plugin's sound-designer and mix-engineer both carry them.
- Proven against real plugins, not mocks: Apple's AUDelay enumerated its true 4-parameter tree over the wire, a delay-time set moved the actual echo in a rendered impulse (the test listens, not just reads), and DLSMusicDevice proved the instrument flavor. Suites: Swift 3066/333, npm 188/188, all green. The in-app copilot was taught the surface the same day (catalog 56 → 58) and proved it in a live turn: asked to read an AUDelay's delay time and set it to half a second, it called both new commands and the plugin's own read-back confirmed 0.5 s — the "no access to plugin values" era is over for the built-in copilot too.

## 2026-07-20 — The note editor grows up: zoom, finer grids, and honest limits
- The piano roll finally zooms: pinch on the grid, ⌘+/⌘−/⌘0, or the new magnifier cluster in the editor header (4–200 pt per beat, remembered per app like the arrange timeline's zoom, which it deliberately mirrors). Grid divisions now go past 1/16 — 1/32, 1/64, and triplet feels (1/8T, 1/16T) — with sub-beat grid lines that fade in as you zoom so a fine grid never turns into visual soup at normal zoom, and quantize learned the same divisions.
- Two honesty fixes: a note can now be dragged as short as one grid step (previously the editor refused to go below the snap's default note length even though the engine happily stores far shorter — AI-written ornaments were viewable but not editable), and the delete-bar button no longer plays dead — when a part is only one bar long, pressing it explains why it's disabled in a small amber notice instead of silently ignoring you. Verified live: a 1/64-note edit accepted over the staging wire, a bar deleted from an 8-beat part, and a pixel capture of the roll at 500% showing 1/64 notes as real, editable dots. Suites: Swift 3078/334.

## 2026-07-20 — The Poly Synth gets a face: a real editor panel for the built-in instrument
- The built-in Poly Synth's sound has always been tunable — but only by the AI over the wire, which is exactly backwards for an instrument you play. Now the instrument picker grows a TUNE button (visible whenever Poly Synth is the track's current instrument) that opens a dedicated dark-glass editor card: OSC (a segmented wave picker — saw, square, triangle, sine), ENVELOPE (attack/decay/sustain/release knobs), FILTER (log-taper cutoff and resonance), OUTPUT (gain reading in dB). The same knobs the insert editors use — option-drag for fine control, double-click to reset — with honest readouts that cross ms→s and Hz→kHz where your eyes expect it.
- The panel and the AI edit the same instrument and see each other live: turn a knob and the wire's next read reflects it; let the copilot set the cutoff mid-session and the open card's knob moves. A knob drag coalesces into a single undo step. No new wire commands or MCP tools — the UI converged on the surface that already existed (`track.setInstrument`). Proven by a 14-check live gate on a staging app plus a pixel capture of the rendered card; suites grew to Swift 3042/331, still zero warnings.

## 2026-07-19 — Conversations that survive: copilot chats now live inside the project file
- Chats persist. Every copilot conversation is now stored inside the project file itself — save the project, quit, reopen it next week, and your chats are there: listable, renameable, resumable, continuable. The rail gained a quiet history view (CHATS) showing every archived conversation with its title and age; the reset button now honestly means "new chat" (it archives, never destroys); resuming is always an explicit act — reopening a project never silently reconnects a conversation to the API. A four-agent build from a settled architecture design (docs/research/design-copilot-chat-persistence.md): domain persistence, engine lifecycle, four new wire commands (ai.copilotChats/ResumeChat/DeleteChat/RenameChat, wire 135→139) with four matching MCP tools (138→142), and the rail UI.
- The honesty engineering is the story. Old project files open unchanged, and one corrupt chat can never fail a project open (per-element lossy decode). Chats ride autosave and crash recovery without ever touching the undo stack, and Cmd-Q now runs a real autosave. Caps keep project files sane — 20 chats, 400 entries / 256 KiB per chat — and when trimming happens the transcript says so in a banner instead of pretending nothing was lost; a single over-long turn is preserved whole rather than half-shown. Thinking blocks are stripped from stored provider history (they're only load-bearing mid-tool-loop, and stripping makes resume safe across model switches) while the readable summaries stay in the visible transcript. Feedback bundles exclude chats entirely — your conversations are yours. The design pass also caught and fixed two latent bugs: a reset() racing an in-flight turn could pollute fresh state through the error paths, and an all-thinking reply used to leave an empty assistant message in history that would have 400'd the next send.
- Proven end-to-end, not just unit-tested: a staging app held a real conversation (it built an ambient pad track named Nebula), saved the project, was killed outright and relaunched; the reopened project listed the chat, resumed it with the full transcript, and when asked — with tools forbidden — "what was the track called?", the model answered "Nebula" from the restored history. 17/17 gate checks. Suites: Swift 3021/330, npm 177/177.

## 2026-07-19 — Thirty rounds, a copy button, knobs where knobs belong — and an icon
- DAW Pro finally has a face: a GPT-Image-generated app icon in the house design language — near-black glass squircle, a neon waveform sweeping violet to cyan, one amber fader — with true alpha transparency (verified at the pixel level, not eyeballed). The committed `AppIcon.icns` carries every size from 16 px to 1024 px, `bundle.sh` seals it into the signed bundle, and `dist/DAWPro.app` now looks like an app instead of a generic terminal binary. This is the first fruit of the newly unblocked GPT-Image pipeline; the broader generated-asset scoping (onboarding art, empty states) remains open by design.
- The copilot's per-turn tool budget default rose from 8 to 30 rounds (the 1–32 policy range and the Settings override are unchanged, and the Settings placeholder now derives from the constant so it can never silently drift). Real compositions routinely batch instruments, clips, effects, and mix moves across many rounds — 8 was cutting legitimate work short with the honest-but-annoying "tool-round limit reached" message.
- AI output is now copyable: hover any assistant message (or an expanded reasoning strip) for a quiet copy glyph — cyan on hover, a green checkmark for a moment once copied — and the rail header gained a copy-whole-reply action that joins the latest reply's prose with blank lines, never tool traffic or collapsed thinking. The clipboard is touched through one seam, tests use a fake, and a whitespace-only copy refuses to blank your clipboard.
- The insert-effect editor was rebuilt as a vertical channel strip with real rotary knobs, guided by a same-day research pass over Logic, Ableton, FabFilter, UAD, and hardware-lineage conventions (docs/research/2026-07-19-knob-vs-slider-insert-controls.md): grouped sections per effect (compressor TRIGGER / TIME / OUTPUT; four EQ band groups; output and mix always last), label-above-knob columns, bipolar center-out arcs for EQ gains and saturator output, log frequency sweeps, mix amounts reading as percentages, gain reading in dB-equivalent, delay times crossing over to seconds — and delay's Ping Pong, secretly binary all along, is finally a real toggle. Threshold and ceiling stay knobs for now by explicit decision: the slider-beside-a-meter treatment waits for per-effect gain-reduction metering. The m17-a insert-editor gate still passes untouched, 22/22. Suites: Swift 2928/327, npm 165/165.

## 2026-07-19 — The copilot thinks out loud, streams live, and lets you pick its brain
- Four user-requested upgrades landed in one wave. The copilot no longer caps its own output: each turn requests the model's full maximum (128K tokens on Claude Sonnet 5) and rides Server-Sent-Events streaming, so long reasoning, long answers, and big tool batches can never be truncated by our own budget or killed by a fixed request timeout. The model's reasoning is now visible: requests opt into summarized thinking, and the transcript shows quiet, collapsed "REASONED" strips — expandable to the full summary, with a breathing violet dot and a live tail-preview while the model is actively thinking. And the model itself is now yours to choose: a MODEL chip in the copilot rail opens a curated picker (Sonnet 5 default, Opus 4.7/4.8, Sonnet 4.6, Fable 5, Haiku 4.5), persisted across launches, applied from the next message — with matching `ai.copilotGetModel`/`ai.copilotSetModel` wire commands and MCP tools, so agents get the same control (wire 133→135, MCP tools 136→138). One catalog drives everything — per-model token ceilings, thinking configs, and the picker — so they can never drift apart.
- Live verification earned its keep twice. A first staging-app gate proved the wire: model round-trips, teaching errors for unknown ids, real summarized reasoning arriving in transcript entries. But polling at 100ms during a streamed 2000-character answer caught ZERO in-progress entries — streaming was secretly buffered: the whole network response was collected before events fired, making "live" a burst of microseconds. The fix made the SSE assembler a true incremental consumer, with a regression test that proves the first delta's event fires before the rest of the stream even arrives. The re-run: 118 mid-stream observations of the growing answer and the model's thinking, clean finalization, nothing left dangling. Suites: Swift 2915/327, npm 165/165.
- The DAW also became a place other Claudes can work: a distributable Claude Code plugin (`claude-plugin/`, installable via marketplace or `--plugin-dir`) ships a six-agent music team — producer, composer, arranger, sound-designer, mix-engineer, finisher — each least-privilege-scoped over the 136 MCP tools (a verified disjoint partition), plus workflow skills (`/new-song`, `/arrange`, `/mix-check`, `/bounce`, `/daw-status`) and a shared wire-lore reference. The MCP server is bundled into the plugin as a single 1.7 MB self-contained file (ESM, `import.meta.url` intact), smoke-tested over a real MCP handshake serving all 136 tools — no build step for end users, no sibling-directory dependency, both strict validators green.

## 2026-07-19 — The copilot finds its voice back (user-reported "(no response)" fixed)
- The in-app copilot had gone silent: every ask ended with a bare "(no response)" and nothing else. The cause was three defects stacked so neatly that each hid the next. Claude Sonnet 5 runs adaptive thinking by default when a request doesn't say otherwise — and thinking spends the same `max_tokens` budget as the visible answer. At the old 4096-token budget, a complex ask could burn the whole allowance on internal reasoning; the provider then threw those thinking blocks away as noise, the engine saw an "empty" reply, and printed "(no response)" while discarding the one clue that told the truth (`stop_reason: max_tokens`). The fix: the turn budget rises to 16000 tokens, thinking blocks are preserved verbatim and echoed back on later rounds exactly as the API requires (which also fixes a latent bug that would have broken multi-round tool turns), and a reply with no visible output now produces an honest, actionable failure naming its stop reason — the string "(no response)" no longer exists in the codebase.
- Fixing the silence uncovered a fourth defect the old truncation had been masking: with a real 16000-token budget, a genuine generation outlives the HTTP layer's default 60-second timeout. Copilot turns now ride a 600-second request timeout (all other AI clients untouched), with the constant pinned by tests so it can't silently drift back. Verified the honest way — a staging app on the staging port replayed the user's exact failing prompt against the live Anthropic API: eight minutes, 43 successful tool calls, a full EDM arrangement with tracks, instruments, MIDI, markers, a mix chain, and a −17 LUFS loudness report at the end. Suites: Swift 2867/323, npm 159/159, all green. (+11 tests over baseline.)

## 2026-07-19 — The Voice panel arrives, honest to a fault
- Voice conversion now has a home in the app: a right-docked Voice panel (VOICE chip in the top bar) where you create named voices, build their training datasets — import audio files, or record on a track as usual and add the clip as a sample — and see the conversion engine's real state with a one-press Start. Audio clips gained "Convert to Voice…": pick a voice, optionally shift pitch, and the converted take lands as a violet AI track aligned under its source, one undo away. A matching `vc_list_voices` agent tool ships too, so everything the panel shows is equally visible to AI agents.
- What makes this release notable is what it refuses to fake. The only voice available today is plainly badged "PIPELINE TEST — proves the pipeline works, not a real voice conversion," and the result card repeats that in amber after every convert. Pressing Train sends a real request and shows the engine's own answer — "real training arrives with a coming update," with your validated request echoed back — instead of a progress bar to nowhere. The rights policy is written into the panel itself: train and convert only with your own voice, never a celebrity's, never anyone's without permission. Real voices arrive with the training update, which needs the one thing that can't be automated: the user's own recordings.

## 2026-07-19 — An agent can now convert a vocal and land it in the project, one command each
- The voice-conversion pipeline is drivable end-to-end: `vc.convertVocals` takes a vocal (either a clip already in the project or an audio file on disk), runs it through the local conversion engine, and lands the result as a new violet AI-flagged track in the arrangement — one command, one undoable edit, and redo brings it back exactly where it was. Point it at a clip and the converted take lands at that clip's own position automatically. The command blocks until done rather than pretending to be a background job — conversion runs at ~37× real time, so even long stems finish in seconds, and every timeout budget along the chain (app-side, agent-side) was sized so a legitimately long conversion is never cut off mid-run.
- Honesty is enforced at every layer: converting through the placeholder "base" voice plainly reports it isn't a real voice conversion yet; a wrong pitch value or an attempt to train over the reserved name surfaces the engine's own teaching error word-for-word; calling convert with the sidecar stopped tells you exactly which command starts it instead of a bare "connection refused"; and `vc.trainVoice` ships fully wired but honestly answers "training arrives with the Voice panel" until the real training path lands. Independent review attacked eight corner cases the build's own tests didn't cover (MIDI clips, conflicting inputs, redo, cross-sidecar isolation) — all held. One latent test bug from the previous item was also caught and fixed: the command-sweep test had been silently booting the real sidecar on every full test run, and would have failed the suite on a fresh checkout.

## 2026-07-17 — The app learns to drive its second sidecar
- The voice-conversion service installed yesterday can now be driven from inside the app — and by AI agents — through three new control commands: check the sidecar's status, start it, stop it. The status answer never shrugs: it always tells you the precise next step ("run the installer" vs. "call start"), reports which engine is loaded and how many trained voices exist (honestly zero until training ships), and if a boot is slow it says "starting, N seconds so far" truthfully instead of pretending success — the same honesty discipline the music-generation sidecar learned the hard way, applied here from day one. The existing generation-sidecar commands are byte-untouched: this is a second, independent service, and a deliberate test proved the two report their own states without cross-talk even when one is running and the other isn't.
- Under the hood the app gained a typed client speaking the service's full contract (list voices, voice status, convert, train — the last two get their commands next), and the whole surface landed with the house convention intact: every command has a matching AI-agent tool (each carrying the own-voice-only policy in its description) and tests at every layer — 43 new app-side tests plus 9 agent-side, with live verification twice over: the builder's end-to-end run caught the sidecar mid-boot on the wire, and an independent review pass attacked the corners (stopping an already-stopped sidecar, starting twice, feeding junk parameters) and found them all handled. Start-to-healthy measures about half a second.

## 2026-07-17 — The voice-conversion engine gets a permanent home
- Hours after the feasibility verdict came back GO, the engine moved from a throwaway test directory into the repo for real: an installer that sets up the whole stack — pinned engine version, isolated Python environment, the four model files (reused from cache with checksums verified), the security-mandated weight-format conversion, and the GPU-format model conversions — in 57 seconds flat, and knows to do nothing in 0.04 seconds when everything's already in place. A launcher starts the conversion service on a local-only port (loopback is hardcoded, not configurable — the service is unreachable from the network by construction), with the same lifecycle conventions as the existing music-generation sidecar.
- The service speaks a small, stable four-endpoint contract designed so the rest of the app never needs to know which engine sits behind it: list voices, check a voice's status, convert audio, train a voice. Conversion is real today (proven end-to-end twice — once in the build, once in independent review with a different input file, at 37× real time warm); the voice list is honestly empty (no bundled voices, no celebrity models — ever); and training answers with a polite "reserved: this arrives with the Voice panel," validating your request fully so the same call will just work when it does. Next: the app-side client and control-surface commands that let agents drive it.

## 2026-07-17 — Voice conversion goes from "blocked" to "GO" in one afternoon
- Six days ago the voice-conversion feasibility spike hit a wall: the corporate network hard-blocked every neural model download, leaving the engine verdict incomplete. Today a routine re-probe found the wall gone — and within the hour, all four required model files (~775 MB) were downloaded, checksummed, and cached durably. The missing measurements followed on this machine: the full conversion pipeline runs at 38× real time end-to-end, pitch extraction at 95×, content encoding at 574×, and — the number that matters most for the "train your own voice" promise — a real training step runs natively on Apple's GPU at 3.2 steps per second with zero CPU fallbacks. Verdict, written into the spike report: GO.
- The guardrails held throughout: no celebrity voice models were downloaded or touched (the pipeline was proven against a neutral untrained target — real voices arrive only when a user trains their own), the test vocal was synthesized from scratch rather than borrowed, and the one unresolved item is properly legal, not technical: the conversion engine's repository still ships no license file, which stays a shipping gate. One fresh discovery was banked for the install step: newer security rules in the ML toolchain refuse the old model format, so the installer will convert weights to the safe format up front. Next up: the install scripts and the local sidecar service that will host voice conversion for the app.

## 2026-07-17 — The test that could never pass, fixed by the numbers
- The generation-card test gate had two dormant bugs in its own checks — caught and filed two cycles ago when a header cleanup exposed them: one leg called a command that doesn't exist (a naming slip: `app.captureUI` for the real `debug.captureUI`), and one compared a number against the clock text "0:33", a comparison that can never be true. Both are fixed — the elapsed check now parses the clock string properly (the card deliberately reports elapsed time as display text, and that stays; the test adapts to reality rather than the other way around) — and the gate's header honestly records that these were always test bugs, never app bugs.
- The gate now passes all twelve checks from a cold start, twice over: once in the fixing session and once in an independent re-run, both against a real staged app, including the leg that boots a real local AI sidecar and watches the interface narrate the startup. With this, the current milestone's runnable work is complete — the remaining three items all wait on one hardware decision (installing a loopback audio device) that only a human can make.

## 2026-07-17 — The last measured freeze is gone, and it cost nothing
- Two cycles ago, measurement convicted the gain-adjustment step of loudness-targeted bounces: over a second of frozen main thread on a 2.7-minute song. Today it moved off the main thread — fused with the loudness re-measure that follows it, so the whole adjustment is one background unit instead of two round-trips. The subtle trap was memory: done naively, handing a render buffer to a background task duplicates it (hundreds of megabytes for long programs) at the moment of the first change. The implementation threads the buffer's single ownership through the hop instead — no copy, and a test pins that the audio data literally never moves in memory, byte-addresses compared.
- Proof, before and after, on the same 2.7-minute program: the app's responsiveness probe caught the old code freezing for 1.07 seconds mid-bounce; the new code's worst hiccup is 9 milliseconds, with the bounce itself no slower. The independent review then ran its own gate with a different recipe: two consecutive normalized bounces came back byte-for-byte identical (the change is deterministic end-to-end), the output landed at exactly the requested loudness, and 208 responsiveness probes never waited more than 14 milliseconds. The suite stands at 2,743 tests across 307 suites, zero warnings. With this, every heavyweight stage of a bounce runs off the main thread — the one remaining on-thread step measures ~20 milliseconds, and it stays by the numbers.

## 2026-07-17 — Sampled instruments stop running out of breath: sustain loops are real
- Until today, importing a sample library whose sounds are built to loop (nearly every sustained instrument — strings, pads, organs, brass) played each note only as long as its raw recording, then went silent; the import report could only apologize. Now loops play for real: the loop points authored in SFZ and DecentSampler files are honored, and when a library's text says nothing, the loop embedded inside the WAV file itself (the standard `smpl` chunk that most sampled instruments carry) is found and used automatically. Held notes sustain indefinitely, the sustain pedal behaves like a real instrument's — loops keep sounding under the pedal and release naturally when it lifts — and the loop seam is crossfaded at render time so it's mathematically quieter than the sine wave's own natural motion: measurably invisible. The import report's apology is gone, replaced by an honest `loopedZones` count, and every edge case (backwards loop points, loop points without a mode, unrecognized modes) degrades with a plain-language explanation instead of silence.
- Proven at every layer, twice over: the implementing agent's render gates show a 1.5-second recording sustaining at full level through a 10-second hold with pitch exact to the cycle count and release decaying to digital zero; the independent review then booted a real app instance and imported a library over the live control connection where one instrument looped by authored opcodes and another only by its embedded WAV chunk — both looped, six times past their natural end, with the report confirming both. The suite grew to 2,741 tests across 307 suites, zero warnings, with old projects' playback pinned byte-identical — a non-looping instrument renders exactly the bytes it rendered yesterday.

## 2026-07-17 — Measurement finds the next freeze before any user does
- The follow-up measurements promised after the render-freeze fix are in, and they split cleanly: writing rendered audio to disk is innocent (never more than 21 milliseconds across 21 measurements at all four write sites), but the gain-adjustment step that runs when a bounce targets a loudness level is guilty — over 1.1 seconds of frozen main thread on a 2.7-minute song, ten times the action threshold. It's now a filed, numbers-backed work item riding the same proven off-thread pattern as the loudness fix. Also swept in: the generation-card test gate got its header cleaned up and, in the process, two dormant bugs in the gate's own checks were caught and filed (one calls a command that doesn't exist, one compares a number against the text "0:33"); and the measurement probe that settled last cycle's timing-alignment question was preserved permanently in the repo with its five confirming run logs, rather than dying with the development session.
- One process incident, fully disclosed and fully recovered: a careless revert command briefly wiped an earlier uncommitted fix along with the measurement scaffolding it was meant to remove. The agent caught it immediately, reconstructed both files exactly (verified against the independently-recorded reference from that fix's own review, byte for byte), and the full suite passed twice after recovery — 2,716 tests across 305 suites, unchanged. The lesson is now a standing rule for every future work session in this repo.

## 2026-07-16 — The engine's sample rate becomes a decision, not a discovery
- First construction step of the approved device-rate redesign: the audio graph's processing rate is now handed in when the graph is built, instead of being re-asked from the output device at every use. Today it's set to the same value as before (the device's rate at build time), so nothing behaves differently — but the door this closes is real: a device changing its rate mid-session can no longer half-update the engine's internal processing chains while audio still flows at the old rate, a latent inconsistency the design review uncovered. From here, switching the whole graph to a fixed project rate (the step that ends Bluetooth-induced plugin storms) is a one-line change gated on a hardware measurement probe.
- "Nothing behaves differently" was proven three ways: the full suite (now 2,716 tests across 305 suites, including two new tests pinning that an injected rate genuinely shapes the graph) passed with every existing test untouched; a live staged session rendered a half-amplitude sine at exactly the true-peak physics predicts; and a deterministic 20-second mixdown rendered over the control connection came back byte-for-byte identical — same SHA-256 — before and after the change. The measurement probe itself waits on one thing: a loopback audio device, which needs a user's go-ahead to install.

## 2026-07-16 — The last known post-render freeze is dead
- Yesterday's design review approved it; today it shipped: loudness measurement after a render now runs off the main thread. The proof came out more dramatic than expected — on a 2.4-minute program, the pre-fix control run didn't just feel slow, it tripped the app's own wedge detector mid-operation ("main actor unresponsive for 9.5 seconds") and had the bounce command rejected outright; post-fix, nearly two thousand liveness probes through the same operations measured 34 milliseconds typical, under a second worst-case, zero rejections. An independent second gate exercised the three remaining render paths (stem export, mixdown, bounce-in-place) with the same result: median one millisecond, worst 14.
- The measurement itself is provably unchanged — a new test pins the off-thread result exactly equal (not approximately equal) to the synchronous one on a varied multi-segment program, and the full suite grew to 2,714 tests across 304 suites, all green. One honest leftover, already filed: the file-write and gain-apply steps still run on the main thread with much smaller cost; they get measured next, and moved only if the numbers say so.

## 2026-07-16 — Settled by design review: the audio engine will stop chasing your headphones
- Milestone 19 closes with its architecture question answered. Today, the whole live audio graph runs at whatever rate the current output device reports — so a Bluetooth headset dropping into call mode drags every effect, instrument, and timing calculation down to 24 kHz, forcing a storm of plugin re-preparations on every device change. The design review's verdict: the graph should run at the project's own rate, always, with a single conversion at the very edge where audio meets the device — and it turns out Apple's own SDK documents exactly this configuration (the review quotes the header text; both quotes were independently re-verified). Every downstream benefit follows by construction: effect timing and latency compensation become identical on every device, live playback finally matches exported files bit-for-bit in configuration, and device swaps stop triggering plugin re-preparation entirely.
- The review also found something worse than the filed complaint: today's device-change recovery restarts the engine without reconnecting it, briefly leaving the processing chains prepared at the new rate while audio still flows at the old one — a latent inconsistency window nobody had noticed. Because this project has been burned three times by undocumented audio-framework behavior, nothing ships on documentation alone: a five-part live measurement probe (with pass thresholds fixed in advance and a designed fallback) gates the actual switch. The implementation lands as five separately-gated steps now seeded as the next milestone, alongside one immediately-approved fix: loudness measurement after renders moves off the main thread, closing the last known way a long song could briefly freeze the app after rendering. Design only — no code changed today.

## 2026-07-16 — Quick pulse-check on native Apple-silicon music generation: nothing new, sidecar stays
- The standing question "could the AI song generator run natively in Swift instead of the Python sidecar?" got its scheduled re-check: the Swift MLX audio ecosystem still ships no diffusion or music-generation model class (text-to-speech, transcription, and codecs only), so the local ACE-Step sidecar remains the right design. The only movement anywhere nearby — a new Python diffusion text-to-speech pipeline — is both the wrong model class and the wrong language to change that verdict. The watch condition stays armed in the research notes; no code touched.

## 2026-07-16 — The proving grounds get permanent: five verification gates graduate into the repo
- The strongest end-to-end checks from the last three milestones lived in a temporary session folder that dies when the development session ends. Five of them are now permanent tooling under `scripts/gates/`: the sketchpad honesty gate, the piano-roll undo/split reseed gate, the mid-play track-add scaling pair (the before-and-after proof that idle clips no longer tax track creation), and the out-of-clip ghost-note gate. Each was made self-contained — the scaling pair now generates its own test tone at runtime instead of depending on a file that no longer exists tomorrow — and each carries an honest header: what it proves, where it came from, and for the timing gates an explicit warning that their thresholds were calibrated on this machine and belong to a human runner, not CI. All five ran green from their new homes, twice over: once by the engineer who moved them, once independently.
- The sweep tool that captures the app at every window size had a subtle honesty bug of its own: opening an effect-editor card switches the app to Mix view by design, but closing it doesn't switch back — so every later capture labeled "arrange" silently photographed the mixer. Fixed and proven across the full 24-frame matrix, including after three open/close cycles. One filed complaint turned out to be stale — git history shows the alleged bogus header note never existed in that file — recorded as such rather than "fixed." Suite unchanged at 2,713 tests across 304 suites; no app code touched.

## 2026-07-16 — The piano roll stops lying about notes past the clip edge
- Notes hanging past the end of a MIDI clip used to draw at full neon brightness — indistinguishable from notes that would actually play. The engine's truth, pinned in code before a single pixel changed: a note whose start lands past the clip end never sounds at all, and a note that starts inside but runs long gets cut off exactly at the boundary. The editor now tells that truth. A pill that runs past the edge glows to the boundary and continues as a flat dim ghost; a pill wholly beyond it (including one starting exactly on the edge — the subtlest case) is entirely ghosted; velocity stems dim only when their note's onset genuinely never fires. A shaded region and hairline now mark the clip end across all three editor bands — note grid, velocity lane, and controller strips — as one continuous column, and ghost notes stay fully editable: drag one back inside the clip and it re-lights.
- Verified live over the control connection, both directions: extending a clip re-lights everything past the old boundary in place, trimming it shows only what survives (a wire trim actually clamps and drops out-of-range notes in the project — a distinction the editor now renders honestly, since only direct note edits can leave latent notes behind). An independent check staged a scenario the implementation never saw, injecting out-of-clip notes through a different command route and confirming every treatment at native resolution — including the boundary-exact ghost and the dimmed stems. Suite grows to 2,713 tests across 304 suites, zero warnings, crash logs untouched.

## 2026-07-16 — Adding tracks mid-song got dramatically cheaper — and a hidden timing bug died on the way
- Adding a track while a song plays used to cost time proportional to every clip on the timeline, playing or not: each player paid a ~6-millisecond start-up handshake even when it had nothing to play. Now players with nothing scheduled simply don't start. Measured end-to-end over the control connection: a mid-play track add with 40 clips elsewhere on the timeline dropped from 438 ms to 162 ms once the playhead was past them, and the per-clip cost collapsed from ~6.5 ms each to zero — adding a track in a large project now costs the same whether the timeline holds ten clips or forty. Active clips are untouched (the same experiment's active-clip numbers held exactly), and six new sample-exact tests pin the tricky cases, including a clip added mid-play onto a previously-idle track landing on the grid to the exact sample.
- The design review for this work surfaced something bigger: a live measurement probe proved (five runs, unambiguous) that macOS starts a late player at its actual start time rather than its requested one — so on resumes with more than ~10 active clips, the serial start loop overran its 60-millisecond anchor window and every later player played subtly behind the grid for the rest of the roll. This had been true at scale for months, inaudible to every loudness-based gate. The fix scales the start window with the number of players that will actually start (small sessions byte-identical, a 40-clip resume waits a uniform third of a second and comes back in perfect lockstep instead of immediately-but-smeared). The probe's verdict, the alignment law, and the start-skip rule are now recorded in the architecture's settled sequencer-clock contract. 2,708 tests across 304 suites, crash logs untouched.

## 2026-07-16 — The crash that almost shipped gets a permanent guard
- Last week's rarest bug — a once-per-day crash when instrument setup raced sound-bank operations — was fixed two days ago; today it got its insurance policy. A purpose-built stress test now packs roughly an order of magnitude more deliberately overlapping prepare/renegotiate/teardown collisions into a tenth of a second than a full day of real use would produce, all aimed at the exact serialization gates that fix installed. If anyone ever weakens those gates, the suite dies loudly instead of shipping a roulette wheel. The test also has to prove it did something: it counts every operation it raced and demands the exact expected totals, so it can never silently degrade into a test that passes by testing nothing.
- The same test permanently bounds how long instrument preparation may take under load (the systemic-slowdown detector: typical half-throttle preparation measures ~2 seconds mid-churn; the alarm is set at 8), and its stress load flushed out one brittle timing assumption elsewhere in the suite — a fixed 300-millisecond wait that's now a patient poll with identical pass criteria. Verified three ways: two clean full-suite runs from the implementer, an independent re-run, and a third run with the CPU deliberately half-starved by competing processes — all green, 2,702 tests across 303 suites, and the crash-log folder unchanged through every run.

## 2026-07-16 — The second library format lands: .dspreset imports on the same honest pipeline
- One day after .sfz, the Sampler now imports `.dspreset` sample libraries — the XML format behind hundreds of free community instruments (Pianobook and friends). The new parser reads the format's real-world shape, verified against the format author's own export tooling: instrument-wide defaults cascading through groups down to individual samples, fractional-semitone tuning, linear or dB volume, velocity layers, round-robins and random alternation, and UI chrome that's deliberately ignored but always counted in the import report — never silently dropped. Both formats now funnel into one shared representation and one shared policy engine, so the honesty rules (dry-run reports, reason-coded skips, loop and size warnings) are identical no matter which format a library arrives in — a parity test literally authors the same instrument in both formats and demands field-identical results.
- Verified beyond the 22 new tests: a hand-authored preset the implementation never saw — three levels of inheritance, sample paths with spaces, and an inverted velocity split compounded with inverse octave tuning — imported over the wire and rendered the quiet note at 878 Hz and the loud note at 438 Hz, exactly as authored; the same fixture pair rendered through the .sfz path produces bit-matching peak levels, parity visible in the audio itself. Suite grows to 2,701 tests / 302 suites; the AI-facing import tool's guidance now teaches both formats.

## 2026-07-16 — Real sample libraries walk in the door: the Sampler imports .sfz instruments
- The thousands of freely available sampled instruments in SFZ format — pianos, drum kits, orchestral libraries — can now be imported directly onto the built-in Sampler: from the Instrument Picker's new "Import Sample Library…" button, over the control connection, or by an AI agent through MCP. The importer handles how these files exist in the wild: multi-file libraries stitched together with includes and macros (the flagship Salamander piano's main file is nothing but scaffolding), sample paths with spaces, note names instead of numbers, Windows line endings and path separators, and five levels of inherited settings. What a library expresses lands on the zone features built in the last two milestones: velocity layers, round-robins, layered groups, per-zone tuning, pan, trims, and envelopes.
- The design's honesty rule is enforced end to end: nothing degrades silently. A dry-run mode returns the full import report — what imported, what was skipped and why (release-triggered samples, keyswitch articulations beyond the default), which opcodes were ignored, and how many gigabytes of samples the library references (with a warning at 500 MB and a refusal above 4 GB unless forced) — before anything touches the project; the real import is a single undoable edit. Malformed macro files refuse loudly with the exact file and variable named, because a half-expanded library imports as garbage. Verified independently beyond the 61 new tests: a hand-authored library the implementation never saw — spaces everywhere, chained macros, and a deliberately inverted velocity split — imported over the wire and rendered with the quiet note at 878 Hz and the loud note at 438 Hz, exactly the inversion as authored. Suite grows to 2,679 tests / 301 suites plus 129 MCP tests; `.dspreset` support comes next on the same foundation.

## 2026-07-16 — The app stays alive while it bounces: no more frozen UI during renders, on any audio device
- Chasing last cycle's "AirPods broke the tests" mystery uncovered something better than the suspected cause: bouncing a song froze the entire app for the render's duration — a full-length song meant ~25 seconds of dead UI and rejected commands, long enough that the app's own health monitor declared it wedged. The offline renderer now yields between chunks, capping any pause at about 85 milliseconds of audio. Proven live over the control connection: during a 39-second render, 282 status probes answered in 37 milliseconds typical, 58 worst-case, zero rejections — where before the fix that entire window was silence. The AirPods, it turned out, were innocent of this half: the freeze always existed; a long test render simply crossed the health monitor's threshold at the same time the headphones changed the sample rate.
- The headphones were guilty of the other half: tests had silently assumed a 48 kHz output device, and a Bluetooth headset in mic mode really runs the graph at 24 kHz. Those expectations are now computed from the device's actual rate (with a dedicated 24 kHz proof that the formula tracks rate, never a constant), so the suite is honest on any machine. And the new cooperative timing surfaced a third find with its own dividend: a rare, pre-existing crash race between instrument setup and sound-bank operations — already on file from a one-off crash log — became reliably reproducible, got fixed at both sites, and the crash corpus has been flat since. All 2,618 tests and the full MCP suite green; one architecture question filed: should the live engine follow a degraded Bluetooth rate at all, or run at project rate like the pros do.

## 2026-07-16 — Every zone gets its own voice: per-zone tuning, pan, sample trims, and a real ADSR envelope
- The Sampler's zones now carry the playback half of what real sample libraries express: per-zone tuning in cents, stereo placement with the standard constant-power pan law, a velocity-to-loudness depth control, per-zone one-shot (a kick that always rings out on a kit where everything else releases), sample start/end trims, and a full attack-decay-sustain-release envelope computed per voice — the same proven state machine the built-in synth uses. Zone gain's ceiling doubled to +6 dB so imported libraries that boost quiet samples arrive at level. As always, every field is optional and old projects play back bit-identically — one test literally replays the old playback law sample-for-sample against the new engine and demands equality.
- Two things surfaced beyond the feature itself. First, a save/reopen hole: none of the new-generation zone fields were being written into project files, so a velocity-layered kit built over the wire would silently lose its layers on reopen — found, fixed additively (old project files stay byte-identical), and pinned with its own persistence tests. Second, verification caught the test environment drifting underneath us: eight latency assertions and three integration tests began failing identically on completely clean code. The culprit turned out to be delightfully mundane — AirPods connected mid-session, macOS made them the default output at Bluetooth's 24 kHz, and the limiter's five-millisecond lookahead honestly reported half as many samples; the tests had silently assumed a 48 kHz device all along. Filed as the next priority item (including the real finding buried in it: the app's control surface stalls hard enough to trip its own watchdog when a Bluetooth headset is the default device) so the suite's green stays trustworthy on any machine. The feature itself proved out end-to-end over the wire: hard-left pan bounced to a file with the right channel at exact digital zero, +1200 cents doubled the rendered frequency (ratio 2.002), the sustain plateau landed 19 loudness units down, and the +6 dB gain lift measured 6.02. Suite grows to 2618 tests / 298 suites.

## 2026-07-16 — The built-in Sampler learns how real instruments are sampled: velocity layers, round-robins, and layered groups
- Sampled instruments sound alive because a soft piano hit and a hard one are different recordings, repeated drum hits alternate between takes, and layered mics fire together. The Sampler's zones can now express all of that: a velocity range per zone picks the right recording for how hard the note was played, round-robin and random gates rotate or shuffle between alternates, and zones in different groups layer while zones in the same group take turns. Every field is optional — existing projects decode untouched and play back bit-identically (the regression suite proves it byte-for-byte), and AI agents get the same power over the wire and through MCP, so an agent can hand-build a velocity-layered kit today, before any file import exists.
- The real-time contract held the line: alternation state lives with the render thread (allocated up front, never touched by the UI), a seeded generator makes renders reproducible in tests, and the voice pool grew from 16 to 64 so pedal-down velocity-layered playing doesn't starve. Verified twice over — the engine suite measures the rotation order, the random split, and the layering math sample-by-sample, and an end-to-end wire check with deliberately inverted zone gains proved the routing: the soft note rendered nine loudness units louder than the hard one, exactly as designed. Suite grows to 2602 tests / 295 suites.

## 2026-07-16 — The open piano roll now follows the truth when an AI edits the clip out from under it
- With the piano-roll editor open on a clip, a trim, split, or undo arriving from the arrangement or over the wire (the way AI agents edit) used to leave the entire editor frozen on the pre-edit picture — notes and controller points the project had already deleted kept drawing, and the readout quoted a deleted point's value until the clip was reselected. The editor's edit models now watch the incoming clip value and reseed themselves whenever it genuinely diverges: matters because a human watching the editor while an agent works must never be shown dead data.
- The refresh is surgical, not a sledgehammer: the editor's own edits round-trip through the store and arrive back looking like external changes, so the models compare canonical content first and refuse to reseed on their own echo — scroll position, note selection, and the chosen controller lane survive normal editing untouched. A reseed keeps the selection's survivors, cancels any in-flight drag cleanly, and recomputes the beyond-clip ghost boundary from the new length. Verified live across all three mutation paths (trim both directions, undo, split) with the editor open the whole time and zero reselects; suite grows to 2594 tests / 294 suites. M18, the hardening round, closes with this — all nine items verified.

## 2026-07-16 — SFZ and .dspreset import gets a verdict: GO, scoped honestly, ten days of work mapped
- The spike asking whether the built-in Sampler should read the two big free-sample-library formats came back a clear GO, built on real evidence: a census of five actual free libraries (fetched as raw text, opcode by opcode) showed the practical core is key ranges, velocity layers, round-robin/random alternation, tuning, and simple envelopes — while loops barely appear in acoustic content, and the famous Salamander piano can't even be read without SFZ's include/macro preprocessing layer (its main file contains zero note data). That preprocessing was promoted to must-have; loops moved to a later round, reported honestly on import rather than silently dropped.
- The design maps everything onto the existing zone model with additive-optional fields (old projects decode unchanged and play byte-identically), keeps the real-time contract intact (round-robin state lives with the render thread, allocated up front like the pitch-bend machinery), and rejects the tempting shortcuts by name: embedding a third-party SFZ engine (a C++ dependency inside the audio path that AI agents couldn't edit zone-by-zone) and import-and-flatten (which would quietly discard the velocity layers that make sampled instruments sound alive). Work is filed as four independently shippable roadmap items totaling ten to eleven days; both docs live in docs/research/ with every claim cited, spot-checked against the original sources.

## 2026-07-16 — Sketchpad candidate rows stop lying during model warm-up: one job, one story, everywhere
- While the AI generator was booting and loading its model, the generation card told the truth ("LOADING THE MODEL…") but the Sketchpad's candidate row — tracking the same job — still said QUEUED with an amber RECONNECTING badge, because its own status poll couldn't land yet. The row now resolves against the generation registry (the card's source of truth) at render time: during boot it shows the card's exact stage words, while running it carries the generator's rich progress text verbatim with matching percentages, and when the registry says the job died it fails the row on the spot with the same reason — a killed generator now reads as a red FAILED row with the actual error, not an eternal RECONNECTING. Terminal rows (done, imported, failed on their own) keep their richer local presentation untouched.
- Verified live on the real boot path twice over: once through the full happy lifecycle (boot → load → generate → done, row and card agreeing frame by frame on screen), and once through a deliberately induced production failure (generator process killed mid-job — both surfaces converged on the same FAILED story in the same second, verbatim reason included). Suite grows to 2584 tests / 293 suites.

## 2026-07-16 — Ultra-wide windows lose the dead glass: the piano roll now fills whatever screen you give it
- On very wide windows (up to the 3456-point ultra-wide stress case) the piano roll's note grid, velocity lane, and controller strip used to stop at their content width, leaving as much as 89% of the editor as an empty black void that read like broken rendering. All three bands now extend to the panel edge as shaded latent grid — one shared layout rule decides the width, and the honesty language survives intact: the lit grid is still exactly the playable window, the shade and the clip-end hairline mark everything beyond as latent. Creating a note out there is deliberately legal and behaves exactly like the controller-point rule shipped earlier today (silent until the clip is extended over it).
- The transport bar's left-anchored readout cluster at ultra-wide was judged and kept on purpose, with the rationale now written into the design language: readouts ride the buttons they describe, surplus width goes to the middle of the bar, and controls that drift with window size break muscle memory. Fixed chrome never re-flows for wide windows; workspace content claims the surplus. All alignment checks pixel-exact; suite grows to 2570 tests / 292 suites.

## 2026-07-16 — Controller points past the clip's end now tell the truth: ghosted, not glowing
- CC points beyond a clip's end are legal data that simply doesn't play (the engine schedules strictly inside the clip; extending the clip brings them to life). The controller strip used to render them at full neon past the note grid — bright, glowing, and lying about being audible. Now the lit trace ends exactly at a thin clip-end hairline and everything beyond renders as a ghost: the lane's own color, dimmed, no glow — visible, editable (drag a point across the boundary and its treatment flips live), but unmistakably inert. One engine-honest definition in the model decides the split, so the drawing can never drift from what actually plays. The rule and its rationale are recorded in the design language; a small correction landed with it (trimming a clip doesn't preserve out-of-window points — it drops them; the docs now say so).
- Verification went three lengths deep: the original seam state before/after, an extension re-lighting the ghosts, and a trim dropping them — and that last pair exposed a separate, pre-existing bug now filed on the roadmap: an open piano-roll editor doesn't refresh when the clip is trimmed from the arrangement or over the wire (notes, velocities, and controller data all render stale until the clip is reselected). Suite: 2568 tests / 292 suites.

## 2026-07-16 — A test-runner annoyance turns out to be a real crash bug in instrument loading — now fixed
- What was filed as "the test helper sometimes crashes at exit, polluting crash reports" was actually a live memory-corruption race in sound-bank loading: Apple's DLS/SF2 instrument engine keeps process-global unlocked state, so loading a bank while another sampler was being disposed (or while a second bank loaded) could fault — and the shipping app was exposed through everyday paths like setting instruments on two tracks in quick succession, or starting a bounce while a bank loaded. Two crash reports captured the exact two-thread interleave; a purpose-built stress test then reproduced it on demand (3 for 3).
- The fix serializes every dangerous touch of that engine — loads, teardowns, even the final release when an instrument's last owner lets go — on one dedicated queue, with a trap that turns any future violation into a clean failure instead of silent corruption. The stress test stays in the suite as a permanent regression gate. Proof: 5/5 stress runs and 3 consecutive full suites clean where the old code crashed roughly once per run, plus a live wire-level storm against the running app (24 concurrent instrument loads; project teardowns fired mid-load, six for six survived). Suite grows to 2564 tests / 292 suites; the audio render path is untouched.

## 2026-07-16 — The "slow track add" turns out to be the price of pressing play: a measurement clears the rebuild's name
- The filed defect said adding a track mid-playback got ~2.7× slower since spring (143 → ~390 ms at 41 tracks). Per-phase measurement proves the engine-rebuild core is unchanged (~140 ms today, same class as the m13 record) — the difference is the benchmarks: the old one had a single rolling audio clip, the new one has forty, and each rolling player costs ~6 ms to restart (a per-player render-cycle handshake inside Apple's framework, paid identically by a plain transport play of the same session). The honest budget is linear: ~140 ms plus ~6 ms per rolling clip. Confirmed by independent variation at fixed track count: 10 clips → 240 ms, 40 clips → 404 ms.
- No code changed — the deliverable is the cost model, now written into the architecture doc, plus two filed candidates for shrinking the per-player term (skipping players with nothing scheduled; batching the starts, which needs a design round first). Both m16 regression gates green, suite at 2563 tests / 291 suites.

## 2026-07-16 — The app can now report its own hang: a wedged UI answers honestly instead of going silent
- The engine watchdog has always covered a stalled engine; a frozen main thread was invisible — the app would keep accepting control connections and then silently hang every command, leaving an AI agent staring at a dead peer. Now a background monitor pings the main thread every second and declares a wedge after 2.5 s of silence, and the control server answers from outside the frozen tier: `engine.watchdogStatus` reports `mainActor: {responsive: false, wedgedForSeconds}` in about a millisecond, every other command fails fast with a plain-language explanation instead of hanging, and a breadcrumb log (`~/Library/Logs/DAWPro/main-actor-wedge.log`) records every wedge and recovery with durations — written off-main, because the wedged thread can't. Healthy responses gain `mainActor: {responsive: true}` beside the usual engine fields. No auto-restart by design: detection and honesty only.
- Verified hard: during a staged freeze a brand-new control connection established in 5 ms and immediately learned the app was wedged; the audio engine played straight through a 10-second wedge (the playhead advanced ~25 beats — the render thread never depended on the UI); back-to-back wedges detect and recover cleanly with per-wedge durations. Zero new wire commands — the honesty rides the existing watchdog verb. Suite: 2563 tests / 291 suites.

## 2026-07-16 — The 985-megabyte ghost: the filed memory leak turns out to be already dead, and now we know exactly what it was
- M18 opens with the scariest filed defect — RSS growing ~10 MB per project cycle under agent-style churn, 114→985 MB over a 90-cycle soak — and closes it without changing a line of code, because the investigation proved the leak died last week. The mechanism, now named with measured evidence: every time a player start raised the "disconnected state" exception that m16-a taught the app to survive, Apple's audio framework abandoned that player's internal scheduled-buffer state (≈0.6× the scheduled bytes, per raise, unreachable from outside — Apple frameworks are not exception-safe). The leak was born the day surviving those raises became possible and died days later when m16-h eliminated the raise class entirely. A bisected A/B against the exact leak-era build proves it: the same storm that gains 17 MB per cycle there is flat on today's build, with zero raises.
- The mandated 90-cycle soak now measures 0.065 MB/cycle steady-state (a one-time warm-up floor, then a flat band with healthy reclamation dips), an independent storm with a different churn shape confirms flat, both m16 audibility gates still pass, and the full suite is green. Total true malloc leakage after a storm plus 21 control connections: 7.4 KB — with a one-line hygiene candidate filed for even that. Sometimes the most valuable fix is proof you don't need one.

## 2026-07-16 — M17 wraps: the docs catch up with the features, and the feedback milestone closes
- Every user-feedback feature from this milestone is now documented where users and agents actually look: FEATURES.md gains rows for the insert-effect editors, space-bar transport, timeline pointer gestures, the free-instruments guide, the generation progress card, and the resize audit — plus two stale counts fixed (Explain coverage is 74 controls, not 46) and one long-stale row corrected (MIDI CC has been shipped since m16-b; the table still said "not yet"). The design language gains the controller-strip labeled-readout rule, the hover ghost-line and refusal-bubble idioms, and the generation card as the canonical violet surface. The architecture doc now records the staging laws that made this milestone's verification honest (settle timing, real-typing semantics, read-only bare seam calls).
- Seven verification gates that proved M17's features were promoted from throwaway session scratch into `scripts/gates/` with their measured laws and known quirks documented in-header, so future regressions can re-run the exact checks. M17 is complete: every feedback item from the 2026-07-15 session shipped and verified (the MLX-native spike stays open by design as a re-check tripwire). No code changes; suite stands at 2545 tests / 289 suites.

## 2026-07-16 — AI generation stops being a black box: one card tells you what's happening, every time
- Every generation job — started from the Sketchpad, by an AI agent over the wire, or through an import — now surfaces in one violet progress card that rides both workspaces: who started it, what stage it's in (real pipeline text like "Generating music (batch size: 2)…"), live percent, elapsed time, and an explicit red FAILED state carrying the worker's reason verbatim. If the generator isn't running, generating simply starts it — the card narrates "starting the AI generator…" and "loading the model…" instead of leaving you staring at nothing. Kill the generator mid-job and the card says so within seconds, plus a notice on the transport. There is deliberately no cancel button: the engine has no abort, and offering a lie is worse than nothing.
- Two long-standing honesty bugs died during verification: live jobs used to read QUEUED for their entire render (the client only recognized a literal stage string the real generator never sends), and a generation that failed while the app was reconnecting left its Sketchpad row spinning forever instead of admitting failure. Both fixed and regression-tested against the real generator's measured output. Suite: 2545 tests / 289 suites; zero wire surface changes (one new Explain topic: the card explains itself).

## 2026-07-16 — The window can be any size now: a resize audit fixes five alignment defects, one of them severe
- A systematic sweep of window sizes (small laptop to ultra-wide), both workspaces, both densities, and stacked side panels found and fixed five defects. The severe one: opening the Sketchpad or the clip-fix panel in a small window could overflow the entire layout — transport bar pushed off-window, blank white voids. Side panels now compress and scroll internally instead of dictating a minimum window size, a rule now written into the design language ("workspace side panels compress, never overflow").
- The rest of the polish: track-header names no longer truncate ("Synt…" → "Synth 10" even at the narrowest sidebar), mixer strips of different kinds (instrument/audio/bus) now align their pan knobs, faders, and section headers on one line rack-wide via a reserved chip slot, the piano roll's controller readout is labeled ("Mod (CC 1) 123" instead of a floating "123"), and instrument chips finally fit their full names. Ruler-to-lanes grid alignment was machine-verified pixel-exact before and after at every size. Suite: 2508 tests / 288 suites; zero wire surface changes.

## 2026-07-16 — Where the free instruments are: a verified guide, and the host proven against real plugins
- New guide `docs/FREE-INSTRUMENTS.md`: eleven verified free AU instruments (what they are, where from, install gotchas), the honest answer to "can I use Logic's instruments?" (no — they're app-internal, and the guide explains what IS shareable), what DAW Pro ships built-in, and a worked example of checking your own machine. Notable finding baked in: Spitfire LABS was folded into Splice INSTRUMENT in late 2025, so the guide points at the living product, not the dead brand.
- The hosting chain was proven against real third-party plugins end-to-end: Surge XT and Dexed were installed (user-level, no admin password — the guide documents the trick), discovered, loaded onto tracks, and rendered audibly (−19/−23 LUFS) entirely through the control plane. Kontakt 8, Reaktor 6, and Splice INSTRUMENT load cleanly too but stay silent until you give them content — expected shell-instrument behavior, now documented. Decision recorded: no VST3 hosting for now (every marquee free instrument ships AU on macOS); SFZ/DecentSampler import filed as a future spike. No code changes; suite stands at 2508 tests / 288 suites.

## 2026-07-16 — Space bar, at last
- Space toggles the transport: stopped plays from the playhead, playing (or recording) stops — the exact same actions as the transport buttons, now on the key every DAW user's thumb expects. The guard rails matter as much as the key: a space typed while renaming a track or marker, or while writing to the AI copilot, inserts a space and never touches the transport — even mid-recording. Key-repeat, modifier chords (⌘Space stays Spotlight's), and floating plugin windows are all ignored. The play button's tooltip now advertises "(space)". Suite: 2508 tests / 288 suites; zero wire surface changes.

## 2026-07-16 — The timeline starts talking back: grab the playhead, click to seek, double-click to split
- The arrange timeline now behaves the way your hands expect. Hover the playhead and the cursor becomes an open hand — grab it and scrub; the transport follows every tick of the drag. Hover empty timeline space and a faint ghost line marks the snapped beat under your pointer; click and the playhead jumps there. Everything follows the SNAP setting, and ⌥ bypasses it for fine placement — the same fine-drag modifier used everywhere else in the app. None of this can steal a clip drag or selection: clips and take lanes always win the pointer.
- Double-clicking a clip to split it now tells the truth when it can't: instead of silently doing nothing, a refusal (like a comp-member clip needing take.setComp or take.flatten first) appears in an amber bubble with the exact same message an AI agent gets over the wire — one vocabulary, human and machine. Splits land as a single undo step, notes fall to the correct halves, and redo re-splits. Suite: 2497 tests / 287 suites; zero wire surface changes.

## 2026-07-16 — The arrange view learns to zoom — and a years-old grid misalignment dies with it
- Zoom in and out of the timeline at last: ⌘+/⌘−/⌘0, trackpad pinch (anchored at the pointer), or the new toolbar cluster next to SNAP — from 25% (whole-song overview, bar labels thinning out automatically) to 1250% (individual beats stretch wide for fine edits). Zooming never loses your place: the playhead (or your pointer) stays pinned to the same pixel while the timeline scales around it. Track rows get S/M/L height steps in the same cluster. Both settings are remembered across launches, are not undo steps, and never touch the project data agents see.
- Fixing the zoom plumbing surfaced and killed a defect that had been in every arrange screenshot since the pinned ruler shipped: the lanes were drawn 6 pt to the right of the ruler, so every gridline sat slightly off its tick. Ruler and lanes are now pixel-coincident at every zoom level (worst measured deviation: 1 px, from line centering). Suite: 2481 tests / 286 suites; zero wire surface changes.

## 2026-07-16 — Click an insert, get knobs: every built-in effect now has an editor panel
- The mixer's insert effects finally open: click any built-in insert (or the slider glyph on its row) and a dark-glass editor card appears with a control for every parameter — proper units (Hz, kHz, ms, dB), logarithmic travel on frequency sliders so the musical range isn't buried, double-click to reset, hold ⌥ for fine control, changed values glow cyan. Adding an insert from the "+" menu opens its editor immediately, one editor is open at a time, and the master chain's inserts are editable the same way — previously master effects could only be adjusted by AI agents over the wire.
- Every slider drives the exact same parameter path AI agents use, so a drag is heard live, lands as a single undo step, and an agent changing a parameter is reflected in an open card immediately. Audio Unit plugins keep their own plugin windows. Suite: 2458 tests / 285 suites; no wire surface changes.

## 2026-07-16 — The control surface stops guessing: typos are taught, discarded recovery is confessed
- Every mutating command an AI agent (or any wire client) sends now rejects unknown parameters with a teaching error that names the bad key and lists the valid ones — ending the class of bug where `track.add {type:"instrument"}` silently created the wrong kind of track. 101 commands are covered (the rest are pure reads); the same strictness now applies at the MCP tool layer, where the SDK's default behavior had been silently stripping unknown keys before the app ever saw them.
- Crash recovery is now honest over the wire: if starting a new project (or opening/saving one) consumes a pending crash-recovery offer, the response says so — `discardedRecovery` with what was lost and when. Recovery timestamps are standard ISO-8601, and a new `project.recoveryBundles` command makes per-session abandoned work discoverable instead of filesystem-only. Verified with a real kill-and-relaunch crash simulation, twice independently. Suite: 2445 tests / 284 suites, npm 118/118; wire surface 126 commands / 129 MCP tools.

## 2026-07-14 — File→New no longer silences the rest of your session
- A serious, long-hidden playback defect is fixed: starting a new project after the engine had ever played (or adding a track after the session's first play) left every subsequently added audio clip permanently silent — honestly flagged with "couldn't play" notices, but silent. The investigation reproduced the cause in a 30-line pure-AVFoundation program: macOS's audio engine never grants start permission to a player attached more than one node deep while the engine is running, even though every public API reports it as connected. Every mixer strip in the app is three nodes deep, so any strip born on a running engine was a dead player host.
- The fix routes every strip birth through the two shapes proven safe: after a new-project rebuild the engine now stays stopped until something actually needs it (first play starts everything together), and adding a track while the engine runs triggers one clean engine rebuild (a 40-track batch add costs exactly one). Verified by a committed regression gate that plays and measures actual audio across five new-project cycles (previously silent from cycle 2, now full level on every cycle), the full teardown-crash test matrix (95 cycles, zero crashes), and byte-identical offline renders. Suite: 2418 tests / 283 suites, npm 118/118; wire surface unchanged.

## 2026-07-13 — Draw your expression: the piano roll gains a controller strip
- The MIDI expression feature is now complete end to end with its editing surface: a collapsible strip under the piano roll's velocity lane shows one controller lane at a time — pitch bend against a center guideline, mod wheel, sustain, or any CC via chips with plain-language names ("Mod (CC 1)", "Sustain (CC 64)") and a "+" menu. Draw with the pencil to insert points, drag a point to move it; each gesture is one undo step, and a strip edit is byte-for-byte the same operation an AI agent makes over the wire. Densely recorded gestures render as a clean stepped line (handles reappear as you zoom in), and arrange-view clip blocks show a faint trace of the first controller lane so expression is visible at a glance.
- Editing lives in the Pro density; the Simple density shows an honest "2 controller lanes" chip so data is never hidden. Clips without controller lanes render pixel-identically to before. Suite: 2411 tests / 283 suites, npm 118/118; wire surface unchanged. This completes the MIDI CC milestone arc (design → playback → live capture → editing surface).

## 2026-07-13 — Play it in: live CC, pitch bend, and sustain now sound through and record into takes
- Expression from a real MIDI controller now works end to end: turning the mod wheel or pressing the sustain pedal is heard immediately (within one audio quantum), and recording a take captures those gestures as controller lanes on the recorded clip — including a sustain pedal pressed during the count-in, which lands as the correct starting value rather than being lost. Captured curves are automatically thinned (duplicates dropped, dense wiggles bounded) so recordings stay light without losing the final value of any gesture.
- Loop recording composes correctly: each cycle's take lane gets the controller values that fall in it, and a pedal or bend held across a cycle boundary is injected into the next cycle's lane at its start — so every take plays back exactly as it sounded. Also fixed along the way: take lanes now preserve their gain envelopes and controller lanes across save/load (envelopes had been silently dropped since the take format landed). Verified by a live end-to-end test with a virtual MIDI keyboard, run twice independently; note-only recordings are proven byte-identical to before. Suite: 2392 tests / 281 suites, npm 118/118; wire surface unchanged.

## 2026-07-13 — MIDI clips learn expression: CC, pitch bend, and channel pressure now play back
- The two-audit-running gap in the MIDI model is closed for playback: a MIDI clip can now carry controller lanes — mod wheel and any other CC, pitch bend, sustain pedal, channel pressure — and they sound, on the built-in instruments (bend actually bends the pitch, sustain actually holds the notes) and on hosted Audio Units (which receive the raw MIDI). Two new commands (`clip.setControllerLane` / `clip.removeControllerLane`, with matching MCP tools) let agents author expression curves; splitting, trimming, duplicating, and arranging clips all carry the lanes correctly, including the value in effect at a cut point.
- The engine "chases" controller state at every playback start, seek, and loop wrap — so a loop never starts with a stuck sustain pedal or a leftover bend from the previous pass, and offline renders match live playback by construction (pinned by a render that measures a 440 Hz note bent to the expected 493.876 Hz). Projects without controller data save byte-identically to before. Suite: 2367 tests / 280 suites, npm 118/118; wire surface 125 commands / 128 MCP tools.

## 2026-07-13 — Timing-compensation buffers get the same seam protection as effect tails
- A theoretical hazard measured by the last audit (structurally real, never once observed in 113 adversarial trials) is now closed for symmetry with the effect-chain fix that shipped earlier: the delay buffers that keep plugin latency compensated could, in a sub-millisecond window at a stop or seek, replay one stale buffer of audio a few milliseconds late. The clearing now uses the same two-pass countdown the effect chains use during live playback, while offline rendering deliberately stays single-pass (proven necessary for byte-identical bounces). A forced-interleaving test reproduces the old behavior permanently as a negative control; the audit's own three capture probes re-ran clean as the regression gate.
- Verification also strengthened an open lead: under an adversarial 41-track rig, a second project-rebuild cycle in one instance skipped every clip with honest "couldn't play" notices (the app stays alive and honest where it used to crash — but the underlying AVFoundation rebuild defect is now filed for a proper investigation of its own). Suite: 2310 tests / 275 suites, npm 106/106; wire surface unchanged.

## 2026-07-13 — "Render my song" now works on MIDI-only projects
- The most natural agent workflow — compose MIDI, then render with default settings — used to dead-end on a false error claiming the project "has no audio clips." The mixdown default now uses the same render window every sibling command already used (through the end of the last clip of any kind, plus a two-second tail), so a MIDI-only project renders on the zero-parameter call. The error now fires only for a genuinely empty render range, and says what to do about it ("add clips or pass an explicit durationSeconds").
- Renders with an explicit duration are proven byte-identical to before (pinned by checksum), the stems command turned out to already default correctly (now pinned so it stays that way), and the stem/bounce equivalence guarantees all held verbatim. Suite: 2306 tests / 275 suites, npm 106/106; wire surface unchanged.

## 2026-07-13 — A missing audio file is no longer a silent mystery
- The last quiet failure in playback honesty is closed: a clip whose audio file has been moved or deleted used to just play as silence with no explanation anywhere. Now it raises a playback notice the moment it's discovered — whether that's when a project opens ("'Bed Vox' will be silent — its audio file is missing… Restore or re-link the file"), when recovery restores a session, or when the engine rebuilds and can't open the file. The notice names the clip, the actual file path, and where it sits in the timeline; agents see the same facts in the project snapshot without having to catch the open response.
- One subtle case surfaced during verification: recovery bundles reference media by absolute path, and those produce no warning in the recover response at all when the file is gone — the new notice is the only signal, which is exactly why it derives from the project's real state rather than echoing warning strings. Suite: 2304 tests / 275 suites, npm 106/106; wire surface unchanged.

## 2026-07-13 — MIDI CC and pitch bend: designed, measured, ready to build
- The most-requested missing capability — continuous controllers (mod wheel, sustain, pitch bend, channel pressure) — now has a complete design: controllers live on MIDI clips as compact stepwise lanes (not mixer automation — different plane, different transport), play back through the same schedule that already survives gapless loops, and always **chase**: starting playback anywhere delivers the correct controller state first, so a sustain pedal or bent note is never stuck from a previous pass. The design round also measured the engine's real event-throughput budget (settling the thinning policy for dense controller recordings) and uncovered two latent bugs the implementation will fix on the way in — including one where a schedule bookkeeping formula silently assumed every MIDI event comes in on/off pairs.
- Implementation lands in three phases (playback, live input + recording, piano-roll editing strip) behind twenty numbered verification conditions, including byte-identical rendering for projects that use no controllers at all. Design: docs/research/design-m16b-midi-cc.md.

## 2026-07-13 — The crash class is dead — and it wasn't what it looked like
- The audit's three crashes looked like a SwiftUI drawing bug; the design round proved otherwise with a deterministic reproduction: the audio engine was raising an Objective-C exception ("player started when in a disconnected state") in the middle of starting playback, and that exception corrupts Swift's main-thread bookkeeping — after which the app either crashes at some unrelated later moment (the drawing code was just the most frequent bystander) or, worse, silently stops responding while looking alive. A crash log from July 6 proved the class long predates last week's changes.
- Three layers of fix landed: playback never hands a disconnected player to the audio system (a clip that can't play is skipped with an honest playback notice instead of an exception); every engine entry point now runs behind an exception barrier that converts a raise into a clear error plus a notice instead of letting it corrupt the app; and all seventeen custom drawing surfaces were hardened so no isolation checks sit in the drawing path at all. The killer recipe that took the app down by the second pass now runs clean indefinitely (verified independently, ten of ten, plus a 15-minute adversarial soak and a ten-round mutation storm — zero crashes, zero hangs), and everything still draws pixel-identically. Suite: 2294 tests / 273 suites, npm 106/106. One new lead filed for the next audit: memory grows under extreme project-rebuild churn — measured, bounded recipe recorded, not yet diagnosed.

## 2026-07-13 — The post-M15 audit: a real crash class found, next milestone planned
- With M15 closed, an audit agent again spent a session driving the app over the control connection like a demanding beta user — and this time caught something serious: the app crashed three times in about 35 minutes of ordinary use, all with the same signature (SwiftUI Canvas drawing closures faulting on a stale captured reference during playback), once on a project with only two tracks. All three crash logs are preserved with reproduction recipes; killing this class is the next milestone's first item. The audit also measured a quieter honesty gap — a clip whose audio file is missing plays as silence with no playback notice (the one case the new notices system doesn't cover) — plus a false error that blocks rendering MIDI-only projects with default settings, a silent crash-recovery discard over the wire, and more silently-ignored-parameter traps than the last survey concluded.
- The good news held up under attack: loop recording, master automation, the arrange commands, multi-meter math, crash recovery fidelity, and a 150-second playback with a live gapless loop wrap (zero audio overruns across 290,000 callbacks) all passed adversarial probing. The previously-filed PDC timing hazard was measured directly — structurally real but never observed in 113 adversarial trials, so it gets a cheap symmetry fix, not an emergency. M16 is now planned: the crash fix first, then MIDI CC lanes (the long-requested headline, behind a design doc), then the honesty round.

## 2026-07-13 — Documentation catch-up: the docs now match the app (M15 complete)
- A documentation pass folded everything the last two milestones shipped into the user-facing docs: gapless looping, loop-take recording, master volume automation (including the stems-stay-fade-free policy), the new arrangement commands, playback notices, and the bypass crossfade all have honest FEATURES entries now; stale rows were corrected (the master effect chain has been shipped since m13-d; MIDI CC honestly doesn't exist yet), all published command/tool counts were brought up to today's reality (123 commands / 126 MCP tools), and the loop-recording semantics are now taught both in the wire protocol's own documentation and the MCP tool descriptions agents read. One long-standing grammar bug in an error message ("a instrument track") is also fixed.
- This closes **M15 — the post-gapless correctness round** end to end: the metronome meter-map bug, loop-cycle take recording, master automation, agent arrangement ergonomics, engine notices, click polish, and docs. Suite: 2286 tests / 270 suites, npm 106/106.

## 2026-07-13 — Two audible clicks hunted down and removed
- Toggling an effect's bypass mid-signal no longer clicks: the hard swap (measured landing between two adjacent samples) is now a 10 ms equal-power crossfade, so switching a compressor or delay in and out during playback is smooth — reverb and delay tails ring out naturally under the falling gain instead of being chopped. Toggling back mid-fade reverses the fade seamlessly rather than restarting it.
- A subtler one from the M14 files is also gone: after an edit during playback, one buffer of pre-edit audio could sneak into a freshly-cleared delay line and come back as a faint one-time echo. The clearing now double-arms during live playback so the first post-edit buffer always renders on a clean line. Both fixes were proven by measurement (before/after captures with stated thresholds, and the old bug kept reproducible in the test suite as a negative control); projects that never touch bypass render byte-identical to before. Suite: 2286 tests / 270 suites, npm 106/106; wire surface unchanged.

## 2026-07-13 — When playback degrades, the app now says so
- Until now, three kinds of quiet trouble — a gain envelope or fades that couldn't be applied this pass, or a clip still being time-stretched that plays as silence — were only ever written to a developer log. They now surface as playback notices: an amber chip appears in the transport bar (in both Simple and Pro modes — a beginner whose fades vanished needs to know more, not less) and opens a card listing each notice in plain language, with a repeat count when the same thing keeps happening. Nothing in the project is ever changed by a notice, and a healthy session shows nothing at all.
- Agents get the same honesty: `project_snapshot` now carries an `engineNotices` field (absent when all is well), coalesced by kind, cleared when a project is created or opened, never saved to disk. Proven live end-to-end: deleting a clip's audio file out from under a scheduled fade produced the honest notice over the wire, repeats coalesced, and a new project cleared it. Suite: 2276 tests / 269 suites, npm 106/106; wire surface unchanged at 123 commands / 126 tools.

## 2026-07-13 — Restructure a whole arrangement in one command
- Three new commands close the gap between what a human can drag and what an agent had to emulate clip-by-clip: `clip.duplicate` copies a clip with everything it carries (notes or audio, gain, fades, envelope, stretch) and lands it cleanly under the no-silent-overlap law; `arrange.insertBars` and `arrange.deleteBars` add or remove whole bars across the entire session — every track, marker, tempo and time-signature change, automation lane, and the loop region move together, meter-aware (a bar in a 6/8 section is honestly six beats), one undo step for the whole restructure. Edge policies are explicit rather than surprising: straddling clips split or trim, a swallowed loop is disabled, and a delete that would knock a time-signature change off its barline is refused with a clear error.
- The audit's silent-typo trap is also dead: misspelling a parameter to `track.setOutput` used to silently re-route the track to master and report success — it (and `input.setDevice`, the one other command with the same shape) now rejects unknown keys with an error that names the typo and lists the valid keys. All proven live over the control connection end-to-end. Wire surface grows deliberately: 123 commands / 126 MCP tools (was 120/123), Copilot catalog 55. Suite: 2253 tests / 264 suites, npm 106/106.

## 2026-07-13 — Fade out the song: master volume automation
- The master bus can now be automated: draw a volume curve on the master strip (Pro mode) or program it through the AI channel with the same automation commands tracks use — "fade out the last eight bars" is a one-command job for an agent now. The fade applies before the master effect chain, so a limiter keeps working the fade the way a mastering chain should, and the timing stays sample-exact even with the limiter's lookahead (proven bit-for-bit). A flat automation lane renders byte-identical to simply setting the master fader.
- One deliberate policy ships with it: stem exports and bounce-in-place stay fade-free — a fade is a performance decision, not material, and baking it into stems would ruin re-mixability. The mastered mixdown gets the fade; stems don't (pinned by a measurement that shows exactly that). Simple mode hides the lane; recording is never colored by a master fade. Suite: 2226 tests / 262 suites, npm 92/92; wire surface unchanged at 120 commands / 123 tools.

## 2026-07-13 — Record a new take on every loop pass
- The classic loop-recording workflow has landed: hit record with a loop enabled and the transport seeks to the loop start, plays the region gaplessly (the M14 machinery), and lands each pass as a new take lane on the same take group — three passes, three comparable takes, newest selected, one undo removes the whole recording. Stopping mid-cycle keeps an honest partial lane; MIDI notes held across the loop seam keep their true length (a bug-in-waiting the design round caught before it shipped); count-in composes cleanly and now has its own small transport-bar stepper. Everything was proven live over the control connection: a real session recorded three lanes with the right notes in the right lanes.
- The audit's honesty bug is dead both ways: recording with a loop no longer silently rolls linear while claiming the loop is active, and editing loop bounds mid-recording is refused with a clear "stop first" error instead of corrupting the take. Recording without a loop is bit-identical to before (pinned by a measured checksum). No new commands — loop state alone decides. Suite: 2197 tests / 258 suites, npm 86/86; wire surface unchanged at 120 commands / 123 tools.

## 2026-07-13 — The metronome now respects time-signature changes
- The audit's top bug is fixed: the live metronome (and the offline renderer, and count-in) built its click grid from a single fixed time signature, so any project with a meter change accented the wrong beats after the change. All three paths now receive the project's real meter map — re-running the audit's measurement probe verbatim shows all 23 captured clicks classified correctly with downbeats exactly where 4/4→3/4 puts them, offline renders match, and a count-in in 3/4 is honestly three beats anchored to the meter at the record position.
- Implementation surfaced a second latent bug the audit hadn't caught: a meter-only change never reached the audio engine at all (only tempo changes pushed), which would have left a playing session's clicks stale — both store funnels now push meter changes too. Projects in a single time signature render byte-identical to before. Suite: 2173 tests / 254 suites, npm 86/86; wire surface unchanged at 120 commands / 123 tools.

## 2026-07-13 — The post-M14 audit: two live-measured bugs found, next milestone planned
- With gapless looping done, an audit agent spent a session using the app the way a beta user (or AI agent) would — driving it entirely over the control connection — and measured two real bugs: the live metronome ignores time-signature changes (with a 4/4→3/4 change, downbeats land on the wrong beats — every click was captured and classified by pitch and level to prove it), and recording with a loop enabled silently records linear from the playhead while claiming the loop is active. It also caught a trap where a typo in one command's parameter silently re-routes a track instead of erroring, and — good news — dismissed a previously-filed concern with code evidence (loop-boundary dragging already commits cleanly once per gesture). Six probe legs including a 53-track session ran crash-free, the first fully clean audit session on record; project-file compatibility and scaling checks came back healthy.
- The findings seed the new M15 milestone, now on the roadmap in priority order: the metronome fix first, then loop-cycle take recording (recording a new take on every loop pass — the payoff M14's fixed anchor makes possible), master-volume automation ("fade out the song" is currently impossible), three agent-ergonomics verbs (duplicate a clip, insert/delete bars project-wide, and the typo-trap hardening), a visible engine-notices surface for degradations that today only reach stderr, two click-polish items, and doc fold-ins. Audit document: docs/research/audit-m15.md; nothing in the product changed today. Suite unchanged: 2168 tests / 253 suites, npm 86/86; wire 120 commands / 123 tools.

## 2026-07-13 — Gapless looping ships: the loop wrap is no longer an event (M14 complete)
- The final phase landed and was proven against the live app over the real control connection: a delay tail rings straight through every loop boundary (measured energy across each seam, zero silent gaps, cycle onsets spaced drift-free to the exact frame — the old ~60 ms hiccup and ~2% per-cycle drag are gone for audio, instruments, automation, and metronome alike). Stopping still silences instantly, and editing the loop bounds mid-play costs exactly one clean seam with no stale audio from the old bounds — both directions proven live.
- Long loop sessions no longer accumulate memory: played-out schedule history is pruned under a new invariant (decided and written into the design doc before a line of code, per the milestone's amendment law), proven by a soak test across multiple pruning events with every note still delivered exactly once and sustained voices unharmed. The architecture doc now records the settled loop contract. One cosmetic finding filed for later: a faint, bounded echo blip can ride inside an *edit* seam (never a wrap). Suite: 2168 tests / 253 suites, npm 86/86; wire surface unchanged at 120 commands / 123 tools.

## 2026-07-12 — The metronome joins gapless looping, and toggling it never touches your audio
- Phase three of gapless looping: metronome clicks are now scheduled across loop cycles ahead of time like everything else, so the click at the loop boundary fires every single cycle (it used to skip one after each wrap) and even a quarter-beat loop at 400 BPM clicks perfectly for 25+ measured cycles. Clicks follow the meter map across the seam — a 4/4→3/4 change inside the loop accents correctly in every cycle.
- Turning the metronome on or off mid-play is now completely isolated to the click player: the headline proof pins every one of 480 000 rendered frames — clip output during a toggle session is byte-identical to a never-toggled run, commanded clicks appear exactly on the grid, and cancelled clicks never sound. The old fallback that restarted playback via a seek just to toggle the click is retired. Suite: 2166 tests / 251 suites; wire surface unchanged at 120 commands / 123 tools.

## 2026-07-12 — Instruments and automation now sail through the loop point too
- Phase two of gapless looping: MIDI notes and automation curves are now unrolled across loop cycles ahead of time, the same way audio clips were in phase one — the per-wrap "flush everything and rebuild" is gone. Synth voices persist through the seam: a sustained note ringing across the loop boundary keeps sounding (measured: the seam that used to render pure silence now carries the note's full energy), note-offs land at their true musical positions even past the loop end, and a note released at the seam pairs correctly with the same pitch re-struck in the next cycle. Automation values step cleanly at the boundary and interpolate exactly within each cycle. Stopping, seeking, or editing still cuts voices immediately, as it should.
- Every event's sample position is pinned to exact arithmetic under multi-segment tempo maps, and the schedule-extension machinery is proven to deliver every note-on and note-off exactly once even when the schedule grows mid-render. Non-looping playback is byte-identical to before. One design-document correction came out of implementation: append-only schedules grow with total cycles played (not bounded by the look-ahead as the design claimed) — recorded as an open decision for the final phase. Suite: 2160 tests / 250 suites; wire surface unchanged at 120 commands / 123 tools.

## 2026-07-12 — The loop hiccup is dying: audio now plays seamlessly through the loop point
- The first implementation phase of gapless looping has landed. Until now, every loop wrap stopped and restarted the audio engine's players — about 60 ms of silence plus a 35 ms overshoot at every pass, and a ~2% per-cycle drift. Audio clips now play straight through the wrap: upcoming loop cycles are queued onto the already-rolling players ahead of time, spliced sample-exactly (verified bit-for-bit across multiple wraps — zero dropped frames, zero silence at the seam), with fades and gain envelopes pre-baked once and reused every cycle. Even the extreme case — a quarter-beat loop at 400 BPM, ~26 wraps per second — sustains indefinitely.
- Implementation surfaced two undocumented macOS audio-player behaviors that the research spike's margins had only just cleared (a fully-drained player queue goes permanently silent; mid-flight queueing needs a minimum head start) — both are now recorded in the design document with the measured numbers, and the scheduling rule that contains them is pinned by tests. MIDI, automation, and the metronome still do their old per-wrap reset for now (their gapless phases are next); recording and non-looping playback are proven byte-identical to before. Suite: 2150 tests / 249 suites; wire surface unchanged at 120 commands / 123 tools.

## 2026-07-12 — The feature guide catches up with the product (M13 complete)
- FEATURES.md had drifted behind three milestones of shipped work: it now teaches multi-segment tempo maps with meter changes (range 20–400 BPM, not the old single-tempo 20–300), the true control surface size (120 commands / 123 MCP tools, up from the documented 108/111), the three newer command namespaces (marker, tempo, instrument), and the fact that AI agents can read live peak/RMS meters for the master and every track straight out of `project.snapshot` — a capability the docs previously undersold. Two older user-facing copy fixes from the beta round were re-verified still in place.
- Documentation-only, proven by a file-timestamp scan (exactly one file changed). With this, **M13 — the correctness & console round — is complete**: teardown crash killed, silent clip overlaps ended, recording guarded, master insert chain, clip gain envelopes (plus their perf fix), gapless-loop blueprint, hidden-surface AU picker and pinned ruler, meter-aware snapping, and these doc fold-ins.

## 2026-07-12 — Pressing play on a long clip with a gain envelope is no longer expensive
- Since gain envelopes landed, any clip carrying one was fully pre-rendered into memory on every play, seek, or loop restart — for a 10-minute stereo clip that meant roughly 190 ms of extra latency and a ~280 MB memory spike each time, even if the envelope only dipped a few bars. The engine now pre-renders only the spans the envelope (or a fade) actually shapes and streams the rest straight off disk: the same clip now schedules in ~41 ms with a ~1 MB envelope footprint. Clips whose envelope genuinely shapes the whole region still pay the honest full cost.
- The sound is untouched — every render is bit-for-bit identical to before, proven by four checksum gates including a real project file (rendered from a copy). Measurement drove the fix: two fancier candidates (math micro-optimization, a bake cache) were rejected because the numbers showed the whole-region read was the real cost. 10 new regression pins. Suite: 2144 tests / 248 suites; wire surface unchanged at 120 commands / 123 tools.

## 2026-07-12 — Dragging snaps to the real bar grid, even after a time-signature change
- Until now, dragging and resizing snapped as if the whole song stayed in its opening time signature — in a piece that switches from 4/4 to 6/8, "snap to bar" would land clips off the real barlines after the change. Every drag surface now consults the project's meter map: clip move/trim/split/stretch, loop-region create/resize/move, marker drag and placement, take-comp painting, and the audio-import landing spot all snap to true barlines on both sides of any meter change, and finer grids follow the local meter. Songs in a single time signature behave exactly as before, pinned by exhaustive property tests against the old math.
- 11 new tests, including a live check that the on-screen drag math and the AI control channel agree exactly on a 4/4→6/8 map. Suite: 2134 tests / 247 suites; wire surface unchanged at 120 commands / 123 tools.

## 2026-07-12 — Every installed effect plugin in the mixer menu, and a ruler that never scrolls away
- The mixer's insert menu used to list only the 9 built-in effects even though the app could already host any installed Audio Unit through its AI channel — now an "Audio Units…" item opens a searchable dark-glass picker of every installed AU effect, and a pick routes through the exact same code path AI agents use, so UI adds and wire adds produce identical results. The master strip honestly hides the option (master inserts are built-ins-only by design, not offer-then-error).
- The bar ruler — together with the loop band, marker lane, tempo lane, and TRACKS header — now stays pinned at the top while you scroll a deep session, and both columns still scroll as one unit so track rows and their lanes can never drift apart. Also: the Pro gain-envelope overlay now ghosts the waveform beneath it so breakpoints stay readable against the audio. Suite at landing: 2123 tests / 247 suites; wire surface unchanged.

## 2026-07-12 — The loop seam has a blueprint: gapless looping is proven possible
- Anyone who builds beats in DAW Pro knows the loop hiccup: every time the loop wraps around, there's a brief stumble before it picks up again. We measured it precisely for the first time — about 35 ms of overrun past the loop end, then 60 ms of silence, and (worse for groove) each cycle runs about 2% long, so a loop slowly drags against any external rhythm. Reverb and delay tails also get chopped at every pass. Today's research spike proves the fix is real: the audio system can splice loop cycles together with zero dropped samples — verified bit-for-bit in a permanent test suite, including the hard case of queueing the next cycle while the current one is still playing.
- The full design is written up with a phased implementation plan (scheduled as the next milestone) and eight pass/fail conditions that gate the work. A pleasant consequence of the chosen approach: effect tails will ring naturally through the loop point, the metronome will toggle on/off mid-playback without a stutter, and loop-cycle take recording (record a new take on every pass) becomes straightforward to build on top. No product code changed today — this was measurement, proof, and planning; the loop behaves exactly as before until the implementation lands. Suite: 2115 tests / 246 suites; wire surface unchanged at 120 commands / 123 tools.

## 2026-07-12 — Shape a clip's loudness over time with gain envelopes
- Audio clips can now carry a gain envelope: click points onto the clip (Pro view) and drag them to ride the level inside the clip itself — duck a breath, swell into a chorus, tail out a phrase — without touching the track fader or writing automation. Points interpolate smoothly in decibels, they multiply with the clip's existing gain and fades rather than replacing them, and the whole gesture of dragging a point is one undo step. The envelope travels with the clip when you move it, splits continuously when you split the clip (no level jump at the seam), survives trims, and is preserved when takes are grouped or comped. Simple view keeps clips clean — envelopes are a Pro-view tool, though they always play back in both views.
- AI agents get the same control through one new command that sets or clears a clip's envelope in a single call, with plain-language rejections for anything malformed (unsorted points, MIDI clips — envelopes are audio-only for now). Rendering honesty was proven hard: an envelope-free project reproduces every historical render byte-for-byte — including after a full save-and-reopen cycle — and rendered ramps were measured against their analytic values over the control wire (−6 dB at the midpoint of a 0-to-−12 ramp, exactly). A mandated engine review confirmed the real-time audio thread is untouched — envelopes are baked offline before playback — and caught two edge-case bugs (take-comping and AI clip-fix could lose or stale-bake an envelope) that were fixed with pinned regression tests before this shipped. Suite: 2111 tests / 245 suites; npm 86/86; wire surface grows to 120 commands / 123 tools; Copilot catalog 52.

## 2026-07-12 — Master your song: an insert chain on the master output
- The master strip finally takes effects. Drop an EQ, limiter, compressor — any of the nine built-in effects — onto the master output and shape the whole mix at once; "make this loud enough for streaming" is now a real workflow (EQ, then limiter, then measure loudness) instead of a dead end. The chain sits after the master fader, the last stop before your speakers, so the fader rides into it exactly the way a mastering chain expects. Everything behaves like track inserts already do: reorder, bypass, tweak parameters live while the song plays (the playhead never hiccups — verified mid-playback and even mid-recording), full undo/redo, and it saves with the project. In Simple view the master strip stays clean fader-and-meters; switch to Pro to see the inserts. The master meter and analysis now honestly read what actually leaves the app — after the chain.
- Stems deliberately stay untouched by the master chain — they're for handing off to another mixer or re-importing, so bouncing stems with a master limiter on still gives you the raw, unsquashed parts, and the parts still sum exactly to the pre-chain mix (verified byte-for-byte). AI agents get the same power through the existing effect commands via the address `"master"`, with plain-language refusals for the two things the master chain won't do in v1: host third-party Audio Unit effects, and take part in sidechain keying (in either direction). The whole feature moved zero bytes in existing audio: every previous render anchor reproduced byte-identically with an empty chain, and a unity-gain chain is bit-transparent. One subtle Apple-engine behavior was caught and designed around along the way: the obvious "pre-fader" wiring is not bit-transparent under a non-unity fader, so the shipped shape is the one that is. Suite: 2090 tests / 243 suites; npm 86/86; wire surface unchanged at 119 commands / 122 tools; Copilot catalog grows to 51 commands.

## 2026-07-12 — Your take is safe: routing changes wait until recording stops
- Recording is now protected from the one class of edit that could silently ruin it. Changing what's routed where — adding or removing sends, switching a track's output bus, deleting a track, or re-keying a sidechain — used to be legal in the middle of a take even though it forces the audio engine to rebuild, cutting the capture short while the record light stayed on. Those operations are now politely refused while recording, each with a plain instruction ("cannot add a send while recording — stop first"), and a refused attempt leaves no trace in undo history. Everything that's safe stays live mid-take: volume and pan rides, send levels, effect knobs and bypass, muting, soloing, clip edits, even adding a fresh track or effect — so a producer (or an AI copilot) can keep mixing while the artist records.
- The rule is principled rather than a verb blacklist: an operation is blocked only if it would actually trigger an engine rebuild, so removing an ordinary effect stays legal while removing a sidechain-keyed one waits, and swapping a synth's waveform stays legal while swapping the instrument on a routed track waits. The AI-agent tool descriptions teach the rule up front. Verified with two independent live recording sessions: takes complete intact to the last note, refused commands name their reason exactly, and the same commands succeed the moment recording stops. Suite: 2066 tests / 239 suites; npm 86/86; wire surface unchanged at 119 commands / 122 tools.

## 2026-07-12 — Clips never silently stack anymore, no matter which tool put them there
- Closed the last four ways a clip could land on top of another and quietly double the audio: extending a clip's edge, stretching it longer, and dropping new audio or MIDI at a specific beat all now trim the clip that was already there — exactly like moving a clip has done since the crossfade release. The worst case was real: placing a full-length audio clip on top of an identical one used to double the volume (+6 dB) with nothing visible in the arrangement; that same operation now measures a 0.0000 dB difference. Every one of these edits stays a single undo step that restores both clips, tiny leftover slivers are cleaned up rather than left behind, and recorded takes still stack intentionally — take lanes are exempt by design.
- The fix is structural, not another patch: all clip-geometry edits now flow through one shared policy point, so a future editing verb can't reintroduce the bug by forgetting the rule. An audit of every geometry-touching operation found and closed one more unlisted gap (growing a MIDI clip by inserting time could overlap its right neighbour) and documented why the rest are safe by construction. Verified live over the control wire on both the original bug recipes and an independent second set of scenarios. Suite: 2060 tests / 239 suites; npm 86/86; wire surface unchanged at 119 commands / 122 tools.

## 2026-07-12 — The teardown crash is dead: engines are rebuilt, never unpicked
- Fixed the most serious stability bug the app has ever had: starting a new project (or removing a track) after playing a session with bus routing could crash the whole app, intermittently, deep inside Apple's audio engine. An instrumented experiment run before any fix code named the exact mechanism: once a node has rendered audio and then sits attached across an engine stop-and-restart, Apple's engine quietly forgets how to detach it safely — the previous fix ("park detaches until the engine restarts") was built on that unsafe operation and crashed in its own machinery. The suspicion that the recent sidechain work caused it was tested and disproven: a rebuilt pre-sidechain binary crashed identically.
- The resolution removes the entire trap by design: the app never surgically unpicks a once-used engine again. Any teardown-class change — new project, opening a project, removing a routed track — now discards the whole audio engine and rebuilds it fresh from the project model in a tenth of a second or less (worst measured: 143 ms at 41 tracks; a mid-play rebuild resumes playback seamlessly with meters live within a quarter second). Effect chains, hosted Audio Unit state, plugin windows, and open projects all survive the rebuild untouched. Proven by a zero-crash campaign that used to be near-deterministic death: 100 consecutive rebuilds (+0.4 MB memory), every historical crash recipe, a 12-way played/routed matrix, 41-track stress runs, and an independent gauntlet of back-to-back project switches, bus removals, and undo storms — plus byte-identical offline renders before and after the change. Suite: 2045 tests / 238 suites; npm 86/86; wire surface unchanged at 119 commands / 122 tools.

## 2026-07-12 — Sidechain everywhere it belongs: one command, one tool, one click
- Sidechaining is now a first-class citizen across every surface. A single control command (and matching AI-agent tool) keys any compressor or gate from another track — or clears it — with the update visible immediately in project snapshots, undoable in one step, and safely refused with a plain-language explanation when a request can't work: keying a reverb, keying from a bus, doubling up keys on one strip, or creating a feedback loop (the error names the exact path, like "Kick → Pad → Kick"). The AI Copilot knows the command too, so "make the pad duck under the kick" is now a one-sentence request. Verified live end-to-end: keying through the real command produced a 24.6× duck on the pad, and independently, a gate chopping a tone dropped its stem by 8.5 dB; re-keying to a different source, clearing by omission, undo/redo, and save→reopen all held up over the wire.
- In the mixer, compressor and gate cards in Pro view now carry a KEY picker: choose a source track and a lit cyan "KEY ▸ Kick" badge appears with a one-click clear (Simple view stays deliberately fader-and-meters only). The Explain assistant can teach sidechaining, and the release-blocking equivalence guarantees are now permanent tests: stems still sum to the mixdown exactly with a sidechain active, and bouncing a keyed track is byte-identical to its stem. Projects that never touch sidechain rendered byte-for-byte identically across the seventh consecutive render-gate generation. Suite: 2042 tests / 238 suites; npm 86/86; wire surface 119 commands / 122 tools; Copilot catalog 47. **This completes milestone M12.**

## 2026-07-12 — Sidechain compression is real: kick-ducks-the-bass, sample-accurate
- Compressors and gates can now listen to a *different* track: point a compressor on your pad at the kick drum and the pad ducks every hit (the classic pumping effect), or key a gate on a sustained tone from a rhythmic part to chop it into that rhythm. The keying is sample-accurate — verified with closed-form math, not tolerances: a keyed compressor's dip depth matched the ratio equation to nine decimal places, and a keyed gate opened on the exact frame the key landed. It's also safe by construction: removing the key source degrades the effect back to normal operation without ever failing playback, feedback loops are refused up front with a message naming the exact path that would loop, and every project that doesn't use sidechaining renders byte-for-byte identically to before (proven across six generations of the render gate). Stems still sum to the mixdown exactly with a sidechain active.
- Independent verification caught and fixed one real bug before it could bite: the effect's key assignment survived undo/redo and played correctly, but the project *file* format silently dropped it — save, reopen, and every sidechain would have been gone. That path is now fixed, regression-pinned, and proven live (save → reopen → key intact), and project snapshots read over the wire now show which track keys which effect. For now this is engine-level (AI-drivable through a staging command); the polished wire command, effect-card KEY picker, and Copilot integration land next. Suite: 2027 tests / 235 suites; npm 86/86; wire surface unchanged at 118 commands / 121 tools.

## 2026-07-12 — The tempo lane arrives: see and shape tempo and meter on the timeline
- The ruler now has a tempo lane: every tempo segment is drawn with its BPM label, meter changes fly small time-signature flags, and in Pro density you edit right there — drag a boundary to move where the tempo changes, scrub a segment's BPM, double-click to add a change, and edit the meter at any barline. A whole drag is one undo step, and everything the lane does goes through the same command the AI uses, so what you see and what an agent reads over the wire can never disagree (verified live: the lane's state and the wire's map matched exactly after every edit). Simple density shows the lane read-only — the information without the sharp edges — and single-tempo projects look exactly as before, with no new chrome to ignore.
- The whole timeline now understands meter: bar numbers stay correct across time-signature changes (a 7/8 section numbers its bars exactly right and hands off cleanly to 4/4), the transport shows your position as bars.beats, and the piano-roll grid follows the clip's meter. Audio clips that span a tempo change carry a small amber "tempo" badge — an honest heads-up that audio doesn't stretch when tempo changes (and why quantizing across that boundary asks you to split first). The Explain assistant can now teach the tempo map, and the codebase-wide lint that forbids raw tempo math outside the map reached its end state: exactly one sanctioned home remains. Suite: 1998 tests / 233 suites; npm 86/86; wire surface unchanged at 118 commands / 121 tools.

## 2026-07-12 — Tempo changes are now real: saved, editable, and undoable
- Tempo maps are no longer a hidden engine capability — you (or an AI agent) can now author them. A new pair of control commands reads and replaces the whole tempo map and time-signature map in one step, so a song can slow into its intro and lift into its drop, and the change is a single undo away. A tempo-lane drag folds into one undo step, editing is refused mid-recording, and asking to set "one tempo" on a song that already has tempo changes is politely refused with a pointer to the map command rather than silently flattening your work. Tempo maps now save and reload with the project (older projects and single-tempo songs are byte-for-byte unchanged on disk), and the AI Copilot gained both commands.
- Under the hood this retires the temporary staging scaffold from the previous phase and routes everything through the real, undoable store mutation; in-flight AI clip-fix jobs detect a tempo change through a cheap revision counter. The real-time audio thread stayed completely untouched (all 17 render-path files byte-identical), and the single-tempo render gate reproduced its exact SHA-256 hash. Suite: 1977 tests / 231 suites; npm 86/86; wire surface 118 commands / 121 tools; Copilot catalog 46. Next: the tempo lane UI and meter-aware ruler.

- Building on the tempo-map foundation, the playback engine is now provably correct when the tempo actually changes mid-song: MIDI notes, audio clips, automation, the metronome, fades, and crossfades all land at their mathematically exact sample positions across a tempo boundary, verified with closed-form expectations (not tolerances) around a 120→90 change — and independently re-verified on a different three-segment map (140→70→105) where note spacing matched the analytic integral to the exact sample. Live behavior holds up too: the playhead advances smoothly through boundaries, looping across two tempo changes wraps at the right musical length, and editing the map mid-playback never makes the playhead jump.
- Two known debts from the foundation phase are settled: fades and crossfades now bake correctly across a boundary (equal-power crossfades stay seamless — 0.017 dB spread at the seam), and audio-quantizing a clip that spans a tempo change is cleanly refused with guidance to split at the boundary first, rather than producing subtly inconsistent timing. Projects that never change tempo render byte-identically to before — the original gate project reproduced every SHA-256 hash on the new engine — and stems still sum to the mixdown exactly, with bounce-in-place byte-identical to its stem even under a multi-segment map. Tempo changes aren't user-authorable quite yet: persistence, the wire commands, and undo arrive next, then the tempo lane UI. Suite: 1958 tests / 228 suites; npm 86/86; wire surface unchanged at 116 commands / 119 tools.

## 2026-07-11 — The tempo map's foundation is in, and the audio is provably unchanged
- Under the hood, every place the app converts between musical beats and clock time — clip lengths, splits, fades, recording placement, the playhead, offline rendering, some fifty-six sites in all — now routes through one new tempo-map engine instead of scattered per-site arithmetic. Nothing sounds different, and that's the point: the whole refactor was gated on rendering the same demanding project (odd 97.3 BPM tempo, MIDI, fades, a crossfade, automation, bus routing) before and after, and every output file — mixdowns, all stems, a bounce — came out SHA-256 byte-identical. The gate was then reproduced a third time from a fresh app session to rule out flukes. The real-time audio thread wasn't touched at all: all seventeen render-path files verified checksum-unchanged.
- A permanent lint test now fails the build if anyone reintroduces raw tempo arithmetic outside the map, so the foundation can't erode. With this in place, the next steps can make tempo actually change mid-song — the map does the math; the app just hasn't been allowed to author more than one segment yet. Suite: 1947 tests / 227 suites; npm 86/86; wire surface unchanged at 116 commands / 119 tools.

## 2026-07-11 — Sidechain gets its green light: the one open question is answered
- The sidechain design (kick-ducks-the-pad pumping) hinged on a single unproven assumption: that the audio engine can feed a second, analysis-only input into an effect. A dedicated engine experiment now answers yes on every count — the second input connects cleanly, delivers the key signal sample-for-sample in the same processing quantum (verified bit-exact over thousands of frames, using a signal designed so silence or cross-wiring couldn't fake a pass), fails with a clean recognizable error when nothing is connected (exactly what the fallback path needs), and survives the full torture sequence of disconnects, reconnects, and node teardown that crashed lesser graph code in the past. Two consecutive offline renders came out byte-identical, which is the property that keeps stem exports and bounces trustworthy once sidechain lands.
- The experiment ships as a permanent test suite so the engine can never quietly regress on it. With condition zero met, both sidechain implementation stages stay on the M12 schedule alongside the tempo map. Suite: 1936 tests / 225 suites; no app code changed.

## 2026-07-11 — Groove preset IDs are now genuinely unique (and M11 wraps)
- A subtle bug found during the quantize-panel work is fixed at the root: the built-in swing presets each get a deterministic ID, but the old derivation accidentally gave every `swing8` preset the *same* one — so anything keying those presets by ID (like a picker list) could show or select the wrong swing. The IDs are now derived collision-free, all 44 resolvable presets verified pairwise distinct, with a pinned regression test so the derivation can never silently change again. Good news uncovered along the way: the actual quantize engine always resolved built-ins by name, so no project or agent workflow ever quantized with the wrong groove — the bug was confined to the listed IDs themselves. Built-in IDs changed once with this fix; they're derived, never saved in projects, so nothing on disk is affected.
- This closes out the M11 milestone: quantize & groove UI, the visible undo-history panel, session markers, honest overlaps + crossfades, bounce-in-place, the tempo-map and sidechain design blueprints, and this fix. Suite: 1931 tests / 224 suites; wire surface unchanged at 116 commands / 119 tools.

## 2026-07-11 — Two big features get their blueprints: tempo changes and sidechain
- No new buttons today — instead, the two most-requested "pro" features that touch the deepest machinery got full engineering designs before a line of code is written. A tempo track (speed the song up at the drop, slow it for the outro) turns out to be safe to build: an audit of all 78 places the app converts between musical beats and clock time found that the real-time audio thread never does that math at all, so the change stays out of the most fragile code entirely. The design's first gate: with no tempo changes authored, the app must produce byte-for-byte identical audio to today — provably nothing regresses.
- Sidechain routing (the classic kick-ducks-the-pad pumping effect) got a design that keeps every honesty guarantee this app has earned: stems still sum exactly to the mixdown, and bounces stay byte-identical, even with a compressor keyed from another track. One open question gates the whole feature — a half-day engine experiment — and if it fails, the feature is parked rather than shipped compromised. Both designs land as reviewable documents in docs/research/, with implementation slated for the next milestone.

## 2026-07-11 — Bounce in Place: commit any track to audio in one step
- Right-click a track header and choose "Bounce in Place": the track renders offline — through its whole effects chain, exactly as it sounds in the mix — and lands as a new audio track right below it, with the original muted so the print takes its place. It's one undo step (undo brings the original back un-muted and removes the print; the rendered file stays on disk for redo), works on buses too, and never touches your levels: the mix before and after measures identical to the thousandth of a decibel. Perfect for freeing CPU from a heavy synth, committing a sound you've settled on, or prepping a stem to send to a collaborator.
- The print is bit-exact honest: the bounced file is byte-identical to what `render.stems` produces for the same track — verified twice with SHA-256 comparisons on independent scenarios (an instrument playing a MIDI phrase through an insert, and an audio track). Agents get the same power via `track.bounceInPlace` / `track_bounce_in_place`, with `muteSource` and `name` knobs and plain-language rejections (a bus-routed track tells you its signal already lives in that bus's stem). Suite: 1927 tests / 224 suites; wire surface 116 commands / 119 tools; Explain catalog: 63.

## 2026-07-11 — Overlapping clips stop lying to your ears, and crossfades arrive
- A real bug from the beta audit is gone: dragging one clip on top of another used to leave both silently playing — the overlap doubled in volume with no warning, no visual hint, nothing. Now a move that lands on another clip trims away the covered part (swallow a clip entirely and it's removed), all inside the same single undo step as the move itself, and importing audio onto an occupied lane follows the same rule. Measured, not assumed: the old behavior showed +6 dB in the overlapped span; after the fix the same span measures identical to a single clip, to two hundredths of a decibel.
- And when you *want* two clips to blend, that's now a first-class move: right-click an audio clip and choose "Crossfade with Next" (¼ to 2 beats) — the first clip fades out exactly as the next fades in, using equal-power curves that keep the loudness seamless through the join (measured spread across the seam: 0.03 dB). A little bowtie badge marks every crossfaded seam, undo removes the blend in one step, and agents get the same tool over the wire (`clip.crossfade`, plus `clip.move` now honestly reports anything it trimmed). Asking for a longer crossfade than the recordings can support gets a plain-language explanation instead of silence. Suite: 1908 tests / 222 suites; wire surface 115 commands / 118 tools; Explain catalog: 62.

## 2026-07-11 — Session markers: your song gets named places
- Songs have sections, and now DAW Pro knows their names. Drag on the empty ruler strip to drop a marker — Intro, Chorus, Drop, anything — then drag its flag to move it, double-click to rename it, and click it to jump the playhead straight there. Markers save with the project, undo like every other edit (a long drag counts as one step, not forty), and older projects open exactly as before. The flags live in their own lane under the loop bar, so loop dragging keeps working untouched.
- This one is squarely for the AI side of the house too: "drop at the second chorus" is now a two-call workflow — agents list the markers by name and beat, then seek to one directly by name or id (`transport.seek` accepts a marker now). Five new wire commands and MCP tools cover add, move, rename, remove, and list; the Copilot can use all of them; and asking for a marker that doesn't exist gets a helpful error, not a shrug. Verified live twice with independent scenarios, including proof that undoing a drag lands back exactly where the marker started. Suite: 1889 tests / 220 suites; wire surface 114 commands / 117 tools; Explain catalog: 61.

## 2026-07-11 — Your whole edit history, visible and walkable
- The app has always remembered your last hundred edits by name — but you could only ever see the next one, through the Undo menu item. A new HISTORY chip in the arrange toolbar opens a panel showing the entire list: everything you can still rewind below a cyan "YOU ARE HERE" marker, everything you've undone (and can replay) dimmed above it. Click any entry and the project walks there one honest step at a time through the same undo machinery ⌘Z uses — no shortcuts, no new ways to mutate your project, so nothing this panel does can ever corrupt an edit. Rapid knob scrubs still collapse into a single entry, so the list reads like a story, not a seismograph.
- Agents get the same superpower over the wire: a new `edit.history` command (and `edit_history` MCP tool) returns both labeled stacks in one call, newest-first, so an AI can see exactly what it — or you — just did and step anywhere in that history with plain undo/redo. Proven live twice over with independent scenarios: list order, scrub-coalescing, click-jumping three steps back with the project state verified to match. Suite: 1853 tests / 217 suites; wire surface 109 commands / 112 tools; the panel ships with its own "Explain this" card (catalog: 60).

## 2026-07-11 — The groove engine gets a face: quantize arrives in the app
- Until now, tightening a loosely-played part was something only an agent could do for you over the wire. A new QUANTIZE panel — reachable from a chip in the piano-roll header or by right-clicking a MIDI clip in the arrangement — brings it in-app: pick how fine the timing grid is (musical names like 1/8 and 1/16, triplets included), choose how strongly to pull the notes toward it, and apply. In Simple mode that's the whole story, deliberately. Pro mode adds swing, snapping note ends, and the groove picker: eight built-in MPC-style swing feels, any groove you've saved, and an "Extract from clip" button that lifts the timing feel out of one part so you can stamp it onto another. One press of Apply is one undo step, no matter how much you fiddled first.
- The panel is honest about who's in charge: choosing a groove takes over the grid and the swing, so the panel locks those controls and says so plainly ("set by the groove", "groove sets the feel") instead of letting you drag sliders that would do nothing. Six new "Explain this" cards teach the whole area in beginner language. And the guarantee that matters for an AI-native DAW held: the panel drives the exact same code path agents use, proven twice over — once by the implementing engineer and once independently with different settings, where the panel's result and the wire command's result came out identical to the last digit, on both a plain-grid quantize and a 1/16-swing groove. Suite: 1829 tests / 214 suites. One bug found along the way (two built-in swings sharing an internal id) is worked around in the panel, pinned by a test, and queued for a proper engine fix.

## 2026-07-11 — No more frozen launches: the app stops reading your Keychain before it even has a window
- Since the beta began, one launch in a while — especially right after an update — would hang forever with no window: the app was reading your stored API key from the Keychain during startup, and if macOS decided to ask permission first, the whole app sat behind a dialog that had nowhere to appear. Startup now touches the Keychain not at all: the window comes up, the agent connection comes up (measured: under a second, in the exact scenario that used to hang indefinitely), and the Settings panel then checks your keys in the background using a metadata-only peek that can never trigger a permission prompt.
- If a stored key does need macOS's one-time permission, Settings now says so honestly — "Key stored — macOS will ask for access the first time it's used" — and the prompt appears only when a feature actually uses the key, with the app fully visible behind it. Agents asking over the wire get the same honesty via a new `consentRequired` flag on the provider status. Fifteen new tests pin the rule that startup performs zero Keychain access. Suite: 1814 tests / 213 suites; MCP suite 84/84 — now run, for the first time, with no key-related workarounds at all.

## 2026-07-11 — The recovery prompt learns to take a hint
- The "Restore unsaved work?" prompt that appears after a crash had one blind spot: it only listened to its own two buttons. If the offer got settled any other way — an AI agent resolving it over the connection, or you simply starting a new project — the prompt stayed on screen anyway, offering work that was already dealt with. It now watches the actual state of the offer and dismisses itself the moment that offer is resolved from anywhere, with the same gentle fade the buttons use.
- Proven against the real thing: a genuine mid-session kill, relaunch, prompt up — resolved over the wire, prompt gone; same again with a new project. Six new tests pin the rule that the offer's availability can only ever arm at launch and drops at every path that consumes it. Suite: 1799 tests / 213 suites.

## 2026-07-11 — An honest look in the mirror: the pro-parity audit, plus two rough edges smoothed
- We audited DAW Pro against current Logic Pro and Ableton Live, feature by feature, grounding every claim in the actual code — the result is a ranked list of what a professional would miss first (docs/research/audit-m10q-pro-parity.md). Headliners: the groove engine is fully built but has no UI to reach it; the undo system already remembers a labeled history that no panel shows; and session markers don't exist yet, which matters double here because AI agents want named song sections to navigate by. The audit also caught a real bug nobody had reported: dragging two clips into overlap on the same track silently doubles the volume with no crossfade and no warning — now documented and queued.
- Two long-standing rough edges got fixed on the spot. The Sketchpad's "generator not running" banner used to tell you to "call ai.sidecarStart" — instructions meant for a machine; it now says, like a person would, "press Start to launch it" (agents on the wire still get the technical message, which is right for them). And asking for a plugin window on a sound-bank instrument no longer gets a confusing "built-in soundBank" refusal — it now explains that sound banks browse programs through the instrument picker instead. Suite: 1793 tests / 213 suites.

## 2026-07-11 — The AI clients grow up: official Anthropic and OpenAI SDKs replace hand-rolled HTTP
- The MCP server's lyrics and image generation now go through the official `@anthropic-ai/sdk` and `openai` packages instead of hand-written HTTP calls and JSON parsing — the standard-SDK directive, applied. Nothing changes from the outside: the same tools, the same anthropic-first key preference, the same error messages when keys are missing, and deliberately zero retries (pinned to match the old behavior exactly rather than silently inheriting the SDKs' retry policy). Suno is the honest exception: no official SDK exists, so that placeholder stays hand-rolled and its comment now says so.
- The real win is what came with the migration: the provider layer had no tests at all, and now it has twelve — including a regression pin for the subtle bug this project already met once, where a model's thinking blocks arrive before its text and a naive parser reads the wrong block. Error paths are proven to surface the provider's status and detail without ever leaking a key. MCP suite: 84/84. One environment note: the machine's npm config points at an unreachable corporate registry, so the two new packages were installed from the public registry and the lockfile now references it.

## 2026-07-11 — The instrument picker lands: browse a real library instead of memorizing program numbers
- Click the instrument chip on any track header or mixer strip and a picker opens with the whole library laid out: the built-in synths, the sound banks (the General MIDI bank drills into all 128 named programs organized by 16 categories, drum kit included, with the exact bank numbers shown for the curious), and every Audio Unit instrument on the Mac — all searchable. In Simple mode the same picker speaks beginner: the GM categories become "Instrument Sets" cards with examples ("Brass — e.g. Trumpet"), and the built-in list trims to the two easiest choices. Adding your own SoundFont is a button inside the picker, right where you'd look for it. Everything the picker does goes through the exact same code path agents use over the wire, so what you pick is always what an agent would see.
- Three new "Explain this" cards cover the picker, and the design holds its rules: cyan only on active states, violet nowhere (this is a library, not an AI feature), and a sound-bank instrument never grows a plugin-window button it couldn't honor — that button is structurally reserved for real Audio Units. The track-header chip stays deliberately tiny (a glyph; the full instrument name lives in its tooltip and on the mixer strip) so long track names keep their space. Verified with a nine-screenshot pixel review, including cross-checking the chip against the live project state over the WebSocket. Suite: 1793 tests / 213 suites; Explain catalog 53. With this, the instrument library milestone is complete end to end: engine, wire, and now the UI.

## 2026-07-11 — Real instruments arrive: the General MIDI bank plays out of the box, and SoundFonts are welcome
- MIDI tracks are no longer stuck on the built-in synths. The engine now hosts Apple's sampler and loads sound banks into it — starting with the General MIDI bank that ships inside every Mac: 128 named instruments from Acoustic Grand Piano to Gunshot, plus a drum kit, zero downloads, zero setup. Agents get the full flow today (list banks → browse named programs by category → set a track to "Trumpet — General MIDI"), your own .sf2/.dls files import into a central library with their preset names read straight out of the file, and everything persists in the project. The in-app picker UI is the next piece landing.
- The engineering held the line where it counts: not one line of new code runs on the audio render thread (bank loading happens off to the side, before an instrument is ever published to the graph), a missing or broken bank honestly reports failure and stays silent instead of quietly substituting a built-in, and the proof is spectral — the same MIDI phrase rendered through the built-in synth, the GM piano, and the GM trumpet measures as three genuinely different timbres, verified again live over the wire with a −21.8 LUFS trumpet mixdown. One trap was caught exactly where the design predicted it might hide: a sample-rate change silently wiped the sampler's loaded bank (degrading it to a test tone), and the fix reloads the bank inside the same guarded window every time. Suite: 1772 tests / 212 suites; MCP suite 72/72; 108 commands / 111 tools.

## 2026-07-11 — The Copilot's leash is yours now: choose how many rounds one reply may take
- The in-app Copilot works in rounds — read the project, think, make a batch of changes — and until now every reply was silently capped at eight of them. That cap is now a setting: Settings → Copilot explains the concept in plain words and takes any budget from 1 to 32, applying to the very next reply with no restart. Prefer tight, predictable answers? Set it low. Asking for a whole arrangement? Give it room. Out-of-range values are politely refused in the field, and even a corrupted stored value can only ever load as a safe in-range budget.
- Agents driving the DAW get the same dial per turn: `ai.copilotSend` accepts an optional `maxRounds` override (bounding only that reply — a caller limiting its own budget harms no one), and `ai.copilotState` now reports the effective limits so an agent can see its budget before spending it. The engine reads the budget once at the start of each turn, so changing the setting mid-reply can never tear a turn in half. Proven across three live launches: the default, a persisted choice surviving relaunch, and an out-of-range stored value clamping safely. Suite: 1714 tests / 206 suites; MCP suite 41/41.

## 2026-07-11 — The agent hookup comes out of the terminal: see, copy, and configure your connection in Settings
- Connecting an AI agent no longer requires knowing magic strings: Settings → Agent Connection now shows the live WebSocket address the app is actually listening on, with a one-click Copy button, and a port field that persists your choice (taking effect at next launch — changing it never yanks the connection out from under an agent mid-session). If the port came from the DAW_CONTROL_PORT environment variable, the panel says so honestly instead of looking broken, and the environment always outranks the in-app setting so scripted setups keep working unchanged.
- Agents get the mirror image: a read-only `app.connectionInfo` command (and matching MCP tool, the surface's third growth this milestone — 105 commands, 108 tools) reporting the bound URL, port, and which source chose it — useful for confirming which app instance a session is actually bridged to. Deliberately absent: changing the port over the wire, since config that can sever the caller's own connection is a human decision. Proven live both ways: one launch under the environment override, one launch genuinely binding a persisted port chosen in Settings. Suite: 1695 tests / 204 suites; MCP suite 29/29.

## 2026-07-11 — Bring your own sound: import audio from the File menu or drop it straight onto the arrange
- The DAW finally accepts your files the way every other app does: File → Import Audio… (⌘I) opens a multi-select picker, and dragging audio from Finder onto the arrange shows a cyan lane highlight with a snapped drop-line right where the clip will land. Drop one file on an audio lane and it joins that track; drop it anywhere else — or drop several files at once — and each becomes its own new audio track, named after its file ("Kick Drum.wav" → a track called "Kick Drum"), all starting at the same snapped beat so stems line up by construction. A multi-file import is exactly one undo step, and a corrupt file in the batch reports its own error without sinking the rest.
- Both entry points funnel through one shared, headless-tested pipeline (25 new tests; suite now 1673 in 202 suites), and the live gate proved the full story end-to-end: a three-stem drop fanned out to three correctly-named tracks with waveforms drawing at bar 2, one undo removed all three, and a garbage file imported alongside a good one hurt only itself. One honest note: the open panel and real pointer drags can't be driven over the wire, so the gate drives the identical execution path through a staging command — the thin panel/drop glue was verified by review.

## 2026-07-11 — The window learns its limits: a measured size floor and an arrange view that scrolls instead of shoving
- The window now refuses to shrink past the point where its controls stop fitting (a floor measured from the actual chrome, not guessed), and the track area — sidebar and timeline together, as one pixel-locked unit — scrolls vertically when tracks outgrow the space. The old failure where tall rows times many tracks would shove the transport bar or title row offscreen is structurally gone: verified at the exact floor with eight maximum-height tracks, every control visible, the overflow neatly contained in the scrolling region.
- This closes the layout debts earlier items deliberately parked: the adjustable-panels overflow edge, and the crowded take-group rows at the narrowest sidebar (their automation toggle now folds into the right-click menu below 300 pt, keeping names readable; the toggle relocates, never disappears). One honest note: the bar-number ruler scrolls with deep content rather than staying pinned — pinning it safely needs a fragile scroll-sync we chose not to build this round. Suite: 1648 tests / 200 suites.

## 2026-07-11 — Track headers grow up: names that never vanish, double-click rename, and an ADD button that says so
- Track names now win the fight for space: at any sidebar width the name stays readable — the level meter compresses to a slim floor, the clip-count badge folds into the hover tooltip on narrow sidebars instead of crowding the title, and long names truncate with the full text a hover away. Double-click any track name (or right-click → Rename Track) to edit it inline — Return commits, Escape cancels, empty input safely does nothing, and a real change is exactly one undo step. The lone `+` became a labeled `+ ADD` menu offering Instrument, Audio, or Bus tracks, and an empty project now shows a proper ADD TRACK button — answering the beta question "or is it AI-only?" for good.
- The first cut of this fix guaranteed the name a hard minimum width — and the verification captures caught it re-inflating the window's minimum size at the narrow extreme, the same trap the adjustable-panels work hit and measured its way out of. Round two made the name soft (layout priority instead of a floor), so the row can never push the window around; the width budget is headless-tested. Suite: 1641 tests / 199 suites.

## 2026-07-11 — Remove a measure and the music closes ranks: delete/insert bars lands everywhere at once
- The piano roll's header grows a small BAR cluster: press − to remove the bar under the playhead (everything after slides left to close the gap), + to insert an empty one (everything after makes room). The note surgery underneath is precise and documented — notes reaching into a cut keep the parts that survive it, notes starting inside it are removed, and a note sustaining across an insertion point simply keeps sounding through it. Each operation is exactly one undo step that restores the previous state note-for-note, the delete button refuses to hollow a clip below one bar, and the whole cluster shows in Simple mode too — removing a measure is not an expert move.
- This is the first M10 item to grow the control surface: agents get the same primitive via `clip.deleteTimeRange` / `clip.insertTimeRange` (and matching MCP tools), general to any beat range, with the wire deliberately more permissive than the UI (a full-length delete clamps the clip to its floor rather than erroring). Proven live twice over: an orchestrator gate asserting the exact surviving note set through delete → undo → redo → re-insert (nothing resurrected), and a second independent round trip through the compiled MCP server. Swift suite: 1633 tests / 197 suites; MCP suite grows to 24.

## 2026-07-11 — The ruler learns to loop: drag a cycle region right where the bars live
- The arrange ruler — previously a purely decorative strip — is now the loop's home: drag across it to sketch a cycle region (snapped to the bar in Simple, to your picked grid in Pro), drag either edge to resize, drag the middle to slide the whole region, click inside to toggle looping on and off, and click anywhere else on the ruler to jump the playhead there. The region draws as a slim cyan band above the bar numbers — glowing when looping is live, a faint outline when parked — with the transport bar's LOOP chip staying in perfect sync, and every affordance advertising itself through the hover-cursor system.
- All the drag math lives in a headless, fully tested model (leftward drags produce valid regions, edges clamp rather than flip at their opposite edge, moves clamp at zero preserving length — 19 new tests, suite now 1604 in 194 suites), and agents get the same picture humans do: setting or moving the loop over the wire relocates the band instantly, verified live with the region landing exactly on its predicted bar lines. A small honesty note: a fresh project shows the default 0→16 region as a faint outline rather than nothing, because that region is real state — it's what the LOOP button would loop.

## 2026-07-11 — Clips show their sound: every MIDI clip draws its notes, audio never reads blank
- The beta complaint "clips look blank" is closed. Every MIDI clip in the arrange now draws a mini note map — pitch-mapped pills, higher notes toward the top, each pill at its exact beat position and clamped to the clip's edge — so you can see where the melody sits without opening the editor. It works in both Simple and Pro (seeing your content isn't an edit feature), scales across the full adjustable row-height range, and AI-generated clips stay violet automatically. Take lanes now share the identical renderer, so a clip and its takes can never drift apart visually.
- Audio clips already drew waveforms; the fix there is honesty at the margins — while a file's peaks are still loading (or the file can't be read), the clip shows a dim center line instead of nothing. Verified deterministically over the wire: four known notes landed exactly at their predicted pixel rectangles (including the edge-clamp case), and a real mixdown dropped onto an audio track rendered its waveform live. Suite: 1585 tests / 193 suites.

## 2026-07-11 — The melody editor gets its playhead: see the transport, grab it, scrub it
- The piano roll now shows the same glowing cyan playhead as the arrange timeline, mapped into the edited clip's own beats and drawn straight through the note grid and velocity lane — and only while the transport is actually inside that clip, so its absence tells you something true. Click or drag in the strip along the editor's top edge to jump or scrub the transport freely (unsnapped, the pro default), while stopped or during playback, with the resize cursor advertising the gesture.
- Built as a pure rendering of existing transport state (no new commands — agents already have `transport.seek`), with the beat mapping and visibility rules headless-tested, and the note grid restructured so transport ticks move only the playhead line rather than redrawing the grid every frame. Verified deterministically: seeks over the wire put the line exactly at the left edge of a note known to start at that beat, and a seek past the clip removes it. Suite: 1574 tests / 192 suites.

## 2026-07-11 — The workspace becomes yours to shape: draggable splitters, resizable track rows, and it all persists
- Three layout dimensions are now mouse-adjustable and remembered across launches: the track sidebar width (drag the splitter between headers and timeline), the editor height (drag the piano roll's top edge), and the track row height (drag the bottom edge of any track header — every row and its timeline lane scale together, verified pixel-aligned even at the 64-point maximum). Splitters are hairlines that glow cyan only when your pointer finds them, and every one carries the correct resize cursor from the pointer-affordance work.
- The allowed ranges are honest by measurement, not guesswork: the first cut permitted layouts that pushed the app header and transport bar clean off the window, so the sidebar minimum was re-derived from the track row's actual intrinsic width (measured 242–267 pt → floor 250) and the editor capped at 55% — verified by a full capture matrix at the extremes. Remaining edge (many tall rows can still nudge the title bar) is owned by the upcoming small-window adaptivity item. The gate also flushed out two unrelated bugs now filed: the crash-recovery sheet doesn't dismiss when an agent resolves the offer over the wire, and app startup can hang invisibly on a Keychain consent prompt before the window exists. Suite: 1569 tests / 191 suites.

## 2026-07-11 — The pointer now tells you what you can grab: hover cursors land on every drag surface
- Every existing interactive surface advertises its controllability the moment you hover it: clip bodies show a grab hand (closing while you drag), trim edges and fade grips show horizontal resize arrows, the clip gain chip and every fader/velocity stem show vertical resize, piano-roll notes grab and their right-edge resize handles show arrows, automation breakpoints grab with a crosshair over empty lane space, and take lanes show the paint crosshair. The cursor holds correctly for the whole drag even when the pointer leaves the control, and the implementation (a hit-test-transparent tracking overlay that only ever sets, never stacks) makes the classic stuck-cursor bug structurally impossible.
- The cursor-per-affordance conventions are now written into the design language ("Pointer affordances") so every future control follows them, with the decision logic headless-tested (suite grows to 1557 tests in 190 suites). One deliberate non-change: track headers got no grab cursor because they aren't draggable yet — that arrives with the adjustable-layout item (m10-d) rather than advertising an interaction that doesn't exist.

## 2026-07-11 — The sidecar Start button now tells the truth: live progress, honest status, and a second root cause fixed
- The beta bug had a second layer beyond the launcher fix: once `ai.sidecarStart`'s 30-second window expired, the app forgot it had ever started the sidecar — every status poll then claimed "installed but not running" while models were still legitimately loading. The manager now tracks the boot for its whole lifetime (surviving even an app relaunch mid-boot via the pidfile), keeps reporting a truthful "starting" with elapsed seconds and a human phase hint read from the sidecar's own log ("preparing environment…", "loading models…", "starting server"), and distinguishes a genuinely dead boot ("boot likely failed — check the log") from one that's merely slow. A real spawned-process regression test pins the exact beta scenario; the suite grows to 1545 tests in 189 suites.
- The Sketchpad banner now shows a cyan spinner with "Starting — loading models (42s)"-style live progress and an in-progress STARTING… button instead of a dead control, polling faster while the boot is underway. Verified end to end with a real cold boot watched from a second connection — every in-flight poll reported "starting" (never the old false "not running"), and thanks to yesterday's launcher fix the boot reached healthy in 3.7 seconds. Both banner states pixel-reviewed. With this, both halves of the beta sidecar bug are closed.

## 2026-07-11 — Explain→Copilot hand-off proves out live: hover any control, ask the AI about it, get a real answer
- The last piece of the "Explain this" feature passed its live gate: the exact question the explain card's "Ask the Copilot →" button prefills ("Explain Punch Recording — what should I do with it here?") went through the rail against the live Anthropic API and came back as a genuinely useful beginner answer — what punch-in/punch-out recording is, how to prep the session for it (loop range, count-in, pre-roll), and the honest boundary that hitting record stays a human action in the app. The copilot made zero tool calls and the project state was verified untouched before/after; it even described the current project's tracks accurately purely from its built-in per-round context, with no key material anywhere.
- With ex-c closed, the "Explain this" parent item completes. M8 now has only the OpenAI-key-blocked image-asset item (glass-b) remaining, so development moves to the M10 beta-feedback backlog next. One tooling lesson banked for future gates: the control protocol's JSON key order isn't stable between calls, so state-identity assertions must compare canonicalized structure, not raw bytes.

## 2026-07-11 — The Copilot passes its real-conversation gate: M6, the AI suite, is complete
- The in-app Copilot held its first real conversation against the live Anthropic API and drove actual project edits end-to-end (the rail-e gate, run twice over the wire on the staging port): "Add an instrument track named Neon Bass, and set the project tempo to 100 BPM" produced exactly `track.add` + `transport.setTempo` — verified in the project overview, one track, tempo 100, nothing else touched. The second turn, "Now mute that track," proved genuine agency: the copilot re-oriented itself with `project.snapshot`, resolved the pronoun from conversation history to the correct track UUID, and issued `track.setMute`. Twelve of twelve checks passed, with zero key material anywhere in the transcript.
- With this, the Copilot rail parent item closes and **M6 — the AI suite — is fully complete** (generation, import, stems, vocal repaint, take alignment, lyrics workshop, and the copilot rail, all real-gated; the Suno cloud fallback stays dormant by design). One cosmetic model quirk recorded honestly: the first turn's closing message imagined a pre-existing duplicate track — the edits themselves were exact. Next up: the explain→copilot live hand-off gate (ex-c).

## 2026-07-11 — AI provider parsing fixed at the root — and the first REAL AI lyrics land through the Keychain key
- Fixed the beta-reported "could not parse provider response: missing content[0].text" failure across every Swift provider client. The root cause: the Anthropic parser assumed the first content block is text, but modern models (the default `claude-sonnet-5` included) emit `thinking`/`tool_use` blocks first — and API error envelopes hit the same guard, masking real errors (rate limits, overload) behind the same misleading message. Now ALL content blocks are parsed (every text block collected, thinking/tool-use tolerated), vendor error envelopes surface their own `type: message` verbatim, and the OpenAI client handles null/array-of-parts content plus refusals. Ten new regression fixtures pin every shape — suite grows to 1530 tests in 186 suites. (No official Anthropic/OpenAI Swift SDK exists, so schema-complete parsing IS the standard here; the TypeScript mcp-server already parsed correctly, and migrating it to the official SDKs is filed as m10-o.)
- Proven against the live API, not just stubs: with the beta user's Anthropic key in the Keychain, a real `ai.writeLyrics` round-trip returned well-formed bracketed [verse]/[chorus] synthwave lyrics in 5.3 s (7/7 gate checks) — which also satisfies the M6 Lyrics-workshop real-key gate verbatim, closing that milestone box. The Copilot rail (rail-e) and explain-handoff (ex-c) live gates are now unblocked next. Note for the beta user: the installed app must be rebuilt (`scripts/bundle.sh`) and relaunched to pick up the fix — the running instance predates it.

## 2026-07-11 — Beta feedback round 1 begins: user guide + feature matrix land, and the sidecar start bug is fixed
- The first real beta session produced a full feedback round, now triaged as roadmap milestone M10 (18 items). First deliverables: `docs/USER-GUIDE.md` — a beginner-readable walkthrough of the whole app including how to hook up an AI agent over MCP (WebSocket URL, port override, server registration) — and `docs/FEATURES.md`, a ~200-entry status matrix that is honest about what's still wire-only (track rename, loop region) or not yet built (MIDI CC, master FX chain).
- Fixed the "sidecar did not report healthy within 30s" failure at its root: the launcher re-resolved Python dependencies on every start, and a TLS-intercepted `flash-attn` metadata fetch could kill the boot before the server existed. `run.sh` now runs `uv run --no-sync` whenever the installed environment is present — verified by a live offline boot to a green `/health`. Log audit found no other real issues (the MPS flash-attention and bitsandbytes warnings are benign fallbacks).

## 2026-07-10 — Autosave hygiene: untitled-recovery bundles now age out instead of accumulating forever
- Root cause corrected along the way: the `Untitled-*.dawproj` pile-up in the Autosave folder (114 bundles) was never the retired legacy autosave writer — it's the still-live, intentional `flushForTransition()` data-safety path, which writes one recovery bundle per dirty untitled session abandoned via new/open but only ever cleaned up its own slug. New `ProjectStore.pruneUntitledRecoveryBundles(keep: 5)` runs at every app launch: newest-by-modification-date retention, matches only true `Untitled-*.dawproj` bundles (decoys untouched), never deletes the live session's own bundle, and tolerates missing directories and bundles held open elsewhere.
- Two regression tests pin the retention policy and its edges — suite grows to 1520 tests in 184 suites, zero warnings. Verified live on the staging port: four seeded over-cap fakes were pruned at launch with exactly the newest five real bundles surviving, and the one-time backlog sweep took the real folder from 114 bundles to 5 (crash-detection `session.lock` preserved). This was the last unblocked work item — everything now remaining on the roadmap waits on API keys or Apple Developer credentials.

## 2026-07-10 — M3 (vi-b-2): plugin windows show the real plugin — the vendor-view ladder lands, and M3 is complete
- Plugin windows now resolve the actual vendor UI instead of always falling back to the system parameter list: a never-failing three-step ladder tries the modern `requestViewController` (raced against a 5-second once-gate timeout so a broken extension can never wedge the app), then the classic v2 Cocoa view protocol via a new headless-testable `AUViewProbe` in the engine, then the generic parameter view as the guaranteed floor. Proven live on both branches with system units: AUDelay and DLSMusicDevice open their real custom views — Apple Delay's tap-graph editor rendering inside our glass chrome at the vendor's own preferred size — while AUMatrixReverb (which ships no custom view) cleanly falls back to generic. Windows now follow vendor self-resizing with a reentrancy guard and stay clamped on-screen.
- Verified end to end: suite grew to 1518 tests in 184 suites (probe tests pin the CF memory contract against real units), npm stays 19/19 with the command/tool surface unchanged at 102/105, and the live gate passed on both the bare dev binary and the installed-style `dist/DAWPro.app` bundle identity. One honest gap recorded rather than papered over: no AUv3 exists on this machine, so the out-of-process AUv3 leg is skipped by necessity — the ladder's design guarantees graceful degradation if one ever misbehaves. With this, **M3 (MIDI & instruments) is fully complete**; every milestone M0–M9 is now done except items blocked on API keys or Apple Developer credentials.

## 2026-07-10 — M3 (vi-b-1): plugin windows are real — AU instruments and effects open in floating glass-chrome windows, driven from the UI or the wire
- The live, sounding `AUAudioUnit` instance now reaches a floating window: narrow main-actor accessors on the concrete engine (a documented one-off exception to the no-AudioToolbox-on-the-surface rule), a registry release callback as the single window-invalidation authority, and an `NSPanel` layer with dark-glass chrome (title, "Track · Manufacturer" subtitle, cyan key-accent — never violet) wrapping Apple's generic parameter view. Windows close themselves the moment their plugin leaves the model — effect removed, instrument switched, project opened — and deliberately survive engine crash-recovery, which never touches the plugin registry. This cycle ships the always-works generic body; vendor custom views (requestViewController / v2 Cocoa UI) are the next cycle.
- Fully agent-drivable: `plugin.openUI` (pin a window at exact screen coordinates, get the actual frame back for captures), `plugin.closeUI` (idempotent), `plugin.listOpenUIs` (honest `available:false` when headless) — 102 commands, 105 MCP tools. Suite grew to 1515 tests in 183 suites, including pins that the accessor returns the identical sounding instance and that recovery fires zero release callbacks. Both the implementing agent's gate (17698) and the orchestrator's independent gate (17695, 15/15) proved the full lifecycle live against DLSMusicDevice and AUDelay, including the auto-close-on-`fx.remove` proof with no close command issued. One real bug found during the gate and fixed: the transparent-titlebar panel's safe-area inset pushed the chrome's subtitle row out of its 34-point band — the header now ignores the safe area.

## 2026-07-10 — M9 (beta): one button turns a bug report into evidence — the beta feedback loop closes out M9's unblocked work
- A headless `DiagnosticsReporter` (DAWCore, injected directories + clock like the autosave manager) writes a single local folder — never a zip, never a network call — containing everything a bug report needs: app/OS/hardware manifest, the current engine watchdog + performance snapshots (the M9 telemetry paying off as evidence), a counts-only project overview, and copies of recent `DAWApp` crash logs (14-day window, newest 10). The full project bundle is included only on explicit opt-in, and nothing anywhere near the bundle reads key material — verified by scan on a live bundle. Reachable three ways: `app.feedbackBundle` on the wire (99 commands), `app_feedback_bundle` over MCP (102 tools — with guidance telling agents to ask before sharing project content), and a cyan "Beta Feedback" row in Settings that saves and reveals the folder in Finder.
- New `docs/BETA.md` tells testers how to install the DMG, what to expect on first launch (fresh prefs domain, mic permission, sidecar env var for installed copies), what's knowingly missing, how to report, and the privacy stance: everything stays on the Mac. Suite grew to 1492 tests in 180 suites; npm 19/19 at the new pins; the live gate created both bundle variants over the wire and inspected every file on disk. With this, every M9 item that can proceed without Apple Developer credentials is done.

## 2026-07-10 — M9 (pkg-d): DAW Pro ships as a disk image — scripts/dmg.sh builds the drag-to-install DMG
- One script on top of the bundle: `scripts/dmg.sh` rebuilds the app (idempotent), stages it beside an `/Applications` symlink in the standard drag-to-install layout, and produces a compressed `dist/DAWPro-0.1.0.dmg` with its SHA-256 printed for release notes. The version is read from the built bundle's own Info.plist, so bundle.sh stays the single source of truth.
- Verified as a real install, not just a file: mounted the image, copied the app out, confirmed the ad-hoc signature still verifies on the copy, launched the installed copy with the full control surface round-tripping, and quit it cleanly by name with the crash-recovery session lock removed. The gate also pinned a subtlety into the packaging docs: the song-generation sidecar's directory walk-up resolves from the process working directory too, so only a true Finder launch shows the pure installed-copy behavior. Cross-machine distribution still carries the Gatekeeper right-click-open caveat until real signing lands (credential-blocked pkg-b/c).

## 2026-07-10 — M9 (pkg-a): DAW Pro is a real Mac app now — scripts/bundle.sh builds an ad-hoc-signed, LaunchServices-registered DAWPro.app
- One script turns the release build into `dist/DAWPro.app`: proper Info.plist (bundle id `dev.dawpro.app`, version 0.1.0, minimum macOS 14, the microphone-permission string a bundled app needs for recording, music app category), ad-hoc code signature that verifies cleanly, and LaunchServices registration. The executable inside keeps its `DAWApp` name so every existing process-management and gate script keeps working, and the bundled binary still honors `DAW_CONTROL_PORT` — the full control surface (including the new crash-recovery and watchdog commands) round-trips through the bundle unchanged.
- The registration pays off immediately: `quit app "DAW Pro"` by name now drives a genuine AppKit termination — verified live, the crash-b session lock is removed on quit — giving orchestrated sessions their first clean programmatic exit (previously only SIGKILL/SIGTERM were scriptable, both of which correctly read as crashes). Known and documented rather than papered over: no icon yet (asset generation is key-blocked), Finder launches use a fresh preferences domain, a copied bundle needs `DAWPRO_ACESTEP_DIR` to find the song-generation sidecar, and Gatekeeper on other machines wants right-click-open until real signing (pkg-b/c, credential-blocked) lands. New docs/PACKAGING.md carries the details; Developer ID signing, notarization, and auto-update are recorded under ## Blocked with their exact unblock path.

## 2026-07-10 — M9 (crash-c): the engine can no longer die silently — a heartbeat watchdog detects render-side stalls and drives the proven recovery path
- A tick-driven watchdog now watches the render heartbeat (the lifetime callback counter from the performance telemetry — read with a single atomic load, never touching the render thread). If the heartbeat freezes for two consecutive 2-second checks while the engine claims to be running, the watchdog declares a stall and restarts the engine through the exact same recovery routine the system's configuration-change path has always used — extracted verbatim, not copied — so the playhead resumes where it was, the crash-a pending-detach bin still flushes, and the mix settings come back. Three consecutive failed recoveries put it in a sticky `failed` state rather than retry-thrashing; the next successful engine start re-arms it. One subtle catch during implementation improved the design: the watchdog only arms when the graph actually has strips producing telemetry — an empty running session has no heartbeat by physics, and would otherwise have restart-looped forever.
- The state is readable anytime as `engine.watchdogStatus` / `engine_watchdog_status` (98 commands / 101 tools): `ok` with an advancing heartbeat means healthy, `restartCount > 0` means the engine died and healed itself, `failed` means manual attention. The live gate showed the whole story on the wire: idle and zeroed before the engine exists, `ok` with the heartbeat climbing during playback, and still climbing after transport stop — the live-thru law, now visible to any MCP agent. Suite grew to 1479 tests in 178 suites, including a device-gated end-to-end restart test that ran live.

## 2026-07-10 — M9 (crash-b): the app can no longer lose work to a crash — rolling autosave, crash detection, and a recovery offer in-app and over the wire
- A headless `AutosaveManager` (DAWCore, injected directory + clock) keeps one rolling `autosave.dawproject` snapshot plus a manifest, written on a 30-second tick only when a new journaled edit has landed — encode on the main actor, file write off it, zero added latency on the edit path, and never touching the user's own file. A `session.lock` written at launch and removed only by a genuine in-app quit makes crash detection honest: SIGKILL and real crashes leave the lock, and the next launch offers recovery — in-app as a neutral-glass cyan sheet ("Restore unsaved work?"), and over the wire as `project.recoveryStatus` / `project.recover {accept}` with matching MCP tools (97 commands / 100 tools). Accepting restores the crashed content under its original IDs, kept dirty, with the source path preserved so the next save lands on the right file; declining, saving, opening, or starting a new project permanently retires the offer.
- The independent live gate (real 30-second timer, real SIGKILL, real relaunches) proved the happy paths — and caught two real bugs plus one false belief, all fixed with regression tests before close (suite 1458/174). The bugs: an unresolved offer could be silently overwritten by the live session's own next autosave (wire edits bypass the launch sheet; the writer now parks until the offer is resolved), and a resolved offer could re-arm later in the session once a fresh autosave landed (resolving now spends the crash-detection latch). The false belief: SIGTERM/pkill does *not* route through AppKit termination — it dies like a crash, which is in fact the safer reading, since nothing saves on the way down; the docs now state the verified behavior and orchestrator sessions quit via the quit Apple event or normalize stale offers at start.

## 2026-07-10 — M9 (crash-a): the teardown crash is dead — root-caused with a six-experiment live matrix, fixed with a pending-detach bin
- The long-parked killer (play a big routed session, open a new project, add a track → hard crash inside AVFoundation's graph bookkeeping) is fixed, and the root cause was proven rather than guessed: AVFoundation only completes a node detach's internal bookkeeping when it can synchronize with a running engine. Detach a node that has ever rendered while the engine is stopped and a stale raw pointer stays behind in the engine's internal node list — surviving reset and restart, immune to disconnect-first — until the next live connect walks it into freed memory. Our project-new teardown hit exactly that: the routing-safety hook stops the engine at the first strip with bus wiring, so the mass detach of a routed session ran against a stopped engine. The pivotal experiment inverted the original theory — stopping *before* all detaches (the by-the-book reading of the old discipline) still crashed, while running the entire 28-strip teardown against a live engine was clean. The discipline's stop, safe for rewires, was the poison for detaches.
- The fix is a pending-detach bin mirroring the codebase's retire-bin philosophy: teardown detaches now execute only against a running engine; requests arriving while stopped park the node — still attached, still strongly held, so no freed-memory window can exist — and flush in order right after the engine next starts. Offline renders and headless tests are byte-identical (their engines never ran). The same seam quietly covers three latent windows of the same class that a spot fix would have missed, and the architecture docs now carry the lifetime rule as law.
- Proven dead twice over: the implementing agent ran the full 41-track repro three times on the fixed build (previously crashed every time; five fresh crash reports were banked during diagnosis), and an independent gate ran three consecutive teardown cycles in a single process plus post-churn playback and undo checks — five for five, zero new crash reports. Suite grew to 1437 tests in 172 suites with four deterministic ordering pins standing guard where the live crash itself can't be reproduced headless.

## 2026-07-10 — M9 (perf-d): the performance counters are now exact under concurrency — and the fix turned the telemetry into a glitch detector
- The render-load counters switched from read-then-write increments to true atomic fetch-adds (plus a bounded compare-and-swap maximum for the peak-callback cell) — still lock-free, still allocation-free, still a single instruction on Apple Silicon, and now provably exact no matter how many threads feed them. The regression test spawns eight threads hammering 160,000 recordings and demands bit-exact totals; the implementing agent went further and temporarily reverted the fix to show the old code drops 45% of counts under that load, then restored it. The invariants section in ARCHITECTURE.md now blesses "multi-producer accumulator" as the third sanctioned pattern for crossing data out of the render thread.
- The fix promptly earned its keep by correcting our own story: re-running the 16-track debug-build experiment with trustworthy counters produced the same "low" callback rate as before — meaning those missing callbacks were never counting errors but real dropped audio cycles (a debug build genuinely can't render 16 dense synths inside the hardware deadline, and CoreAudio skips late cycles). Pure live playback turns out to be single-threaded after all; the real concurrency the counters needed to survive is a live graph and an offline bounce running at once, which the earlier profiling had directly observed. Both research docs were corrected accordingly.
- Net effect: comparing the measured callback rate against blocks × device rate is now an honest, wire-visible saturation detector — if it reads low, the engine is audibly glitching, full stop. Release builds pass that check at every scale tested. Suite grew to 1433 tests; the release build re-profiled identically after the change (no cost to the hot path); MCP surface untouched.

## 2026-07-10 — M9 (perf-c): the load-profiling pass — the engine has massive headroom, and the measurement found two real bugs anyway
- The verdict from driving a 41-track synthetic monster over the wire (37 dense saw synths with full FX-preset chains, three FX buses fed by sends from every track, and 128 automation points per synth): on a release build the whole engine uses about 14% of one CPU core, the slowest single render callback stayed under 1% of its real-time budget, not one budget overrun fired, and a 30-second offline mixdown rendered in 1.3 seconds — nearly 23× faster than realtime. There is no DSP hotspot to optimize at this scale; these numbers are now the documented regression baseline. The sharpest practical lesson: the same session on a debug build reads ~28× slower per block and bounces at a third of realtime — all future performance measurement happens on release builds, no exceptions.
- The pass earned its keep by finding two real defects, neither in the audio math. First, the brand-new telemetry undercounts under load: AVAudioEngine renders independent tracks on a thread pool, so the counter design's single-writer assumption loses increments when callbacks overlap — provable on debug at 16 tracks, where the counters reported 43% of the true callback rate while the vibe-meter analysis proved every track was sounding. That fix (a proper atomic fetch-add) is split out as its own roadmap item. Second, the long-parked teardown crash finally reproduced with a complete symbolicated stack: play a big routed session, open a new project, add a track — crash inside AVFoundation's graph bookkeeping on a stale node pointer. The exact wire repro and analysis leads are written up for the crash-safety work.
- Also documented for every future harness: the expected-callback-rate arithmetic that catches undercounting (blocks × the output device's pull rate — the device's 44.1 kHz, not the graph's 48), the fact that instrument tracks render their FX chains inline (one telemetry block per synth track), and that offline renders pull 4096-frame slices. Docs-only change to the repo; verified by the campaign itself (three harness scripts, both build configurations, cross-checked against the tap-based master analysis, which is immune to the counter race).

## 2026-07-10 — M9 (perf-b): the engine can now report its own render load — telemetry lands as `engine.performanceStats`
- Every render callback in both of the engine's real-time workhorses — the instrument source nodes and the per-strip effect-chain hosts — now stamps its wall-clock cost into a preallocated block of lock-free atomic counters, giving the DAW (and any AI agent over MCP) a live answer to "how hard is the audio engine working": callback and frame counts, accumulated and peak render time, budget-overrun count, an average load over the window, and a ~1-second "load right now" figure. The chain-host stamp starts only after upstream audio has been pulled, so nested renders are never double-counted, and offline bounces feed the same counters — headless profiling works without ever opening the app.
- The instrumentation is the first new engine code written under the RT-safety invariants that (perf-a) codified, and it conforms exactly: one heap allocation, integer-only math on the render thread (plus a single guarded floating-point smoothing step), release/acquire publishing, and no allocation, locks, or trapping division anywhere in the hot path. One new sanctioned exception was added to the invariants list for its single-writer counter pattern. Reset is windowed for profiling: asking for stats with reset returns the closing window and starts a fresh one, and the two windows tile exactly — the seam (perf-c)'s load-profiling pass will read before and after every experiment.
- Surfaced end to end as the first `engine.*` control command plus a matching `engine_performance_stats` MCP tool, with sixteen new tests including a headless end-to-end proof (a one-second offline render produces exactly the expected callback and frame counts). Verified independently: build clean, suite grew to 1432 tests in 171 suites, MCP tests all green at 95 commands / 98 tools, and a live wire session watched real playback push the counters — about 7% average load on an eight-track pop session — then exercised reset windowing and confirmed sane behavior after stopping. Next: (perf-c) — drive a deliberately heavy session over the wire and use this telemetry to find and fix the hotspots.

## 2026-07-10 — M9 (perf-a): the render thread comes back clean — 47 sites audited, zero violations
- M9 opens with proof of the discipline the engine was built under: a line-level audit of every site that executes on or feeds the real-time audio path — render callbacks for all five instruments and nine built-in effects, AU hosting adapters, the PDC ring, automation, every tap closure, the CoreMIDI receive path, the vibe meter's analyzer, stretch bridging, the recording writer, and all seven atomics patterns. Verdict: zero violations. Nothing on the render thread allocates, locks, hops actors, or touches files; the atomics carry correct memory orderings throughout.
- The audit leaves two durable artifacts: a findings document with a per-site verdict table (including six "watch" items that are sound today but fragile if copied carelessly — one is a dead graph-teardown function that would recreate an old segfault class if ever wired live), and a new RT-safety invariants section in ARCHITECTURE.md codifying the two-tier rules, the two sanctioned patterns for crossing state into the render thread, and the complete four-item exception list. Future engine work gets reviewed against that section. It also recorded a concrete lead for the parked teardown crash (a deinit ordering that leans entirely on an AVFoundation guarantee) for the upcoming crash-safety work.
- Docs-only change: build clean, suite holds at exactly 1416 tests in 168 suites, and the findings were spot-checked against code from earlier cycles. Next: (perf-b) — RT-safe render-load and xrun telemetry surfaced as an engine.performanceStats command and MCP tool, the measurement seam the actual profiling passes will read.

## 2026-07-10 — M8 (ob-c): the first-song gate passes for real — onboarding is COMPLETE
- The whole promise, proven live on a fresh profile with zero staged shortcuts on the task steps: the tour offered itself on first launch, the local ACE-Step engine cold-booted and generated a real 30-second lo-fi song from the tour's own suggested prompt, the import advanced the tour, and then playing, nudging the tempo, moving a fader, and bouncing the finished mix each advanced exactly their own step — ending with an 11.8 MB WAV on disk and a "completed" state that survived killing and relaunching the app without re-offering the tour. Sixteen of sixteen checks passed, on the full generation path (the template fallback was never needed).
- That closes the "Onboarding: first-song-in-10-minutes guided flow" roadmap item — design, headless model, guided UI, and live gate all landed and independently verified. M8 is now complete except its two key-blocked gates (GPT-Image assets and the explain-to-copilot live conversation), which wait on API keys alongside the other parked items. Next: M9 — performance, stability, and release engineering.

## 2026-07-10 — M8 (ob-b): the guided tour is on screen — coach-mark cards, real-deed detection, and two new buttons
- The first-song tour now greets you: on a fresh profile a centered glass card offers "Your First Song," and each task step then anchors beside the actual control it teaches — a glowing cyan ring around Play, around a fader, around the Sketchpad — flipping out of the way near screen edges and never covering what it points at. The chrome is deliberately non-violet (this is product guidance, not AI; cyan is the only accent), progress reads as seven dots plus a plain count, and Skip step / Skip tour are always one quiet click away. Finished or dismissed tours never nag again; Settings gains a "Replay tour" row.
- The tour advances on real accomplishments, detected app-side by an observing adapter rather than scattered button hooks: the store now publishes a tiny edit event (with the undo journal's own label and key) and a render-completion counter, and a tested classifier sorts edits so a fader move reads as mixing while a mute, clip drag, or tempo nudge reads as shaping — the two steps can never collapse into each other. Because the adapter watches the store, actions arriving over the control wire count exactly like clicks, which the verification proved by walking the entire tour over WebSocket with zero staged signals: template applied, play pressed, tempo nudged, fader moved, one-second bounce rendered — each advancing its own step and nothing else's.
- Two controls the flow needed now exist: an EXPORT button in the transport bar (save panel, then a real bounce — present in both Simple and Pro, with the readout anchor and PUNCH untouched) and a neutral "USE A TEMPLATE" button under the Sketchpad's GENERATE for the instant, keyless path. Both ship with Explain cards (catalog now 46). Verified independently: build clean, suite grew to 1416 tests in 168 suites, all six captures pixel-reviewed, the staging command stays off the public wire, and sixteen of sixteen wire checks passed. Next: (ob-c) the live first-song gate on a fresh profile — then M8 is done except its key-blocked gates.

## 2026-07-10 — M8 (ob-a): the first-song tour gets its brain — onboarding flow designed, modeled, and tested
- The "first song in ten minutes" guided tour now exists as a complete design plus a fully tested headless state machine. The script is seven steps — welcome, generate, listen, shape, mix, export, done — walking a brand-new user from an empty project to a bounced song, and it works without any cloud API key: the generative step rides the local ACE-Step Sketchpad with an instant song-template fallback for the impatient or the offline.
- The tour advances itself by listening for real accomplishments, not clicks: the app will emit typed signals (project gained content, playback started, an edit landed, the mixer moved, a render finished) and the model advances only when the active step's expected signal arrives — with manual advance and skip always available so a missed signal never traps anyone. Progress persists across relaunch, finished or dismissed tours never nag again, and a Settings replay seam is built in. The design doc pins the exact file-and-line wiring sites for every signal, including the rule that keeps the shape and mix steps from collapsing into each other, and honestly flags the two controls that don't exist yet (an export button and a template button — next cycle's work).
- Verified independently: build clean, suite grew to 1401 tests in 166 suites (34 new tests cover the full walk-through, every no-op guard, persistence round-trips, and the same copy style rules the explain cards obey), zero engine/control/MCP surface changes, and the wiring map's claims spot-checked against the real code. One catch during review: the listen step's copy pointed users at the top of the screen for the Vibe Meter, which lives in the bottom transport bar — fixed. Next: (ob-b) the guided UI itself — glass step cards, coach-mark anchoring, signal wiring, and the two missing buttons.

## 2026-07-10 — M8 (vm-b): the glowing instrument — the session vibe meter is alive in the transport bar
- The signature visualization has landed: a small glowing ember orb now lives left of the master cluster, and its shape IS the mix. The 24 analysis bands from vm-a become the orb's silhouette — a bass-heavy mix bulges warm and low, a bright mix flares cool and high — while the spectral centroid slides its color along a warm-amber-to-cyan ramp, the mix level drives how hard the core glows, and spectral flux sets how much it shimmers. Silence is a dim ember, not a black hole. It renders on a 60 fps Canvas, shows in both Simple and Pro transport modes (it's information, not an edit control), and by construction never turns violet — that color stays reserved for AI, and a test sweeps the entire color ramp to prove it.
- All the perceptual mapping lives in a headless, tested model: log-frequency hue placement, dB-to-brightness curves, and asymmetric attack/release smoothing (fast in, slow out) so the orb breathes with the music instead of jittering. Twelve new tests pin dormancy at exact floors, mid-spectrum hue at 1 kHz, curve monotonicity, and the no-violet invariant. A debug-tier seed command stages deterministic captures without touching the engine, and the meter ships with its own "Explain this" card — hover it in explain mode and the app tells you what the glow means.
- Verified independently: build clean, suite grew to 1367 tests in 165 suites, six captures pixel-reviewed (four unmistakably distinct states including real playback rendering a green-teal mid-spectrum orb), four live wire checks on the seed command including its error path, and isolation checks confirming the engine, control protocol, and MCP surface are untouched. With both halves landed, the Session vibe meter roadmap item is COMPLETE. Next: the onboarding first-song-in-10-minutes guided flow — the last unchecked non-key-blocked M8 item.

## 2026-07-10 — M8 (vm-a): the vibe meter gets its ears — real-time spectral analysis of the master mix, on the wire
- The session vibe meter's data source is live: a DSP analyzer now rides the master bus tap, computing 24 log-spaced spectral bands (40 Hz to 16 kHz), short-term level, held peak, spectral centroid (how bright the mix is), and spectral flux (how much the energy is moving) at roughly 46 snapshots a second. It analyzes post-master-fader — what you hear is what it measures — and it is real-time-disciplined throughout: FFT buffers, windows, and band tables are preallocated at init, and the audio-adjacent tap path allocates nothing but the published snapshot value.
- Everything is finite by contract. Silence and stopped transports decay smoothly to an exact −80 dB floor (the peak takes ~5 seconds by design, releasing at −20 dB/s), poisoned input frames are skipped whole, and the wire never sees a NaN. Agents get the same view humans will: a new `mixer.masterAnalysis` command and `mixer_master_analysis` MCP tool return the snapshot on demand — an AI can now ask whether the mix is bright, dense, or peaking without rendering a file. Real LUFS measurement stays with `render.measureLoudness`; this is the fast, always-on view.
- Verified independently: build clean, suite grew to 1355 tests in 164 suites (thirteen DSP tests pin the analyzer against known signals — a 1 kHz sine lands in the right band with the right centroid and RMS — plus chunk-size invariance and stereo down-mix parity), npm audit green at 94 commands / 97 tools, and a live wire pass watched the centroid track an arpeggio in real time before decaying back to exact floors. Next: (vm-b) — the glowing instrument itself, the signature visualization this data feeds.

## 2026-07-10 — M8 (ex-b): "Explain this" goes app-wide — 43 curated cards across every surface, anchored per-instance
- The explain catalog doubled from 21 to 43 entries and the violet "?" mode now covers the whole app: every mixer strip (channels, buses, and the master), the piano roll's grid, velocity lane, and snap, the arrange sidebar's track rows and add-track button, clips in the timeline, all three AI panels (Sketchpad with its Lyrics workshop, the Copilot rail, FIX WITH AI), and Settings — where the API-key card explains what a key unlocks and that it lives in the Mac's Keychain, without ever showing a key value.
- The load-bearing fix was per-instance anchoring: ex-a could only tag the first mixer strip because repeated controls sharing one ID collided on a single stored frame. Now a hovered control reports its own frame at hover time, so sliding from one strip's fader to the next re-anchors the card on the strip under the pointer; the old ID-keyed frame table survives only as capture staging, where a new instance selector on the debug command lets a capture prove the card lands on strip three, not strip one. Shared controls got shared copy — one "Simple / Pro" entry now serves the density chip on all four panels.
- Four labeled deviations, all reviewed sound: the shared density ID rename, the debug-tier instance selector (pre-authorized), one honest-scope entry each for Canvas-internal clip and note-grid affordances rather than fake per-grip tags, and hoisting the explain scope so cards float above the Settings modal. Verified independently: build clean, suite grew to 1339 tests in 162 suites with a count-floor test pinning the catalog against silent shrink, all five captures pixel-reviewed (violet exclusive to AI affordances throughout), and eleven wire checks passed including the renamed ID correctly erroring. Next: the parent item waits only on (ex-c), the key-blocked live hand-off gate; the cycle after picks up the session vibe meter.

## 2026-07-10 — M8 (ex-a): "Explain this" lands — a violet ? chip that makes every control self-describing, with a hand-off to the Copilot
- A violet EXPLAIN chip now sits in the app header beside COPILOT and SKETCHPAD. Toggle it and the app enters explain mode: hover any registered control and a violet-edged glass card appears with plain-language curated copy — what the control does and when you'd reach for it — plus an "Ask the Copilot →" button that closes explain mode, opens the rail, and prefills a question about that control as a draft (never auto-sent, so it works with or without an API key; the live conversation gate is ex-c, key-blocked). Explain mode is an overlay, not a lockout — the controls underneath keep working — and Esc exits, with the Esc handler mounted only while the mode is active.
- The copy lives in a headless 21-entry catalog in DAWAppKit covering the two reference surfaces (all twelve transport-bar controls and a mixer strip's nine), with tested style rules: titles cap at 24 characters, bodies run 40–280 characters ending in real punctuation, and no dB/Hz jargon appears without a plain-language gloss. Two labeled deviations, both verified sound: the hand-off routes through an AppModel draft property because the copilot engine deliberately has no draft API (its turn loop is untouched), and only the first mixer strip is tagged since identical IDs on every strip would collide frames — the ex-b rollout generalizes that.
- Verified independently: build clean, suite grew to 1338 tests in 162 suites (+10 catalog/state tests), all four captures pixel-reviewed (violet stays exclusive to the AI affordances per the design language's Rule 3), the debug staging command round-tripped live on the staging port — six checks including the unknown-focus error path — and grep confirms the explain surface exists nowhere in the control protocol or MCP server, exactly as designed. Next: ex-b rolls `.explainable` coverage across every remaining surface.

## 2026-07-10 — M8 (sp-d): Simple ↔ Pro rollout COMPLETE — the transport splits, and every panel now has an honest density story
- The last conversion is deliberately the smallest: in Simple, the transport bar hides exactly two things — the PUNCH chip (an advanced record window) and the test-tone verify button (a diagnostic) — while play, loop, click, tempo, the readouts, and the master all stay. One geometric subtlety got a labeled deviation: the leading control group is pinned to a fixed width so the Position/Time/Tempo readouts (the bar's visual anchor) sit at pixel-identical x in both modes while the chip row still closes up naturally. The agent caught its own first attempt truncating PUNCH at a narrower pin and re-captured at the right width.
- With sp-d, the parent roadmap item closes: density coverage is uniform across the app. Four surfaces carry live SIMPLE/PRO chips (piano roll, mixer, arrange, transport); the other nine were audited as already-Simple and are now formally documented as coincident-exempt — with the design language codifying the principle that a panel whose modes coincide must never grow a do-nothing toggle, because a toggle that changes nothing is worse than none.
- Verified independently: build 0 warnings, suite 1328/161 held, capture pair pixel-reviewed (readout anchor confirmed by overlay comparison), and UserDefaults now carries four independent panel keys with mixed values — the per-panel model working exactly as designed. Next: M8's "Explain this" AI affordance on hover.

## 2026-07-10 — M8 (sp-c): the arrange workspace learns Simple mode — move clips on a bar grid, nothing sharp to grab
- In Simple, arranging is exactly three verbs: see clips, drag them (on a grid locked to whole bars), play. The snap picker, edge-trim strips, corner fade grips, per-clip gain chip, double-click split, and ⌥ time-stretch all belong to Pro now — and the suppression is honest at the gesture layer, not just cosmetic: SwiftUI gesture masks drop the Pro recognizers, and the drag-zone classifier collapses every press to "body" in Simple, so grabbing a clip's edge moves it instead of dead-air no-oping where a trim strip used to be. The context menu follows suit (clip edits Pro-only; take-group entries stay in both modes, since take lanes keep their own verdict).
- Read-only status stays visible in both modes by design — a stretched clip's ratio badge, the render shimmer, error dots: a beginner should see what state a clip is in even when they can't initiate the edit. The Bar-lock is a tested DAWAppKit unit (`ClipSnap.effective`) that never mutates the picked resolution, so flipping back to Pro restores your snap choice — the same courtesy the piano roll established.
- Verified independently: build 0 warnings, suite grew to 1328/161, all three captures pixel-reviewed (the same selected clip reads as a plain block in Simple and shows its fade wedges and −3.5 dB chip in Pro), every gated gesture entry point code-reviewed, and UserDefaults now holds three independent panel keys — arrange, mixer, and piano roll each remembering their own density. Next: sp-d closes the Simple↔Pro rollout (the minor transport split + documenting the nine modes-coincide verdicts).

## 2026-07-10 — M8 (sp-b): the mixer console learns Simple mode — level, pan, mute/solo, and a longer fader
- The densest surface in the app now honors the beginner rule. In Simple mode every channel strip reduces to what a newcomer actually reaches for — name and kind badge, pan, the fader beside its meter and dB readout, and Mute/Solo/Arm — while Pro reveals the signal-flow sections: inserts, sends, and output routing. The vertical space freed in Simple flows into a visibly longer fader throw, so the beginner mode isn't just fewer controls, it's finer level control. Bus strips gate the same three sections and keep their per-kind differences; the master strip is exempt (it was already its own Simple mode) and renders pixel-identically in both.
- The whole console is one panel on the sp-a foundation: the shared SIMPLE/PRO chip sits in the Mix toolbar's top-right (the position SNAP occupies in Arrange), bound to panel ID "mixer" on the same sticky store. No new commands, no new tests needed — the gating is a pure view-conditional over the already-tested store, and sp-a's `debug.panelDensity` staged every capture.
- Verified independently: build 0 warnings, suite 1327/161 held, three captures pixel-reviewed (a staged session with real inserts, a send, and a bus so Pro had content to hide), and the piano-roll regression shot doubled as a live independence proof — mixer at Pro and piano roll at Simple simultaneously, each persisted under its own key. Next: sp-c, the arrange workspace's Simple mode.

## 2026-07-10 — M8 (sp-a): Simple ↔ Pro gets a real foundation — 13-surface inventory, per-panel density store, one shared toggle
- The "every panel" mandate now rests on evidence instead of vibes: a 13-surface inventory (`docs/research/simple-pro-inventory.md`) classified the app — the piano roll already carries the pattern; the mixer channel strip, the arrange workspace, and (minorly) the transport genuinely need modes; and nine surfaces already ARE their Simple mode (master strip, track rows, automation, takes, clip-fix, sketchpad, lyrics, copilot, settings), so they get documented as coincident rather than burdened with a do-nothing toggle. The rollout is split accordingly: sp-b mixer, sp-c arrange, sp-d transport + the coincide verdicts.
- The mechanism is shared and headless: `PanelDensity`/`PanelDensityStore` in DAWAppKit (@Observable, per-panel — a beginner may want a Pro piano roll but a Simple mixer; persistence through an injected backing seam, with a UserDefaults adapter keying `panelDensity.<panelID>`, nine hermetic tests), and a `SimpleProToggle` chip component extracted verbatim from the piano roll's toggle. Density is an app-side sticky preference — it survives relaunch and is never written into the project file — now codified in DESIGN-LANGUAGE.md.
- The piano roll was refit onto the shared pieces with exactly one behavior change: the mode now sticks across reopen and relaunch. A `debug.panelDensity` staging command (debug tier — off allCommands, no MCP tool) lets captures and E2E stage either mode over the wire. Verified independently: build 0 warnings, suite grew 1318/160 → 1327/161, both mode captures pixel-reviewed (the Simple↔Pro delta is exactly the snap picker and velocity lane), wire round-trip of both happy and both error paths, and an on-disk persistence proof. Next: sp-b, the mixer console's Simple mode.

## 2026-07-10 — M8 (glass-c): the audit's follow-ups land — measured contrast, honest accents, one grid
- The three deferred findings from the glass-a audit are done. The create "+" affordances (add-track, add-insert, add-send) dropped cyan for neutral chrome — Rule 3 reserves cyan for playback/activity, and the design language now codifies the principle: an accent is earned by state, not by inviting a click. The Sketchpad's ± length stepper keeps its cyan, correctly, as a numeric-readout control.
- The contrast pass was measured, not eyeballed: WCAG relative luminance with `.opacity()` blends alpha-composited over the actual surfaces (math kept in scratchpad/contrast.py). Plain `textDim` proved already compliant (5.51–6.30:1) and was left untouched; the real offenders were nine ad-hoc opacity blends, now retargeted to two new tokens — `textSecondary` (real labels, "No inserts"/"No sends" went 3.39→6.71:1) and `textFaint` (placeholders/decorative, worst case 2.84→4.18:1 against a 3.0 floor). The four-tier text hierarchy is codified in DESIGN-LANGUAGE.md with a ban on dimming real labels below 4.5:1 via ad-hoc opacity.
- Three near-duplicate grid-emphasis literals collapsed into `DAWTheme.gridEmphasis` (white @ 0.14) — the piano roll and keyboard sidebar shifted by 0.02 each and all grids now read at the timeline's strength. Verified independently: build 0 warnings, suite 1318/160 held, before/after captures reviewed at the pixel level. M8 next: Simple ↔ Pro progressive disclosure on every panel.

## 2026-07-10 — M8 begins: the glass-cockpit compliance audit — the design language holds, two breaks fixed
- First M8 item (glass-a): an evidence-based sweep of all ten shipped surfaces against DESIGN-LANGUAGE.md — full code sweep of the view layer plus eleven headless captures (app driven over the control wire on port 17695), each viewed by the auditor. Verdict: the cockpit is real — essentially all color routes through `DAWTheme`, every numeric readout is SF Mono, glow encodes state only, and violet stays strictly AI. Findings archived at `docs/research/design-audit-glass-a.md` with per-surface verdicts and file:line evidence.
- Two hard rule breaks found and fixed: the arrange sidebar's Mute chip lit amber (colliding with the Arm chip and mis-signalling "record" — the doc mandates Mute = red, and the mixer already complied), now red; and the piano-roll keyboard drew from the view layer's last raw hex literals, now the `DAWTheme.keyBlack`/`keyWhite` tokens (zero visual change). Three restyle-sized follow-ups (cyan "+" affordance semantics, an app-wide dim-text contrast pass, grid-hairline token unification) were deferred honestly as (glass-c) rather than half-fixed.
- Verified independently: build 0 warnings, suite 1318/160 held exactly, before/after captures reviewed at the pixel level. The GPT-Image asset half (glass-b) is parked under ## Blocked on the absent OPENAI_API_KEY. Next: Simple ↔ Pro progressive disclosure on every panel.

## 2026-07-10 — M7 COMPLETE: the MCP integration suite drives the real wire — and fixes what the demo found
- `mcp-server/test/integration.test.ts` (12 tests, now part of `npm test` alongside the 7-check audit) exercises the REAL transport end-to-end: it spawns the actual DAWApp binary headless on port 17690 and a real MCP SDK client over stdio, so every assertion crosses client → stdio → mcp-server → control WebSocket → app. Coverage includes the composition macros' first real-MCP exercise (skeleton scaffold, preset chain, seeded humanize determinism), the one-`edit_undo` scaffold revert, `project_overview`'s size bound, verbatim error surfaces, and a re-measured `render_bounce`. Missing app binary skips the file with an actionable message — never a silent pass; teardown is SIGTERM→SIGKILL in try/finally, and `pgrep DAWApp` stays empty after every outcome.
- The suite opened by fixing the two live mcp-server bugs yesterday's E2E demo exposed, each pinned by a regression test: void-result tools (`track_set_volume`, `transport_play`, …) now return the literal `"ok"` instead of an invalid `JSON.stringify(undefined)` content item that made clients reject with `-32602` despite the command executing; and the bridge now gives render-family commands a 180 s per-command timeout (`LONG_RUNNING_COMMANDS`) instead of the flat 5 s that silently discarded the loudness report of any full-length render (the regression proves a 6.2 s measure that used to die now survives).
- Verified independently: `npm test` **19/19 in ~11.4 s** (audit intact at 7/7), Swift baseline untouched at **1318 tests / 160 suites**, both fixes surgical single-site diffs, no stray processes. Notably the suite passed 19/19 on its very first run — the implementing agent spent its time reading the real tool schemas and Swift handlers instead of debugging afterward. **With this, every M7 item is done: the MCP surface is enforced-complete (96 tools), agent-ergonomic (overview + macros), demo-proven (a real agent shipped a track over it), and now regression-guarded on the real wire. Next milestone: M8 — design & simplicity polish.**

## 2026-07-10 — M7: the E2E demo — an AI agent composed, arranged, and mixed a track entirely over MCP, zero clicks
- The milestone's proof-of-concept is real: a delegated Claude agent, given only the `mcp__daw-pro__*` tool surface, produced a 24-bar moody synthwave piece at 104 BPM (Am–F–C–G, 464 notes across Bass/Chords/Lead/Pulse polySynth tracks) with a genuine arrangement (Chords enter bar 5, Lead exists only bars 9–20, Pulse sits out the outro), a deliberate mix (staged volumes/pans, compressor on Bass, chorus on Chords, a "Space" reverb bus fed by post-fader sends from Chords + Lead, and a 4-point volume-automation fade over the outro), live-meter playback proof, and a −14 LUFS bounce — ≈52 MCP tool calls, zero UI clicks, zero files written by the agent. Artifacts: `~/Library/Application Support/DAWPro/Generations/demo-m7-agent-e2e/` (demo-track.wav 57.4 s + demo-track.dawproj).
- Verified independently by the orchestrator: saved project structure matches the brief on every axis; the WAV's sample peak is exactly −1.000 dBFS (the true-peak ceiling clamp landing precisely where the render_bounce contract says); a fresh wire measurement reproduced the agent's main-section loudness verbatim (−19.19 LUFS / −6.04 dBTP, exact match); an independent play + snapshot showed the intro metering with Lead correctly silent.
- The demo doubled as a live audit of the MCP surface and found two real mcp-server bugs, queued for the MCP-integration-suite cycle: void-result tools (track_set_volume, transport_play, …) serialize `JSON.stringify(undefined)` into an invalid content item (client sees `-32602` though the command executed), and the bridge's flat 5 s request timeout eats render_bounce/measureLoudness replies on full-length renders (~25 s) even though the file lands. Also noted: the session ran against a stale MCP server process predating the macros — the agent composed everything the long way, which arguably strengthens the demo.

## 2026-07-10 — M7: the composition-macro trio completes — macro.songSkeleton scaffolds a session in one call
- `macro.songSkeleton` (MCP: `macro_song_skeleton`, tool #96) turns "start a pop song at 120" into a working session: tempo set, a genre-appropriate track roster added with mixer presets pre-applied (bass-tight on Bass, vocal-presence on Vocals, warm-keys where it fits — macro-b composed into macro-c, with a catalog-integrity test validating every cross-reference), the song's sections laid out as contiguous named empty MIDI clips on an "Arrangement" guide track, and the loop region set over the whole arrangement. Five genres ship (pop, house, hip-hop, rock, ballad), each with sensible default tempo and section plan; custom tempo and sections override cleanly. Additive by design — it never wipes the current project.
- The item's hardest guarantee — the entire scaffold as exactly ONE undo step — produced a documented store finding: `performEdit` journals one entry per call and only coalesces same-key entries within 800 ms, so composing store methods naively would fragment undo. The scaffold instead folds every mutation into a single performEdit body using the no-edit helper pattern (`applyTempoChange`, new `applyLoopRegion`), proven in both the DAWCore suite (undo-stack depth) and through the wire (one `edit.undo` restores the prior project exactly).
- Verified independently: build 0 warnings, **1318 tests in 160 suites** (+22, +2); parity audit 7/7 with the bijection at 93 commands + 3 = 96 tools; live app round-trip **10/10** — scaffolded pop onto a non-empty project (additive confirmed), the bass-tight chain landed on Bass, eight empty guide clips with Outro at beat 192 and loop to 208, one undo left exactly the pre-existing track, custom sections overrode defaults, and both error contracts held. With all three macros done, the composition-macros roadmap item closes; next M7 item: the end-to-end agent demo.

## 2026-07-10 — M7: one command to a mixed strip — mixer.applyPreset lands with a six-preset catalog
- `mixer.applyPreset` (MCP: `mixer_apply_preset`, tool #95) applies a named preset from the static, versioned `MixerPresetCatalog.v1` to any strip — audio, instrument, or bus. The preset's chain replaces the strip's inserts wholesale as one undoable edit (undo restores the exact prior chain, ids and order included); volume, pan, and sends stay untouched because presets are tone, not balance. Six presets ship, built only from the built-in FX pack: drum-bus-glue, vocal-presence, bass-tight, master-glue (compressor into limiter with a −1 dB ceiling), warm-keys, and clean-boost (+3 dB gain). Each apply mints fresh effect ids so two strips holding the same preset stay independently addressable. One documented mapping note: the built-in EQ has no dedicated high-pass, so "rumble trim" intents use a negative low-shelf — the closest available shape.
- Discoverability is structural: the MCP tool's `preset` param is an enum with every option described, and the unknown-preset error lists all six valid names. Catalog fidelity is tested by applying every preset and asserting the resulting params exactly — presets are pinned contracts, not vibes.
- Verified independently: build 0 warnings, **1296 tests in 158 suites** (+18, +2); parity audit 7/7 with the bijection at 92 commands + 3 = 95 tools; live app round-trip **8/8** — vocal-presence replaced a pre-existing gain effect with EQ→compressor at exact catalog values, undo brought the old chain back, clean-boost's linear gain matched 10^(3/20) to nine decimals, and master-glue landed compressor→limiter on a bus. Next: (macro-c) macro.songSkeleton completes the composition-macro trio.

## 2026-07-10 — M7: the first composition macro — clip.humanize gives MIDI a reproducible human feel
- `clip.humanize` (MCP: `clip_humanize`, tool #94) applies seeded, deterministic jitter to a MIDI clip: each note's onset shifts by an independent uniform amount within ±`timingBeats` (clamped strictly inside the clip) and each velocity within ±`velocityRange` (clamped 1–127), with lengths, ids, and order untouched — one undoable "Humanize" step. The response merges `seedUsed` into the clip payload: replay it to get the identical take, omit `seed` to re-roll. Drawn seeds stay under 2^53 so they round-trip the JSON wire exactly. Determinism comes from a small splitmix64 generator in DAWCore, since Swift's system RNG can't be seeded.
- Review caught a real gap before close: the agent's first pass skipped the `requireNotCompMember` guard that protects every other note-mutation site (comp members are store-managed — quantize rejects them explicitly). The premise was verified in the store code, the deviation bounced, and the guard + a regression test (comp member → `clipInTakeGroup`, notes byte-identical after) landed the same cycle. One behavior note for agents: a zero-jitter call changes nothing and therefore journals nothing (the app-wide performEdit convention) — don't pair it with an undo.
- Verified independently: build 0 warnings, **1278 tests in 156 suites** (+15, +2); parity audit 7/7 with the bijection at 91 commands + 3 = 94 tools; and a 10/10 live app round-trip — seed 42 echoed and reproduced identical notes through the wire twice, velocities pinned to both rails under max range, onsets stayed in bounds, the no-op round-tripped bit-identically, and out-of-range params rejected by field name. Next: (macro-b) mixer.applyPreset.

## 2026-07-10 — M7: agents get a cheap map of the session — project.overview lands
- `project.overview` (MCP: `project_overview`, tool #93) answers "what's in this session and what ids do I act on" in a fraction of `project.snapshot`'s tokens: a `ProjectOverview` Codable projection in DAWCore surfaces transport, master, and per-track state (routing, sends, fx names, clips, automation) with full actionable UUIDs — but counts instead of lists wherever a list can grow unbounded. MIDI clips report `noteCount`, automation lanes report `pointCount`, and file paths never appear. Optional fields are omitted rather than null; instrument tracks resolve a nil instrument to the default synth's display name the same way project.snapshot always has.
- Token efficiency is a tested contract, not an intention: a DAWCore test builds a dense synthetic project (8 tracks, 24 clips, 64-note MIDI clips, 60-point automation lanes) and asserts the overview encodes under 8 KB and at least 5× smaller than the full snapshot — measured 6,537 vs 84,731 bytes, a 12.96× reduction. One disclosed v0 seam: `sends[].preFader` is a documented constant `false` because the send model is post-fader-only today; the field exists so the shape stays stable when pre-fader sends land.
- Verified independently: build 0 warnings, **1263 tests in 154 suites** (+6, +1); the iteration-79 parity audit passed 7/7 with the bijection auto-adjusting to 90 commands + 3 = 93 tools — the enforcement carried this item's MCP correctness for free, exactly as designed; and a live app round-trip scored 8/8 (tempo/mute surfaced, noteCount with zero note leakage, the track id from track.add comes back verbatim and actionable, no path leaks, and the overview is smaller than the snapshot even on a 3-track session). Next M7 item: composition macros.

## 2026-07-10 — M7 opens: MCP↔command parity and schema richness are now machine-enforced
- The first M7 box closes with a twist: the scoping inventory showed every one of the 89 control commands already had an MCP tool (the "gaps" were naming-convention artifacts — six generation tools historically drop the `ai_` prefix, and three tools are direct-API by design). What was missing was enforcement, so that's what shipped: `mcp-server/test/audit-tools.test.ts` boots the real server on an in-memory transport, lists tools the same way a client would, parses `Command.allCommands` straight out of `Commands.swift`, and asserts the bijection (both exception tables explicit) plus richness — every tool titled with a beginner-readable ≥40-char description and every input property recursively described. `npm test` runs it cold; no new dependencies.
- Enabling refactor: `src/index.ts` shrank from 3870 to 30 lines (stdio entry only) and all 92 `registerTool` calls moved verbatim to a new exported `src/server.ts`, so tests import the server without side effects. The audit immediately earned its keep, catching a sub-bar `track_rename` description and four undescribed discriminator literals in `automation_add_lane`'s target schema — both fixed. The /mcp-verify skill's manual parity step now just runs the audit.
- Verified independently: cold `npm test` 7/7; a real stdio `initialize` → `tools/list` against `dist/index.js` returns exactly 92 tools; and a planted regression (shortened description) makes exactly the richness assertion fail, restore returns 7/7 — the enforcement provably bites. Swift surface untouched. Next M7 item: the agent-facing project snapshot.

## 2026-07-10 — M6 (rail-d): The copilot gets its face — a violet chat rail docked into the cockpit
- `CopilotRailView` + `CopilotTranscriptEntryView` (new `Sources/DAWApp/Copilot/`): a right-docked 360 pt violet-edged glass rail, mounted app-level at full workspace height in both Arrange and Mix — the copilot is a workspace companion, not a selection-gated panel. Header carries the glowing violet identity dot, AI credit, reset ↺ and close; a first-use hint card teaches the feature in plain language with three example prompts. The transcript renders every entry kind from the rail-c wire contract distinctly — user bubbles right-aligned, assistant text in violet glass, tool calls as violet chips showing the dotted command + params, tool results as green-ok/red-error chips, failures as a red strip with the actionable message — with a WORKING shimmer row and auto-scroll while a turn runs (input disabled, red cancel replaces send).
- Chip summaries are compacted by `CopilotSummaryFormat` in DAWAppKit so the rendering contract is headless-tested; the engine gained a `seedForCapture` hook driven by debug-tier `ui.showCopilot`/`debug.copilotSeed`/`debug.copilotState` (off allCommands, off MCP — capture/E2E only). DESIGN-LANGUAGE.md gains the "Copilot rail" component entry.
- Verified independently: build 0 warnings, **1257 tests in 153 suites** (+10, +2), MCP surface untouched at **92**, and all three live-app captures personally reviewed against the design language (idle hint card; full entry-kind variety in one conversation including an error tool-result and the shimmer; failure strip with input re-enabled). Remaining: rail-e proves the whole rail on a real key — blocked until one lands.

## 2026-07-10 — M6 (rail-c): The copilot engine is wired — an AI can now converse its way through the same commands as every other client
- `CopilotEngine` (DAWControl, @MainActor @Observable) runs the full tool-use turn loop: user message → provider call → up to 8 tool rounds executed against the identical `CommandRouter.handle` the WebSocket uses → final text. Session context rebuilds every round (8-char id prefixes with engine-side expansion), command errors flow back as error tool-results so the model can react, and hard caps (8 rounds, 4k results, 8k context, 20-message history, one turn at a time) bound every conversation. The 36-command `CopilotToolCatalog` carries transliterated JSON schemas with a test-asserted denylist — project.new/open/save, track.remove, and the copilot's own commands can never be called by the model.
- Wire surface: `ai.copilotSend` / `ai.copilotState` (poll, transcript with user/assistant/toolCall/toolResult/failure entries) / `ai.copilotReset`, mirrored as three MCP tools (**92** total). The engine is constructed key-less at app startup; the provider resolves per turn, so adding a key in Settings ⌘, works without a restart.
- Verified independently: build 0 warnings, **1247 tests in 151 suites** (+32, +3 — catalog exhaustiveness, a FakeCopilotProvider suite driving the real router through scripted multi-round tool sequences, command wire tests), npm clean, and a 7/7 live app round-trip (validation, the actionable no-key error with the engine confirmed wired, unknown-turnId poller semantics, reset, zero key material in any response). Remaining: rail-d gives this a violet chat rail; rail-e proves it on a real key.

## 2026-07-10 — M6 (rail-b): Copilot provider client lands — Anthropic tool-use speaking, OpenAI fallback, fully pinned without a key
- `Sources/AIServices/CopilotProvider.swift` implements the rail design's §2 seam exactly: value types for tool specs, content blocks (text / tool_use / tool_result), turn requests and replies, behind a `CopilotProviding` protocol that speaks pre-encoded JSON `Data` so AIServices never imports DAWControl. `AnthropicCopilotProvider` pins the Messages tool-use wire shape (tools with input_schema, tool_use/tool_result pairing by id, stop_reason mapping); `OpenAICopilotProvider` mirrors it over chat-completions function calling; `resolveCopilotProvider` follows the anthropic-first Keychain/env chain with the actionable no-key error naming Settings ⌘,.
- Thirteen stub-HTTP tests (reusing the LyricsWriter local-server helper) pin both providers' request shapes and parsing — including multiple tool_use blocks in one reply and the tool_result-rides-in-user-message contract — plus the resolver chain order and a no-key error that provably contains zero key material.
- Verified independently: build 0 warnings, **1215 tests in 148 suites** (+13, +3), MCP surface untouched at 89 tools, no logging primitives in the client, key-leak grep clean. Next: rail-c wires the engine, catalog, and ai.copilot* commands so this client starts driving the DAW.

## 2026-07-10 — M6 (rail-a): Copilot rail architecture settled — the chat copilot will drive the same command surface as every other client
- The copilot rail v1 design is closed and archived (`docs/research/design-rail-a-copilot.md`, 11 sections): a hand-curated 36-command tool catalog in DAWControl (schemas transliterated from the MCP server, with a name-bijection exhaustiveness test), in-process execution through the identical `CommandRouter.handle` the WebSocket uses, per-round session context with 8-char id prefixes, and an Anthropic-first/OpenAI-fallback provider seam that speaks pre-encoded JSON `Data` so module boundaries stay clean. Non-streaming v1; provider re-resolved each turn so adding a key in Settings takes effect without restart.
- Notable placement decision: `CopilotEngine` lives in DAWControl (AIServices would need DAWControl types — a dependency cycle), and the app observes the engine directly instead of a DAWAppKit mirror model. Safety rails are structural: a positive allow-list excludes project.new/open/save, track.remove, recording/arm, and the copilot's own commands (recursion impossible by construction), with 8-round and payload caps; every mutation stays individually undoable.
- Split shipped alongside the design: rail-b (provider client) → rail-c (engine + wire + MCP, 89→92 tools) → rail-d (violet rail UI) → rail-e (real-key gate, blocked like the lyrics workshop). ~41 tests planned across 4 suites, all runnable key-less via a fake provider driving the real command router. No code this cycle — design only; baselines hold at 1202/145, 89 tools.

## 2026-07-10 — M6 (v-d): Onset auto-align lands — AI takes snap to the original performance with one command
- New `take.autoAlign` command + `take_auto_align` MCP tool (89 total): measures the micro-offset between a take lane and the group's reference lane by matching their detected onsets (same spectral-flux detector the audio-quantize path uses), then moves the take so its phrasing locks to the original — one undoable "Align Take" edit. `apply:false` gives a pure dry-run preview; `searchWindowMs` (10–500, default 150) bounds the hunt. The aligner recovers a planted 80 ms shift to within a tenth of a picosecond through the real detector, and refuses to guess: fewer than 2 matched onsets throws `alignmentInconclusive` with counts and advice.
- The orchestrator's live closed-loop round-trip caught a real bug the 1199-test suite missed: applying at beat 0 with no headroom silently clamped to a no-op while reporting `applied:true`. Fixed same cycle — an apply that would push the take before the timeline start now throws `alignmentWouldCrossTimelineStart` naming the required move, the available headroom, and the `take.move` remedy; `applied:true` now strictly means the take sits aligned. Three regression tests pin it.
- Verified independently: build 0 warnings, **1202 tests in 145 suites** (+31, +4), tsc clean at 89 tools, and a 9/9 live wire round-trip (preview ±80 ms recovery, preview purity, apply→residual <3 ms, all three error surfaces, undo restore). The M6 vocals path — repaint core, clip-fix loop, real-hardware gate, and now micro-alignment — is complete end to end.

## 2026-07-10 — M6 (v-c): Real repaint gate PASSES — the vocal-fix loop is proven on live hardware, sample-exact at the seams
- Ran the full clip-fix loop against the real ACE-Step sidecar (turbo, MLX native) on the archived 30s vocal stem: wire-scaffolded project → `ai.fixClipRegion` on beats 16–24 (±10s context → 22s window, repaint 8–12s in-file) → status polls → import as the violet "AI Fix 1" lane → comped audition bounce. About 70 seconds wall end-to-end including model load; the submit was accepted first try and the three "installed but not running" polls during the model-load GIL stall were absorbed by the designed tolerance.
- Continuity analysis PASS, stronger than the design demanded: the context outside the repaint window came back at peak lag **0 samples with correlation 1.0000** on both sides — upstream splices the source audio back verbatim outside the window, so alignment is sample-exact, while the fix region itself is genuinely new material (correlation 0.16). Both comp-splice seams are click-free in the rendered bounce, and the comp is exactly [original 0–16 | fix 16–24 | original 24–60].
- Nine artifacts archived for audition under `~/Library/Application Support/DAWPro/Generations/gate-vc-repaint/` (dry window bounce, returned repaint, comped bounce, analysis.json, wire-response JSONs). No code changed — this was a verification gate; baselines stay 1171 tests / 141 suites, 88 tools.

## 2026-07-10 — M6 (v-b-2): FIX WITH AI panel lands — region vocal fixes are now a two-click flow in the app
- Select an audio clip and a violet FIX WITH AI chip appears in the arrange header, opening a docked glass panel: region beats prefilled from the clip (cyan SF Mono, editable), a "what to fix" prompt, optional bracketed lyrics, and a SUBTLE/BALANCED/BOLD strength picker (mapping to the repaint modes) above a violet-glow FIX THIS REGION button. Below it, an AI FIXES strip tracks every job: violet shimmer + step/percent while generating, green READY with one-click IMPORT, an IMPORTED → "AI Fix N" badge once the take lands, red failures with the upstream message. The panel persists across selection changes — jobs keep polling while the composer collapses to a hint.
- Under the hood: headless `DAWAppKit.ClipFixModel` over the v-b-1 store methods with the Sketchpad resilience rules — a failed poll marks a card transiently stale but never kills it; `clipFixStale` is terminal amber, `clipFixJobNotFound` terminal red, and any other import error stays retryable. Debug-tier seed commands (off the agent surface) drive captures and E2E.
- Verified independently: build 0 warnings, **1171 tests in 141 suites** (+19, +1); MCP surface untouched (88 tools); all three captures personally reviewed (filled composer on "Lead Vocal", the three-state jobs strip, the imported badge). The full vocal-fix loop — select, describe, generate, import, comp — is now usable both from the app and over MCP.

## 2026-07-10 — M6 (v-b-1): Clip vocal-fix flow lands — "fix this region" becomes a comping decision, not a destructive edit
- New agent-plane vertical: `ai.fixClipRegion {trackId, clipId, startBeat, endBeat, prompt?, lyrics?, mode?, strength?, seed?, contextSeconds?, model?}` bounces the target dry (as-heard: stretch/gain baked, track FX/sends stripped, plain-clip fades stripped to match post-grouping playback) over the region ± 10 s of context, submits an ACE-Step repaint of exactly that window, and — after the caller polls `ai.generationStatus` — `ai.importClipFix {jobId}` lands the result as a violet "AI Fix N" take lane comped in over exactly the requested region. Original audio is never replaced: the M5 take-group machinery holds both, one undo step restores everything, and the user comps between original and fixes with the existing take tools.
- Two engineering guarantees from the daw-architect design: outside-window audio from the repaint (a VAE reconstruction, not the original samples) can never reach the mix — the comp splice selects the fix lane only inside the region; and a minutes-long job survives project edits honestly — pure moves rebase by delta, anything geometry-breaking (trim/stretch/gain/tempo) fails with an actionable `clipFixStale` naming what changed. Pending fixes are in-memory v0 (documented: they don't survive relaunch; `clipFixJobNotFound` says to resubmit).
- Verified independently: build 0 warnings, **1152 tests in 140 suites** (+34, +3 — pure planner window/splice cases, dry-bounce assertions incl. zeroed fades and no render tail, move-rebase/stale matrix, two-fixes-compose-into-one-group, registry lifecycle); npm clean at **88 tools**; live app round-trip ALL PASS (7 checks — field-named validation, ghost-track translation, exact `clipFixJobNotFound` contract wording). Design archived at `docs/research/design-v-b-clip-fix.md`; real-sidecar seam-continuity verification is the upcoming (v-c) gate.

## 2026-07-10 — M6 (v-a): Repaint core lands — surgical AI audio fixes over the wire, retake = fresh seed
- `ACEStepClient` learns `repaintAudio`: regenerate a time window (`start`/`end` seconds) of an existing audio file, guided by optional prompt/lyrics, with `mode` conservative/balanced/aggressive, `strength` (balanced only), waveform-crossfade control, and deterministic-or-random seed. The upstream surface was read from sidecar source first: repaint is supported by BOTH turbo and sft, so unlike stems there's no sft ensure-load — one raw job id polls through the ordinary `ai.generationStatus` path. Source audio stages into the shared temp-dir allowlist; `audio_format:"wav"` always (the mp3-default trap, pinned again in tests).
- No invented "retake" command: upstream has no retake task type — a retake is the same repaint window with a fresh random seed, so the command/tool docs say "call again without `seed`" instead of growing a second surface.
- Wire + agent plane: `ai.repaintAudio` with field-named validation (missing/nonexistent `sourcePath`, negative `start`, `end` ≤ `start`, unknown `mode`, out-of-range `strength`) and the `ai_repaint_audio` MCP tool (**85→86**).
- Verified independently: build 0 warnings, **1118 tests in 137 suites** (+19, +2 — wire-shape suite pins every repaint field incl. seed-both-ways and confirms no model-inventory/init calls; command suite covers every validation branch); npm clean at 86 tools; live app round-trip ALL PASS — four field-named validation errors over the wire plus the actionable sidecar-unreachable translation on a well-formed submit. Real repaint generation is deliberately deferred to the (v-c) gate.

## 2026-07-10 — M6: Lyrics Workshop lands stub-complete — project-aware AI lyric writing awaiting its first real key
- The Sketchpad grows a violet WRITE-WITH-AI disclosure: theme + style + structure chips (verse/chorus/bridge/outro, add/remove/reset) → a provider-written draft in ACE-Step's bracketed format, with REWRITE, instruction-driven REFINE, and one-click APPLY TO LYRICS into the composer. Backed by the headless `DAWAppKit.LyricsWorkshopModel` (idle/writing/failed states; injected writer factory so the no-key case surfaces as an in-panel message at write time, not at launch).
- `LyricsGenerating` gains `writeLyrics(LyricsWriteRequest)` (default-bridged for minimal conformers); `AnthropicClient`/`OpenAIClient` implement it through a shared `LyricsPromptBuilder` that teaches both providers the identical bracket-format + singability system prompt and weaves in project context — omitted `tempoBPM`/`timeSignature` default from the live transport, so a bare call still carries the session's tempo/meter. Provider selection is anthropic-first via the Keychain/env `resolveKey` chain; no key yields an actionable, key-value-free error naming Settings (⌘,) and `ai.providerStatus`.
- Control + agent plane: `ai.writeLyrics` (`prompt` required; `style`/`structure`/`context`/`existingLyrics`+`instruction` optional — providing `existingLyrics` switches to refine mode) and the mirroring `ai_write_lyrics` MCP tool (**84→85**), deliberately distinct from the env-key legacy `generate_lyrics`: this one uses the app's keys and live project context.
- Verified independently: build 0 warnings, **1099 tests in 135 suites** (+37, +5 — both providers' exact request shapes pinned against stub HTTP servers, workshop state machine, command round-trip); npm clean at 85 tools; all three captures personally reviewed (filled composer, "via anthropic" draft with REWRITE/REFINE/APPLY, bracketed lyrics landed in the editor); live no-key wire round-trip ALL PASS (actionable error, zero key material, field-named validation). **Stub-verified only — the roadmap box stays unchecked until a real key is supplied (Settings ⌘, or `.env`) and one real generation is exercised; see ## Blocked in ROADMAP.**

## 2026-07-10 — M6: API key management lands — Keychain storage, glass Settings panel, and a wire that can't leak
- The AI provider stack is now fully configurable in-app: a Settings overlay (header gear chip or ⌘,) with per-provider rows — Anthropic, OpenAI, Suno (dormant), and a keyless ACE-Step row — backed by `KeychainKeyStore` (SecItem generic-password, service `com.dawpro.api-keys`). Environment variables keep precedence and show as LOCKED rows pointing at the var name; Keychain-saved keys show only a session-scoped `•••• last4` mask (stored plaintext is never read back for display). Neutral chrome by design — violet stays reserved for AI-generated content.
- The security boundary is structural, not conventional: there is NO set-key command on the control protocol or MCP — key values cannot transit the agent plane, period. The wire gets `ai.providerStatus` (+ `ai_provider_status` MCP tool, 83→84) returning strictly `{provider, configured, source}`; a test scans the full response JSON for key material and another asserts no set-key command exists. Resolution is a shared env-first chain (`resolveKey`) wired additively through `AIConfig.fromEnvironment(keyStore:)` — behavior with env vars present is byte-identical to before.
- Verified independently: build 0 warnings, **1062 tests in 130 suites** (+27, +3 — including a live headless macOS Keychain round-trip in an isolated namespace), npm clean at 84 tools; both captures personally reviewed (empty state, and the env-locked + keychain-configured mix); and a fresh live wire round-trip with an injected fake env key — the response reported only `configured/source`, with zero key material in the raw JSON.

## 2026-07-10 — M6 (iii-c-real) COMPLETE: genuine SFT stem separation, log-proven — the stems epic closes
- The gate that matters passed: `ai.extractStems` with NO model specified now defaults to `acestep-v15-xl-sft`, ensure-loads it into sidecar slot 2, and the sidecar log shows **every extract sub-job routing "Using second model: acestep-v15-xl-sft"** — zero silent substitution. The stems that came back are genuine, distinct PCM separations (different md5s, RIFF/WAVE 16-bit 48 kHz, 5.5 MB each, archived to ~/Library/Application Support/DAWPro/Generations for audition), imported as two violet AI tracks and removed by one undo. Full gate 10/10; slot-2 load + extraction in 164 s.
- What shipped: run.sh exports `ACESTEP_CONFIG_PATH2=acestep-v15-xl-sft` (slot 2 constructed at startup); `ACEStepClient.defaultStemsModel` + `ensureStemsModelLoaded` (`GET /v1/model_inventory` is_loaded check → `POST /v1/init {model, slot:2}`, 600 s configurable timeout, per-instance ensured cache, actionable `modelSlotUnavailable` error when an old sidecar lacks the env var); explicit `model` still wins. +4 tests (1035/127), tools steady at 83, command/tool descriptions teach the auto-load behavior.
- Two MORE findings only the real server could produce (now five total for this epic): `/v1/models` is SHADOWED by an OpenAI-compat route returning `{"object":"list","data":[]}` — the correct envelope lives at upstream's internal `/v1/model_inventory` (which also confirmed on live data that ONLY the sft checkpoint advertises extract/lego/complete); and the slot-2 model load briefly stalls the sidecar's event loop (GIL) so even executor-backed init windows can bounce wire submits with the misleading "installed but not running" — transient-tolerant submit retry is now standing guidance, and the "loading" sidecar state distinction has earned its third strike as a polish item.
- With this, the M6 (iii) generation epic — import pipeline, Sketchpad UI, stems extract/Lego, and the real-model gate — is fully landed.

## 2026-07-10 — M6 (iii-c-real) partial: first REAL stems run — wire proven 10/10, one bug fixed, one upstream trap exposed
- The whole stems path ran against the real sidecar for the first time: `ai.sidecarStart` from the wire (healthy in 5–7 s), a real 30 s lofi source generated in 50 s (turbo), `ai.extractStems` on that WAV, two named stems back, `ai.importGeneratedStems` landing violet `AI: Vocals`/`AI: Drums` tracks, single undo — 10/10 gate checks on the re-run.
- Real bug the stub hid (again): the stems submit path omitted `audio_format: "wav"`, so upstream returned 128 kbps MP3 bytes in `.wav`-named files (caught by the gate's RIFF assertion — both "stems" were byte-identical 0.48 MB sizes). One-line `ACEStepClient` fix + regression assertions pinning `audio_format` in both extract and Lego wire tests; re-gated on the real sidecar: genuine RIFF/WAVE PCM 16-bit 48 kHz stems, 5.76 MB each.
- Upstream trap, still open (why the box stays unchecked): passing `model: "acestep-v15-xl-sft"` does NOT load it — the sidecar logs `Model 'acestep-v15-xl-sft' not found in ['acestep-v15-xl-turbo'], using primary` and SILENTLY runs the extract on turbo, which officially doesn't support the task type (upstream doesn't reject it either). So separation quality is unproven until the sidecar serve config actually loads the SFT checkpoint — that config work + a genuine SFT re-gate is the remaining (iii-c-real) scope. Also learned: a fresh sidecar's FIRST /release_task blocks its event loop for the lazy model load, so wire submits (not just status polls) need transient tolerance — the flagged "loading" sidecar state polish item now has two bites.
- Suite 1031/127 green with the fix, 0 warnings; MCP untouched at 83.

## 2026-07-10 — M6 (iii-c): stems — extract and Lego land as multi-track violet imports
- The DAW can now split audio into stems and grow arrangements track-by-track: `ai.extractStems` (source file + stem names) and `ai.legoGenerate` (source file + global_caption + per-track local prompts) fan out one upstream `/release_task` per track under a composite `"stems:<uuid>"` job id, polled through the SAME `ai.generationStatus` surface (aggregated progress; one failing sub-job fails the composite naming the track) with the results riding an additive `stems: [{trackName, audioPath, bpm?, durationSeconds?}]` field. `ai.importGeneratedStems` mirrors the iii-a import fanned out: all-or-nothing stem staging into the project's Generations home, then ONE performEdit appending N violet AI tracks (title-cased from track_name) each with a clip at the same beat, tempo adoption by the iii-a rule from the first bpm-bearing stem — a single undo removes every track and restores the tempo. 3 new MCP tools (80→83) teach the healthy-sidecar → submit → poll → N-violet-tracks flow.
- Reading upstream source (not the scout summary) changed the design: extract AND lego are single-track-per-job and BOTH require `src_audio_path` — Lego is conditioned-on-context generation, not from-scratch; and the source-audio "upload" is upstream's temp-dir allowlist (`release_task_audio_paths.py` accepts only paths that realpath into the sidecar's own system temp), so the client stages a COPY under the shared `$TMPDIR` before submitting. Biggest catch: `TASK_TYPES_TURBO` EXCLUDES extract/lego — the turbo config our sidecar boots with won't serve them until the (already-installed) base/SFT model is loaded into a handler slot. `model` is exposed on both requests; a real-sidecar stems gate is now an explicit roadmap item (iii-c-real) rather than a silent gap.
- Verified independently: build 0 warnings, **1031 tests in 127 suites** (+29, +2), npm clean at 83 tools, and the stub-sidecar E2E — which drives the REAL app binary over the REAL control WebSocket and asserts the actual wire shapes (staged src path under $TMPDIR per sub-job, task_type/track_name/global_caption/local prompt) — re-run by the orchestrator: **27/27**, including 2-stem import + tempo 96 adoption + single-undo-removes-both, the Lego 1-track path, and verbatim still-running/unknown-job/empty-trackNames errors.

## 2026-07-10 — M6 (iii-b): AI Sketchpad — song generation gets a face
- The generation stack is now a first-class panel: a 340 pt violet-edged Sketchpad docks right of the Arrange timeline (header SKETCHPAD chip toggles it), with style-prompt + lyrics editors, one-tap `[verse]/[chorus]/[bridge]/[outro]` section chips, a 15–240 s length stepper, and a candidates list where each generation lives as a card — shimmer + step/percent progress while running, BPM/length metadata + cyan PREVIEW (off-engine AVAudioPlayer, one at a time) + glowing IMPORT when succeeded, a readable red reason when failed, and an IMPORTED→track-name seal after landing. Import rides the existing iii-a pipeline (`store.importGeneration`), so the panel and the control wire agree on job state via a shared `ACEStepClient`/`SidecarManager`; a sidecar-down banner offers inline START.
- All panel state lives in headless `DAWAppKit.SketchpadModel` (`@MainActor @Observable`, zero AppKit/SwiftUI): candidate lifecycle queued→running→succeeded/failed→imported, poll-only-active refresh loop that tolerates thrown polls (stale badge, keep trying), injected import closure, sidecar gating of `canGenerate`. Debug-only `ui.showSketchpad` + `debug.sketchpad*` seed/drive commands stay off `allCommands`/MCP — the agent-facing surface is unchanged (80 tools), so no ARCHITECTURE delta.
- Verified independently: build 0 warnings, **1002 tests in 125 suites** (+21, +1 — scripted-fake SongGenerating covering every transition), MCP steady at 80; four window captures personally reviewed — empty state (GENERATE correctly dim on blank prompt), succeeded card (92 BPM 30s, armed GENERATE), the full import round-trip in one frame (seal badge + violet AI track + clip at bar 1 + tempo adopted 92.0), and the demo spread (STEP 3/8 40% glowing bar over a failed card). Agent fixed two real defects mid-task: runloop-spin awaits silently not completing (→ fire-and-forget Tasks + state polling) and the view's poller amber-flagging a fake demo job id.

## 2026-07-10 — M6 (iii-a): generation→project import — a finished job becomes music in the arrangement
- One command turns a succeeded ACE-Step job into project material: `ai.importGeneration` (+ `import_generation` MCP tool, 80 total) copies the WAV out of the volatile sidecar cache into `~/Library/Application Support/DAWPro/Generations/` (the recording-take model — planMedia folds it into the .dawproj bundle on save), reads the authoritative on-disk duration, and in ONE `performEdit("Import Generation")` appends a violet AI-flagged track + clip at the target beat with tempo adoption — project tempo ← the generation's `metas.bpm`, by default only on an empty project, forceable either way. Single undo removes the track AND restores the tempo. Rejections are actionable and verbatim: still-running points at `ai.generationStatus`; unknown/expired jobs surface the client's own wording.
- The result `metas` (bpm/duration/genres/keyscale/timesignature) and echoed prompt now ride `SongGenerationStatus` as additive omit-when-nil fields, and DAWCore reaches audio+metas through a new `GenerationImporting` seam (injected `generationSource`, adapted in DAWControl over the router's existing `SongGenerating`) — DAWCore stays AI/network-free, and the seam is literally the status re-poll since succeeded status already carries the fetched-once audio path.
- Verified independently: build 0 warnings, 981 tests in 124 suites (+20, +1), npm clean at 80 tools, stub-sidecar E2E re-run **32/32** — generate → poll to succeeded (bpm 92) → import → snapshot shows AI track+clip+tempo 92 → undo restores both → second import with `setProjectTempo:false` leaves tempo untouched → error surfaces verbatim. Real-sidecar generation was proven at the M6 (ii) gate; the import path composes on top of it unchanged.

## 2026-07-06 — M6 (i)+(ii) REAL GATE PASS: first AI-generated audio out of DAW Pro
- The full local generation stack is live end-to-end: 55 GB of ACE-Step-1.5 weights installed (XL-turbo + XL-sft DiT, 4B LM), the sidecar starts from the control wire and reports healthy in under a minute, and a real generation — lofi prompt + bracketed verse/chorus lyrics, 60 seconds — rendered in ~52 s wall on the M5 Max (LM planning at 51 tok/s, tiled VAE decode) and landed as a valid 10.99 MB 48 kHz WAV fetched through `ai.generationStatus`. Both M6 boxes checked.
- The real gate earned its keep by flushing out three bugs no stub could see: (1) install.sh's weights sanity check only knew single-file layouts — the first SHARDED repo (XL-turbo, 4×5 GB) could never pass despite downloading perfectly; (2) upstream's serve-time generation path builds `project_root/checkpoints` explicitly, BYPASSING the documented `ACESTEP_CHECKPOINTS_DIR` — without exporting `ACESTEP_PROJECT_ROOT` the first generation re-downloads the entire model bundle into the wrong directory (run.sh now exports it, plus a defensive symlink); (3) `ACEStepClient` re-wrapped upstream's pre-built `/v1/audio?path=…` result URL, double-encoding it into a 403 — fixed to request it verbatim, with a regression test pinning the exact request target the server receives (961 tests / 123 suites, 0 warnings).
- Operational notes: the sidecar's single event loop blocks during lazy model load, so status polls transiently fail — the wire clients tolerate it, and a "loading" state distinction is a flagged polish item. Session-restart cleanup wiped the old scratchpad, taking the stretch-listen audition WAVs (regenerable on request) — durable artifacts now belong in the repo or ~/Library, not the scratchpad.

## 2026-07-06 — M6 (ii) generation layer: ACEStepClient + generate_song (awaiting real-generation gate)
- The DAW can now ask for songs: `SongGenerating` reshaped to the async submit/poll pattern local generation actually needs (`generateSong` → submission, `generationStatus` → state/progress/audio; SunoClient minimally adapted, still the dormant fallback), and `ACEStepClient` (actor) implements it against the sidecar's REAL routes, read from the upstream source: `POST /release_task`, `POST /query_result` (numeric status map + a JSON-encoded nested result payload), `GET /v1/audio` streaming, the `{data,code,error}` envelope — and a verified fact: upstream has NO cancel route, so we ship none. Finished audio is fetched once to a temp WAV (`audio_format` deliberately "wav", not upstream's mp3 default) and cached per job.
- Wire: `ai.generateSong` / `ai.generationStatus` with field-named validation; a sidecar-unreachable error re-probes SidecarManager so the agent gets the precise actionable message ("call ai.sidecarStart"). MCP: `generate_song` + `generation_status` (79 tools) teaching the healthy-sidecar-first, submit→poll→import flow and the bracketed-lyric format.
- Verified independently: build 0 warnings, 960 tests in 123 suites (+19, +2 — multi-route stub server, no weights needed), npm clean at 79, live stub E2E re-run ALL PASS (submit→running-with-progress→succeeded→valid RIFF/WAVE on disk, fetch-once caching, unknown-job and no-sidecar errors verbatim). **Both M6 (i) and (ii) boxes stay unchecked pending the real gate**: weights ~23 GB downloaded at last check; once complete — real sidecar health check closes (i), first real generation closes (ii).

## 2026-07-06 — M6 (i) management layer: ACE-Step sidecar install/run/lifecycle (weights downloading)
- The AI-suite milestone opens: `scripts/ace-step/install.sh` (idempotent — uv-managed Python 3.12 venv sidestepping the system 3.14 vs ACE-Step's <3.13 pin, shallow upstream clone, `acestep-download` for the LARGEST official tier per the standing directive: XL-turbo + XL-sft DiT + 4B LM, ~55–70 GB, size-sanity + import self-check, success marker) and `run.sh` (loopback-only FastAPI on 127.0.0.1:8001, MLX LM backend + MPS fallback, exec + pidfile so signals reach the server). Research-doc deviation documented: the doc's "-diffusers" bf16 repos don't exist in the live downloader registry — raw FP32 repos via the real CLI instead (disk is no constraint). No auth gate: ACE-Step-1.5 is MIT/unauthenticated on HF, confirmed live.
- `SidecarManager` actor in AIServices: `/health` probe (verified against upstream's actual route shape) mapping to notInstalled / installedNotRunning / starting / healthy / error with version+model info; `start()` spawns run.sh with startup-timeout poll, pidfile, and logs to ~/Library/Logs/DAWPro/ace-step.log; `stop()` SIGTERM→SIGKILL. `ai.sidecarStatus/Start/Stop` commands + 3 MCP tools (77 total) teaching the install-first flow. Two real install-script bugs found by actually running it (bash-3.2 `set -u` empty-array crash, unconditional `uv venv`) — fixed and re-verified idempotent.
- Verified independently: build 0 warnings, 941 tests in 121 suites (+21, +4 — stub-HTTP health-mapping suite needs no weights), npm clean at 77 tools, live E2E re-run ALL PASS (real dir honestly `notInstalled` mid-download; stub sidecar proves the full status→start→idempotent-start→stop→no-op-stop cycle over the wire). **Roadmap box stays unchecked until the ~55–70 GB download completes and the real sidecar passes its health check** — install running in background, ~1 GB in at last check.

## 2026-07-06 — M4 (i) RESOLVED: mid-play send activation — stale render clock, one-flag fix
- The defect two fix rounds bounced off is closed, and the instrumented diagnosis showed why those rounds couldn't work: the new send was NEVER miswired (the post-resume connection dump proved the full leg connected and its tap firing — carrying silence). The real mechanism: after the rewire's stop→reset→start engine bounce, `outputNode.lastRenderTime` still reports the PREVIOUS render session's sample clock, so `startPlayers`' `derivedBeats()` anchor froze the playhead at the resume beat for the length of the prior session — everything downstream was correctly playing a stopped transport. Arithmetic confirmation: predicted wrap-revival +4.19 s vs observed +4.17 s. Fix: `startPlayers(renderClockTrusted: false)` on the rewire-resume path forces the host-clock anchor branch (host time is monotonic across the bounce); one flag, no other behavior change, instrumentation removed.
- Verified independently: build 0 warnings, 920/117 exact baseline, and BOTH live repros re-run by the orchestrator — the original 19-check bus E2E ALL PASS including the historically failing "send signal meters on FX bus" (0.0724 RMS), and the audio-clip variant metering 0.1000 on the destination bus 252 ms after a mid-play addSend with existing playback untouched. The MIDI variant's revival lands at the loop wrap by design (documented no-chase v0 contract — a sustained pad has no note-on between resume and wrap).
- Discovered en route, parked properly (no-thrash): `project.new` after a PLAYED send/bus session corrupts the AVAudioEngine graph — the next `track.add` crashes in `UpdateGraphAfterReconfig` (two different surface stacks across runs = heap corruption; never-played sessions don't crash; proven independent of this fix). Recorded under `## Blocked` with repro `crash-teardown.mjs`. **M4 is now fully complete except that parked teardown crash.**

## 2026-07-06 — M5 (iv-d): render wire + MCP — M5 COMPLETE
- The loudness/stem surface goes on the wire: `render.measureLoudness` (measure, write nothing), `render.bounce` (optional −70…0 `lufsTarget`, −20…0 `truePeakCeilingDb`, honest clamp reporting), `render.stems` (per-track selection, `includeMixdown`) — field-named validation, store rejections verbatim, responses threading the model's own Codable. Three MCP tools (74 total) whose descriptions teach an AI mixing agent the −14 streaming / −23 EBU R128 conventions, the clamp-not-limiter semantics with the bus-limiter-then-re-bounce escape hatch, and the Σ stems ≡ mixdown invariant. `render.mixdown` untouched; ARCHITECTURE gains the `render.*` paragraph.
- Live-E2E-discovered crash fixed in iv-a's short-term loop: a render with exactly 30 hops (any clean 3.0 s at 48 kHz) crashed `Loudness.measure` on an invalid range (`1...(hopCount − hopsPerShortTerm)`); one-line guard, suite re-verified. Found because the E2E drove the REAL app — the fake-engine tests couldn't see it.
- Verified independently: build 0 warnings, 920 tests in 117 suites (+17, +1), npm clean at 74 tools, live E2E re-run ALL PASS — measured −14.906 LUFS/−12.361 dBTP on the 2-track+bus session; bounce to −16 → −16.0000 LUFS with the written file's Node-read peak matching the report exactly (−13.4545); hot-material clamp → `limitedByCeiling` true, −1.0000 dBTP, honestly short of target; stems 01 T1/02 Bus vs 00 Mixdown residual 0.0000e+0 over the wire; both error surfaces verbatim.
- **M5 — Editing depth is COMPLETE**: waveform editor, time-stretch, take comping + MIDI/audio quantize + grooves, stem export + LUFS bounce. 920 tests, 74 MCP tools, zero render-thread regressions across the milestone.

## 2026-07-06 — M5 (iv-c): stem plan + export — Σ stems ≡ mix, proven
- `StemPlan.swift` (pure DAWCore) partitions the session at the master input: one dry stem per direct-to-master track (sends stripped), one stem per bus carrying every send contribution routed to it — the only partition where nonlinear bus FX keep the sum identity. Bus-routed track requests reject verbatim; bus passes park foreign direct-outs on a silent dummy bus so the missing-bus→master fallback can't leak; `NN Name.wav` sanitize with case-insensitive collision suffixes. `renderStems` probes the full-session PDC plan ONCE and forces it on all N sequential passes, measures each stem (never normalizes), and streams one buffer in flight; `includeMixdown` writes `00 Mixdown.wav` under the same plan.
- The epic's crown-jewel invariant holds: Σ stems vs mixdown residual is 5.4e-20 on a flat project and BIT-EXACT (0.0) on both the bus-FX (250 ms delay) and PDC (240-sample lookahead limiter) projects — against a normative bar of 1e-4. The negative control renders one stem under its subset auto-plan instead and combs at 0.25 residual, proving the forced-plan machinery is load-bearing. Send tails demonstrably live in the destination bus stem (dry stem RMS 0.0 vs bus 0.108 in the tail window).
- Verified independently: build 0 warnings, 903 tests in 116 suites (+17, +2), MCP untouched (71 — wire lands at iv-d). Assumptions flagged: NN prefix numbers the filtered selection (no gaps); empty selection throws `nothingToRender`.

## 2026-07-06 — M5 (iv-b): buffer-render seam + measured/normalized bounce
- The engine gains three additive offline primitives on `AudioEngineControlling` (`renderOffline` buffer render with forcible PDC targets, `offlineCompensationTargets` full-session plan probe, `writeAudioFile`), with protocol-extension defaults keeping every fake green; `renderMixdown` is now literally renderOffline + writeAudioFile — proven bit-identical (max diff 0.0) with the WYSIWYG stretch-await preserved. The PDC probe builds the manual-rendering graph and reads the plan without rendering a frame, and matches `PDCPlan.compute` by test.
- `ProjectStore+Render.swift` lands `measureLoudness` (render → measure, nothing written) and `renderBounce`: static gain `target − integrated`, true-peak ceiling clamp `G = ceiling − TP` with honest `limitedByCeiling`, gain applied in place, output RE-measured post-gain, written Float32 WAV. Measured: −16 target → −16.00000051 LUFS re-read from disk; clamp case gets exactly `ceiling − TP` (+1.0 dB where +6 was asked) with the report showing the real achieved loudness; `bounceSilent` verbatim when a target is asked of gated silence.
- Verified independently: build 0 warnings, 886 tests in 114 suites (+15, +2), MCP untouched (71 tools — wire lands at iv-d). Flagged: param range validation deliberately deferred to the wire layer per spec; store defaults throw `engineUnavailable`.

## 2026-07-06 — M5 (iv-a): loudness core — BS.1770-4 in pure DAWCore
- `Loudness.swift` lands the measurement engine for the stem/bounce epic: K-weighting biquads re-derived at any sample rate from the analog-prototype constants (48 kHz published-table pin ≤ 1e-6), 400 ms / 75 %-overlap gated integrated loudness (−70 LUFS absolute → −10 LU relative gate), max momentary + short-term from the same energy series, and 4× polyphase Annex-2 true peak (129-tap Kaiser-β6 sinc, phase 0 bit-transparent, passband flat within 0.0093 dB at 48 k). Pure scalar Swift, no Accelerate — DAWCore stays engine-free; `LoudnessMeasurement` Codable IS the future wire shape (nil fields for gated silence, digital silence encodes as `{}`). `RenderedAudio` moved DAWEngine→DAWCore with in-place `applyGain(linear:)`; engine behavior frozen.
- Measured vs analytic: 997 Hz −23 dBFS → −22.99998 LUFS; left-only channel-weight case −26.0103 vs −26.0; gate-drop −23.0310; EBU 3341 fs/4+45° true peak +0.0982 dBTP (genuine band-limited overshoot at the abrupt fixture start, bounds (−0.4, +0.2)); burst short-term −27.6852 vs analytic −27.6845; 44.1 k calibration −22.9972.
- Verified independently: build 0 warnings, 871 tests in 112 suites (+21, +7). No wire/MCP change this sub-item (71 tools) — commands land at iv-d. Assumptions flagged: momentary/short-term stay ungated per §3.2 (finite on sub-gate programs while integrated is nil); TP interpolator design is implementer's-choice per spec.

## 2026-07-06 — M5 (iii-g): groove templates — the epic closes
- Grooves are now a project-level palette: `GrooveTemplate` is a pure per-slot timing-offset table (`{gridBeats, cycleBeats, offsets}`, offsets clamped to ±grid/2) extracted from real performances — a MIDI clip's note onsets or an audio clip's detected transients, both through the same pure `extract` (nearest-slot snap, per-folded-slot average, empty slots stay straight). Eight built-in MPC swings (`swing8/16 × 54|58|62|66`, any 54–75 resolvable) compute on demand and are never persisted. `groove.extract/list/remove` commands + 3 MCP tools (71 total), and both `clip.quantize` and `clip.quantizeAudio` take a `groove` param (builtin name → template id → template name) — applied BY VALUE through the single `QuantizeTarget.slotOffset` branch, so groove wins over swing, both quantize paths inherit it unchanged, and deleting a template never dangles. Persistence is additive and omit-when-empty: pre-groove project files re-save byte-identical; undo covers extract and remove.
- Verified independently: build 0 warnings, 850 tests in 105 suites (+25, +6), MCP clean, live E2E re-run ALL PASS — swung-MIDI extraction returns offsets [0, 0.16] exact vs analytic swing-66; applying the saved groove to a straight MIDI clip lands every onset dead on target (dev 0.000000); builtin swing8:66 through the AUDIO path (quantizeAudio → offline bounce → re-detect transients on the rendered file) puts all onsets on groove targets at max 0.0013 beat; list/remove/undo/unknown-ref all verbatim. **M5 (iii) take comping + quantize + grooves epic COMPLETE** — 7 sub-items, zero render-thread changes, one engine addition (transient analysis) total.
- Flagged assumptions: extraction is clip-relative (grooves are position-independent); offset clamp is the closed ±grid/2 bound so swing-75 round-trips exactly; cycleBeats defaults to 4 (no meter model yet — revisit with meter work).

## 2026-07-06 — M5 (iii-f): audio quantize v0 — slice, nudge, crossfade
- Audio clips now quantize destructively: `clip.quantizeAudio` (+ `clip_quantize_audio` MCP tool, 68 total) detects transients (iii-e), slices the clip at onsets, and nudges each slice to the grid through the SAME pure `QuantizeTarget.nearest` evaluator as MIDI quantize — grid, strength lerp, MPC swing — then replaces the clip with its slices in one `performEdit("Quantize Audio")`, so undo restores the single original clip (same id). Monotone clamp guarantees slices never reorder; comp members, MIDI clips, non-identity-stretch clips, and <2-transient clips reject with dedicated verbatim errors.
- Deliberate deviation from the settled spec, caught by honest measurement: the spec's source-continuation gap-fill (extend a slice to reach its neighbour's new start) replays the NEXT onset's attack when a slice moves late — the bounce analysis showed full-energy doubled transients at 0.90/2.80/4.80 beats. Shipped instead: natural-length slices (each reads only its own `[onsetᵢ, onsetᵢ₊₁)` span) with equal-power crossfades at compressed joins and clean silence at expanded gaps — the classic Recycle behavior, and what makes onsets land exactly on grid. Elastic (per-slice stretch) stays the flagged v1.
- Verified independently: build 0 warnings, 825 tests in 99 suites (+23, +5), MCP clean, live E2E re-run ALL PASS — off-grid click clip (max deviation 0.1013 beat) → quantize → offline bounce → re-detect onsets on the RENDERED audio: 6/6 dead on grid, max deviation 0.0000 beat, no ghost transients; undo→1 original clip, redo→7 slices, rejections verbatim.

## 2026-07-06 — M5 (iii-e): transient detection — the epic's one engine addition
- Audio clips can now report their onsets: `clip.detectTransients` (+ `clip_detect_transients` MCP tool, 67 total) runs a pure vDSP spectral-flux analyzer — mono mix, 1024-sample Hann frames at 256 hop, half-wave-rectified flux against a 0.35 s moving-median adaptive threshold with a 1%-of-peak floor (empirically needed: spectral leakage on a decaying pad otherwise sneaks past), 30 ms minimum onset gap, energy-rise refinement. Markers are source-file seconds plus a 0–1 strength, geometry-free by construction — trims, splits, moves, and stretches never invalidate the analysis. Results cache as JSON sidecars keyed like stretch renders (content hash + sensitivity quantized to 0.05 + analyzer version), atomic-rename committed, corrupt-self-healing. Strictly off the render thread.
- Measured: click-train onset error max 0.67 ms against a 5 ms bar (with a noise bed); a decaying pad yields exactly its one attack and zero tail onsets; determinism is bit-identical across relaunch and re-render. The marker API feeds iii-f (audio quantize consumes `timeSeconds`) and iii-g (groove extraction gets strengths for free).
- Verified independently: build 0 warnings, 802 tests in 94 suites (+21, +2), MCP clean, live E2E re-run ALL PASS (5 onsets found on a staccato mixdown at 12 ms max error — synth attack ramp, 0 spurious — cache rerun identical, MIDI rejection and sensitivity-range errors verbatim).

## 2026-07-06 — M5 (iii-d): MIDI quantize — grid, strength, MPC swing
- MIDI clips can now be quantized: `clip.quantize` (+ the `clip_quantize` MCP tool, 66 total) moves note onsets toward a target grid with a 0–1 strength lerp and MPC-convention swing (50 straight … 75 max, offbeat slots delayed by `(2·swing/100−1)·grid` before the lerp). Note lengths are preserved unless `quantizeEnds`; results are re-canonicalized, deterministic, and idempotent at full strength. Destructive with snapshot undo under the house coalescing key; audio clips are rejected with a message pointing at the future `clip.quantizeAudio`, comp members by the shared take-group guard.
- The math lives in pure `DAWCore/Quantize.swift` with the groove seam pre-built: iii-g adds an additive `groove` field and flips one branch in `slotOffset` — the wire shape and tool schema stay fixed. iii-f's audio quantize will reuse `QuantizeTarget.nearest` verbatim. One process note: the implementing agent caught a 2× discrepancy between the briefing's swing wording and the spec's formula and correctly followed the spec.
- Verified independently: build 0 warnings, 781 tests in 92 suites (+17, +4), MCP clean, and the live E2E re-run ALL PASS — exact grid at strength 1, exactly-halfway onsets at 0.5, swing 66 landing offbeats at 1.32/3.32, verbatim audio rejection, undo restoring the original onsets.

## 2026-07-06 — M5 (iii-c): take lane UI — comp painting in the arrange view
- Take comping is now a direct-manipulation workflow: tracks with take groups grow a signal-green stacked-layers glyph that expands a takes section above the automation row — one dim sub-row per take lane (mini waveform or MIDI pills), with the comp rendered as glowing highlights over the selected ranges and the newest lane accented. Click-drag on a lane paints it into the comp for the dragged range (snapped, per-tick commits riding the `take.comp:<id>` undo coalescing, exactly like automation drags); a plain click selects the whole take. Member clips in the main lane wear a "name · N" group badge and glowing splice hairlines at comp boundaries, with a take-focused context menu (Select Take N / Flatten Group); the sidebar gets a height-matched group panel with per-take select dots and a FLATTEN chip.
- All geometry and gesture math is headless in `DAWAppKit.TakeLaneModel` — including a normalize step that keeps every paintable comp provably inside what `setCompSegments` accepts, cross-checked against the real store in tests (20 new, 2 suites). A `ui.showTakes` debug command (the `ui.showAutomation` pattern) makes the section captureable headless. The optional crossfade control was deliberately skipped for v0.
- Verified independently: build 0 warnings, 764 tests in 88 suites (+20, +2), and captures re-viewed — the 3-segment painted comp shows each lane glowing over exactly its painted range with three rebuilt member clips, badges, and splice lines; post-flatten returns ordinary clips with all chrome gone.

## 2026-07-06 — M5 (iii-b): take comping on the wire + recording auto-group
- The comping model is now fully AI/E2E-drivable: seven `take.*` commands (`group`, `setComp`, `select`, `removeLane`, `flatten`, `move`, `setCrossfade`) with comp-segment arrays round-tripped through the model's own Codable (per-index parse errors, store rejections verbatim), and seven matching MCP tools (65 total) whose descriptions teach an agent the comping model — lanes hold takes, the comp is an ordered segment list, members reject normal edits until flattened. Snapshots carry `takeGroups`/`takeGroupID` for free via the iii-a Codable.
- Recording now auto-comps: when a finished audio take overlaps existing material on the track, it lands as a new lane in a take group (existing group extends; plain clips get grouped; disjoint stays plain) with the newest take winning the default comp — the classic loop-booth workflow. One deliberate behavior change: re-recording over the same range forms a 2-lane group instead of stacking overlap-summing clips (the old test updated to match). MIDI recording is untouched; loop-cycle multi-take recording stays deferred.
- Verified independently: build 0 warnings, 744 tests in 86 suites (+23, +2), MCP `tsc` clean at 65 tools, and the live 34/34 E2E re-run — group → member-edit rejection (verbatim message naming the escape hatch) → 2-segment comp → select → flatten → members freed → full undo/redo round-trip including group restoration. Honest note: the wire key is `takeGroupID` (Swift-synthesized), diverging from the lowercase-`d` id convention elsewhere.

## 2026-07-06 — M5 (iii-a): take/comp domain — take lanes, comping, flatten-on-edit
- The take-comping foundation (from the settled M5 (iii) design): tracks own `takeGroups`, each holding take lanes (full Clips — audio or MIDI — so nothing about a take is second-class) and an ordered comp-segment list. The pure `CompFlattener` rebuilds ordinary track clips from the comp — joins become representational equal-power crossfades exactly like manual M5 (i) crossfades, so the playback engine needed zero changes. Comp-member clips are protected: all nine clip-edit operations reject them with a message naming `take.flatten` as the escape hatch; tempo changes re-flatten every group inside the same undo step. Persistence is additive (old projects byte-identical), and `planMedia` now walks lane media so un-comped takes survive a save.
- Seven store ops (`groupTakes`, `setCompSegments`, `selectTake`, `removeTakeLane`, `flattenTakeGroup`, `moveTakeGroup`, `setTakeCrossfade`) with house undo-coalescing keys; overlap grouping uses connected-cluster semantics. 27 new tests across 4 suites: flattener determinism, crossfade join correctness, all rejection paths, persistence round-trips including old-project compatibility, lane-media planning, undo/redo.
- Verified independently: build 0 warnings, 721 tests in 84 suites (+27, +4). Control commands + MCP tools land in iii-b (the split defers the wire layer, matching the vii-a/vii-d pattern).

## 2026-07-06 — M5 (ii-e): stretch UI + listening spike — M5 (ii) time-stretch complete
- Stretching is now a direct-manipulation gesture: ⌥-drag a clip's right edge to time-stretch (snapped, live "6.0 beats · 1.50×" readout, "≈" grip cue when hovering with option held) — it routes through the store's window-invariant `stretchClip(toLengthBeats:)`, so the source window never shifts. Non-identity clips wear a persistent SF Mono ratio/pitch badge; outside the 0.75–1.5× quality band the border and badge glow amber; while the background render is pending an animated shimmer sweeps the clip (a 10 Hz bounded-window poll over the engine's pull-based status, kicked on any stretch edit so both gesture- and MCP-driven changes shimmer); failures get a red border + error dot. All gesture math lives headless in `DAWAppKit.ClipStretchModel`, whose preview is cross-checked against the real store — including the subtle ratio-clamp→length re-derivation. Patterns recorded in DESIGN-LANGUAGE.md.
- The listening spike (ACE-Step not yet installed, so the app synthesized its own material: an 8-beat polySynth phrase with chords and staccato transients, rendered→imported→stretched→bounced through the live app) produced 36 grid cells across {0.75, 0.9, 1.25, 1.5}× × {−5, −2, +3, +7} st × formant on/off. Every cell length-exact; true peaks −7.67…−1.69 dBTP with zero cells over 0 dBFS — the ii-b +4.9 dB sine overshoot did not reproduce on musical material (chordal peaks aren't phase-aligned). Headroom decision: no hidden per-clip compensation gain — Float32 end-to-end means nothing clips on disk, the amber hint surfaces the risk, and inter-sample taming belongs at a future master-bus true-peak stage. **signalsmith-stretch stamped provisional-final; no Rubber Band escalation** — final sign-off awaits human audition (grid + notes in the session scratchpad's stretch-listen/).
- Verified independently: build 0 warnings, 694 tests in 80 suites (+14, +1 suite), captures re-viewed (badges, amber tint, shimmer frames mid-render).

## 2026-07-05 — M5 (ii-d): stretch engine wire — clips actually play stretched
- The engine now honors the ii-c stretch fields end to end. `StretchRenderCache` renders full source files through the OfflineStretcher into content-keyed Float32 CAFs (`~/Library/Caches/DAWPro/StretchRenders/`; SHA256 over path/size/mtime/param bit patterns/engine version — geometry-free, so trim/split/move/tempo edits never invalidate), with a 250 ms debounce, per-clip latest-wins cancellation, same-key single-flight, and unique partial files committed by atomic rename. At schedule time a `StretchResolution` resolver seam swaps the rendered CAF in as the clip's source with `startOffsetSeconds × ratio` offset mapping — the fade bake runs unchanged on the stretched timeline; pending renders schedule silence (never wrong-speed audio); identity clips never touch the resolver, an exact structural bypass. Render completion invalidates the clip schedule and restarts through the existing `tracksDidChange` seam; `render.mixdown` awaits pending renders so bounces are WYSIWYG; snapshots surface transient `stretchRendering` / sticky `stretchError` per clip (omit-when-default).
- Verified independently: 680 tests in 79 suites (+8, +1 suite), 0 warnings, full E2E re-run ALL 16 checks. Measured: identity null test max diff 0.0 with zero resolver invocations; offset mapping bit-exact at frame 48 000 (caught by an amplitude-ramped fixture — a pure sine is period-aligned at 0.5 s and hid wrong offsets); stretched fades 0.0 vs reference; live bounce audible in the 2.1–2.9 s window that only exists stretched (RMS 0.0642 = full source level) and silent after; mid-play re-stretch keeps the transport playing through the restart seam (playhead 5.46 → 6.42 beats). Deferred: cache LRU eviction sweep; failed renders retry only on param re-edit.

## 2026-07-05 — M5 (ii-c): stretch domain + full wire surface
- Clips carry their stretch intent: `stretchRatio` (0.25–4), `pitchShiftSemitones` (±24), `formantPreserve` — additive omit-when-default Codable with the ClipDocument mirror, so pre-stretch projects stay byte-identical. Pure helpers codify the contracts: `sourceWindowSeconds(tempoBPM:)` (the derived source window — lengthBeats stays the timeline authority) and `isStretchIdentity` (the exact-bypass predicate ii-d consumes). Store ops: `setClipStretch` (nil-keeps-current per-field, MIDI clips rejected with a clear message, undo-coalesced) and the compound `stretchClip(toLengthBeats:)` — sets the new length AND scales the ratio so the source window stays constant, with the subtle case handled: if the ratio clamps, the length re-derives so window invariance survives. Split copies stretch params to both halves (the full-file cache makes junctions seamless); trim/move preserve them untouched (geometry-free keys).
- Wire surface: `clip.setStretch` / `clip.stretchToLength` commands and two MCP tools (58 total) teaching agents the absolute-ratio semantics, the 0.75–1.5× quality sweet spot, and that rendering is async once ii-d lands. The engine deliberately ignores the fields this slice.
- Verified: 672 tests in 78 suites (+20, +4 suites), 0 warnings, mcp-server clean, independent build + suite run, and a live wire smoke: ratio 99 clamps to 4 with pitch preserved, the compound op turned 2 beats into 8 with ratio 4, MIDI rejection surfaced verbatim, and both clips' snapshots round-tripped all fields.

## 2026-07-05 — M5 (ii-a, ii-b): stretch seam settled + signalsmith vendored with the OfflineStretcher facade
- The integration seam is settled (ARCHITECTURE entry): three additive clip fields with absolute tempo-independent ratios in v0; full-source-file content-keyed CAF renders cached OUTSIDE `.dawproj` (geometry-free keys — trim/split/move/tempo edits never invalidate, split points seamless because both halves read the same phase-vocoder output); at schedule time the stretched file simply replaces the clip's source with `startOffsetSeconds × ratio` mapping, so the fade bake runs unchanged; debounced latest-wins async rendering with silence-while-pending; identity is an exact structural bypass.
- ii-b lands the foundation: signalsmith-stretch v1.3.2 and signalsmith-linear vendored verbatim with licenses and pinned commits, compiled through a new `CSignalsmithStretch` flat-C shim target on Apple Accelerate (one C++ translation unit; package-wide C++17 caused no conflicts). The Swift `OfflineStretcher` facade uses upstream's own exact-length recipe (output-seek pre-roll → chunked process → flush), needs no post-trim, checks cancellation between blocks, and passes a FIXED RNG seed — making output deterministic, which is what makes ii-d's content-keyed cache coherent.
- Verified: 652 tests in 74 suites (+8, +1 suite), 0 warnings, independent build + suite run. Measured: stretched lengths land EXACT (144 000/72 000/96 000 frames); pitch preserved at 440.00 Hz through a 1.5× stretch; +7 semitones measures 659.00 Hz vs 659.26 analytic; cancellation fires at poll 2 of ~36; two runs bit-identical. One honest flag for the listening spike: 0.75× compression shows overlap-add overshoot (~+4.9 dB inter-sample); Float32 CAFs don't clip on disk, but ii-e should make a headroom call.

## 2026-07-05 — M5 (ii): time-stretch library decided — signalsmith-stretch (MIT)
- The M5 (ii) library gate is decided after a full evaluation (docs/research/2026-07-05-time-stretch-library-evaluation.md): **signalsmith-stretch** — MIT header-only C++11, the cleanest commercial-shipping license possible, a block buffer API that matches the proven bake-at-schedule-time pattern, explicit formant controls for ACE-Step vocal material, and credible quality evidence (a direct forum A/B preferring it over Rubber Band; production use inside Qt/FFmpeg and audiomentations). Integration shape: vendored with its signalsmith-linear FFT sibling (optionally on Apple Accelerate) behind a flat-C shim per the CAtomics precedent, wrapped in a Swift `OfflineStretcher` facade.
- Named fallback if vocal listening tests disappoint: Rubber Band's commercial Standard license (£590 attribution / £1,490 non-attribution under 10 employees — verified pricing; its GPL track is explicitly unusable for proprietary shipping). SoundTouch rejected on quality, Bungee OSS noted as a bake-off second opinion but vendor-capped below its paid tier, Apple's TimePitch units reserved for the future real-time preview path via the existing AU-hosting plumbing.
- The daw-architect is settling the integration seam next: stretch-render cache location/key/invalidation (including project-tempo changes), stretch-before-fade-bake ordering with post-stretch beat remapping, an async render job model (the AU-prepare precedent), and the preview boundary. Sub-item split follows the design.

## 2026-07-05 — M5 (i-d): waveform editor UI — M5 (i) complete
- Clips are now directly editable in the arrange view: drag a clip body to move it (snapped, with a beat readout), grab the ~6-point edge zones to trim, double-click or use the context menu to split (including at the playhead), pull the corner fade grips to draw translucent fade shading (bowed for equal-power, straight for linear; curve toggle in the context menu), and drag the cyan dB chip vertically for clip gain — seamless mid-play by the i-b design. A SNAP control in the arrange header offers Off/Bar/Beat/1/2/1/4, with Bar following the project meter (a new `ClipSnap` type — the piano roll's snap hardcodes a 4-beat bar). Audio clips render a cached peak-outline waveform computed off the main actor, windowed by `startOffsetSeconds` so trims and splits show the true source region.
- All snap math, hit classification, and edit-preview clamping live headless in `DAWAppKit.ClipEditModel` (mirroring the store's rules; 14 tests), and every mutation routes through the five i-a store methods so undo and drag-coalescing come free. The clip-editing pattern is codified in DESIGN-LANGUAGE.md.
- Verified: 644 tests in 73 suites (+14, +1 suite), 0 warnings, independent build + suite run, and the capture inspected independently: split visible as two clips with the waveform continuous across the boundary, equal-power fade shading on the outer corners, −6.0 dB chips on both halves, SNAP: Bar in the header. **M5 (i) — the waveform editor — is complete** (domain, engine, wire, UI; 44 new tests across the four sub-items). Next: M5 (ii) time-stretch & pitch-shift, starting with the library decision.

## 2026-07-05 — M5 (i-b, i-c): clip gain/fades render + full edit surface on the wire
- Fades and gain are now audible, per the settled design with zero new render-thread code. `ClipFadeBake` computes fade-in/middle/fade-out frame windows (contiguity guaranteed by construction for any playhead or fade shape) and multiplies the normalized envelope — evaluated per frame from the domain's own `Clip.envelopeGain` — into buffer copies of only the fade windows, reading through a bake-owned second file handle (the player's streaming instance has stateful read position; sharing would race). `scheduleAll` schedules faded clips as three contiguous pieces on the clip's existing player; unfaded clips take the pre-existing path byte-for-byte. `startOffsetSeconds` is now honored (split/trim are audible, bit-exact against reference). Gain rides `player.volume` with an in-place `clipGainChanged` path — mid-play gain edits never restart; fade/offset edits are schedule-affecting and correctly re-bake through the existing restart seam.
- The wire surface: `clip.split|trim|move|setGain|setFades` (split returns both resulting clips; fade-curve parse errors name the offending field; store rejections surface verbatim) plus five MCP tools (56 total) teaching AI agents arrangement editing, crossfade-by-overlap with the equal-power recommendation, and dB gain staging.
- Verified: 630 tests in 72 suites (+26 over i-a's 604: 12 engine + 14 control), 0 warnings, mcp-server builds clean, and the live E2E re-run independently — ALL PASS (split note partitioning, snapshot round-trips, save/reopen persistence, error surfaces). Engine evidence: analytic fade error exactly 0.0 with equal-power midpoint 0.70710677; unfaded null 0 differing frames; split + linear crossfade nulls against the unsplit render at 1 float ulp; −6.02 dB plateau matches analytic to 7 decimals; mid-fade scheduling starts at the exact partial-envelope value; two renders bit-identical.

## 2026-07-05 — M5 (i-a): clip edit domain — split/trim/move/gain/fades + settled engine design
- M5 opens with the headless clip-edit foundation: `Clip` gains `gainDb` (−72…+24), `fadeInBeats`/`fadeOutBeats` with `FadeCurve.linear|equalPower`, and `startOffsetSeconds` (new — audio clips previously always played from the file head; split/trim are impossible without a source offset). All fields are additive omit-when-default Codable, mirrored into ClipDocument persistence, so pre-edit projects save byte-identical. One pure evaluator `envelopeGain(atBeat:)` (equal-power = sin/cos quarter-cycle, gain and fades compose multiplicatively) is the single authority the engine (i-b) and UI (i-d) will reuse.
- Store operations, all clamped and undo-coalesced: `splitClip` (fixed-tempo source-offset math, MIDI notes partitioned with overhang truncation, fades redistributed — clip 1 keeps fade-in, clip 2 keeps fade-out), `trimClip` (leading edge advances the offset and drops outside notes; fades re-clamp), `moveClip`, `setClipGain`, `setClipFades` (proportional reduction preserving the in/out ratio when the sum exceeds clip length). Verified: 604 tests in 70 suites (+17, +3 suites), 0 warnings, independent build + suite run.
- The engine read path is settled (architect memo → ARCHITECTURE entry): clip gain rides live `AVAudioPlayerNode.volume` (seamless mid-play edits); fades bake at schedule time into three-piece scheduling (fade-in buffer / streamed middle segment / fade-out buffer) on each clip's existing player; crossfades are purely representational — overlapping clips sum on their own players, the engine has no crossfade concept. The per-strip envelope-stage alternative was killed with the exact math: post-sum it cannot express two simultaneous per-clip gains, so it is exactly wrong during any overlap.

## 2026-07-05 — M4 (viii-c, viii-d): PDC always-on — latency compensation v0 complete
- PDC is now automatic: every event that can move a latency number (chain edits, bypass, hosted-AU prepare, routing changes, rate changes, cold start) funnels through one choke point at the tail of `PlaybackGraph.applyParameters`, which maps strip state into the DAWCore planner and pushes each strip's ring target — and because offline render calls the same path on both sides of engine start, live/offline parity holds by construction. The wire now reports it all: per-strip `chainLatencySamples` (all-effects sum) and `compensationSamples` always, `compensationClamped`/`compensationSkewSamples` omitted unless meaningful, plus a project-level `pdc` object (stage targets, maxPathLatency, outputLatency structured so a future master chain adds in). No new command — snapshots ride the existing surface per the settled design.
- Verified: 587 tests in 67 suites (+9, +1 suite), 0 warnings, independent build + suite + an independently re-run live E2E, all 23 assertions: plan-correct fields while stopped (dry strip padded 240 to meet the limiter strip, bus honest zeros, omit-if-zero honored); bypass toggled mid-play left playback rolling and totals bypass-stable while ONLY the limiter strip's ring retargeted 0→240 (absorbing the absent delay); removal mid-play dropped every total to zero with the transport still advancing. Parity: the latent-chain + shared-send-bus project cross-diffs across two offline renders at bit-level 0.0 with all four paths coherently aligned (single hit, peak exactly 1.0).
- **M4 (viii) PDC v0 is complete** (viii-a planner, viii-b ring, viii-c wiring/reporting, viii-d parity). M4 now stands finished except the parked (i) live mid-play send-activation defect (workaround: stop/play). Next: M5 editing depth.

## 2026-07-05 — M4 (viii-b): the PDC compensation ring
- The delay that makes compensation real: `CompensationDelayState` — per-channel power-of-two Float rings (32 768/channel, 16 384-sample cap + quantum headroom), allocated only at prepare, driven by a heap-atomic target and reset flag (the bypassFlag pattern) with render-only cursor state. Inserted in ChainHostAU between the chain walk and the vol/pan automation stage, and in InstrumentRenderer on both the main and idle/silence paths so ring history stays continuous across idle quanta. Retargets declick by dual-reading the ring at old and new offsets and crossfading over ≤128 samples; resets (transport start/seek/cold start/offline start) zero the rings and snap without a fade. A clean-history zero-target fast path provably never touches the buffer — PDC is bit-inert until a real target arrives.
- `PlaybackGraph` gains `setCompensationTarget(_:forStrip:)` (the surface viii-c's recompute will drive) and arms ring resets exactly where chain resets already happen. One documented deviation: the v0 loop wrap flushes rings, because this engine's wrap IS a transport restart where chain tails are already cut — carrying ring history there would be the inconsistent choice; the spec's no-flush rule activates when a seamless wrap ships.
- Verified: 578 tests in 66 suites (+7, +1 suite), 0 warnings, independent build + suite run. Measured: uncompensated impulses at frames 4800/5040 collapse to a single coherent 0.5-amplitude peak at 5040 under the hand-computed plan; equal-target inverted render nulls to exactly 0 nonzero samples; 512 adversarial bit patterns (subnormals, odd mantissas) pass through the inert path bit-unchanged; the retarget fade region is bit-equal to the crossfade formula; a reset kills the 240-sample stale tail to exact zeros; two renders bit-identical.

## 2026-07-05 — M4 (viii-a): PDC plan math + settled latency-compensation design
- The PDC design is settled (architect spec, recorded in ARCHITECTURE.md): a per-strip preallocated ring delay inside ChainHostAU, upstream of the strip mixer's fan-out so one ring aligns the dry feed and every send tap at once; staged global-max alignment (tracks pad to T, buses to B, master hears T+B) with the honest admission that exact alignment for a direct-to-master track with sends is mathematically impossible with one delay per strip — that residual is reported per-strip, and vanishes in the canonical zero-latency-bus case. Bypass-stable totals (bypass never retargets the mix; the ring absorbs the difference), per-strip atomic u32 retargets (not snapshot republishes), dual-read crossfade declick, v0 output-delayed timeline, rings reset at transport/render start for exact offline parity. Item (viii) split into viii-a…d.
- viii-a lands the pure planner in DAWCore: `PDCPlan.compute(input:cap:)` over per-strip (chainLatencyAll, chainLatencyActive, kind, routing) → per-strip planned/applied compensation with clamped flag and residual, skew reporting, and T/B/maxPathLatency — deterministic, Sendable value types, garbage-tolerant (hostile hosted-AU latencies clamp instead of crashing). The engine ring (viii-b), recompute wiring + snapshot fields (viii-c), and parity harness (viii-d) follow.
- Verified: 571 tests in 65 suites (+15, +1 suite), 0 warnings, independent build + suite run + code review of the planner against the spec (worked example verbatim: comp(A)=240, comp(B)=0, T=240, B=0, zero skew). Ops note: the design cycle survived three agent stream-stalls (one watchdog kill + resume, one self-recovery mid-write) — the spec came out complete and source-verified despite them.

## 2026-07-05 — M4 (vii-e): arrange automation lane UI — automation v0 complete
- Automation becomes drawable: each track header grows a disclosure glyph (cyan glow when lanes are active) that expands an automation row under the clip lane — VOL/PAN target picker, green ON/OFF enable, delete, and a Canvas breakpoint editor sharing the arrange view's exact beat→x mapping. Click empty space to add a point, drag with a live value/beat readout, double-click or ⌫ to delete; segments render as a neon polyline (bloom-under-core glow, glowing dots, dashed neutral guide), dimmed when the lane is disabled; pan lanes draw neutral-white per the mixer's pan convention. Drags commit per-tick through `setAutomationPoints` for live audible feedback, riding the store's `automation.points:<laneID>` undo-coalescing key, with the draft re-seeded from the store's canonical sorted result at gesture end.
- All geometry, hit-testing, edit ops, and readout formatting live headless in `DAWAppKit.AutomationLaneModel` (16 tests); every mutation goes through the vii-a store methods — the view never touches `Track.automation`. A debug-tier `ui.showAutomation {trackId}` command (ui.showMixer precedent, not on the MCP surface) lets headless runs open the row for capture. The pattern is codified in DESIGN-LANGUAGE.md.
- Verified: 556 tests in 64 suites (+16, +1 suite), 0 warnings, and three live captures — the agent's (volume lane, five breakpoints landing exactly on bars 1–5 under the clip) plus two independent orchestrator captures: a pan lane drawn over the wire rendering hard-L→center→hard-R precisely against the center guide with correct hold-after-last-point, and the disabled state showing OFF + dimmed polyline. **This completes automation v0** (vii-a…vii-e); vii-f (touch/latch/write recording, sendLevel engine, AU-param lanes, master lanes, bezier) stays deferred.

## 2026-07-05 — M4 (vii-c): built-in FX-param automation lanes
- Automation now reaches inside the built-in effects: a lane targeting any of the nine kinds' parameters (delay mix, EQ band gain, compressor threshold, …) evaluates at each quantum start and stores straight into the effect's render-thread state before the chain walk — no locks, no allocation, no graph churn. `AutomationSchedule` grew POD `effectParam` breakpoint tracks (paramName resolved to a spec slot on the main actor; unresolvable lanes never reach the schedule; 64 tracks per strip, matching preallocated cursors), and `AutomationRenderer.storeEffectParams` shares generation-adoption helpers with the gain/pan path so the two consumers can never disagree on position.
- The per-kind lock-free-POD audit found a uniform hazard: every built-in's main-actor `apply` allocates (snapshot box + retire-bin append), so all nine got a lean render-thread setter that adopts pending snapshots through the same atomic slot `process()` reads, then re-derives through the existing per-kind math (pure libm/arithmetic everywhere; limiter lookahead fixed-size so lines never resize; delay/reverb/chorus time-type params are read-offset changes on MAX-sized lines). A value-type `AutomationParamOverlay` keeps knob (base) and automated (effective) params split, reverting to knob values within one quantum when a lane is disabled or removed — without it the effect stayed stuck on the last automated value forever.
- Verified: 540 tests in 63 suites (+7), 0 warnings, independent build + suite run. Measured: gain-lane staircase settles within 7.07e-09 of the analytic quantum-start value with exactly 0.0 intra-quantum spread; automated delay-mix bounce shows 0.0 in the dry region despite knob mix 0.7 (lane wins), bit-identical across two bounces; bypassed-effect-with-lane null 0 differing bit patterns; ghost-effect/out-of-range/NaN stores inert; mid-play lane edits republish with the MIDI schedule object-identical.

## 2026-07-05 — M4 (vii-b, vii-d): automation playback engine + control/MCP surface
- Volume and pan lanes now play back sample-accurately. Each strip owns a permanent `AutomationRenderer` publishing immutable `AutomationSchedule`s through the same atomic-pointer/retire-bin discipline as the MIDI scheduler; evaluation runs at the end of the chain walk (ChainHostAU for audio/bus strips, InstrumentRenderer for instruments) with per-sample linear ramps — the offline bounce matches the analytic ramp within 7.4e-9, and an automated pan lane sitting at center leaves buffers bit-identical. An enabled volume lane replaces the fader (the mixer node is pinned; mute/solo gating untouched); while stopped, the lane value at the playhead is applied WYSIWYG. Point edits during playback republish without any restart — proven by object-identity on the MIDI schedule across a mid-play edit, and live: editing points mid-loop dropped the meter with playback position advancing continuously. Live and offline render paths agree with cross-diff exactly 0.0.
- The wire surface: `automation.addLane|removeLane|setPoints|setLaneEnabled` round-trip the target and point shapes through the model's own Codable (the wire can never drift from persistence), malformed points fail with per-index errors, and v0 rejections (send-level, AU-param targets) surface the store's exact message. Snapshots carry each track's lanes via the existing Track encoding — zero extra wiring. Four MCP tools (51 total) tell AI agents how to draw rides, fades, and filter sweeps.
- Verified: 533 tests in 62 suites (+21 over vii-a's 512), 0 warnings, plus a 15/15 live E2E: drawn fade bounce hit the analytic envelope (mid-fade ratio 0.476 vs 0.5 expected), mid-play edits took effect with transport rolling, disabling the lane returned control to the fader, lanes persisted through reopen. Ops note: two agent stream-stalls this cycle were recovered via transcript resume + a fresh narrowly-scoped test agent; no work lost.

## 2026-07-05 — M4 (vii-a): automation domain model + store CRUD
- The automation foundation lands in DAWCore, headless: `AutomationLane` (one per target per track, store-enforced) with `AutomationTarget` (.volume/.pan plus persistence-stable-but-v0-rejected .sendLevel and .audioUnit-effect params — honest deferrals, not silent failures), canonically ordered `AutomationPoint`s (linear/hold segment curves; bezier is an additive future case), and one pure evaluator `value(atBeat:)` shared by UI, engine main-actor side, and tests. Values clamp through each target's existing range (volume/pan/send/effect-param specs); unknown targets are hard errors.
- Store CRUD ships with the full undo story: idempotent `addAutomationLane`, whole-array `setAutomationPoints` (4096-point cap, `automation.points:<laneID>` coalescing), enable toggle, and cascade rules — removing an effect, send, or bus drops the lanes targeting it inside the same undo step. Persistence is additive: `TrackDocument.automation` is omitted when empty so pre-automation projects save byte-identical, no schema bump.
- Verified: 512 tests in 60 suites (+19, exact contract test names), 0 warnings, independent build + suite run. Architect design (evaluation inside owned render code via immutable atomic-published schedules, fader-override rule, no-restart point republish) recorded as a settled ARCHITECTURE entry; engine read path is (vii-b), control/MCP surface is (vii-d).

## 2026-07-05 — M4 (vi): full mixer view
- The mixing console lands: a horizontal rack of channel strips in the glass-cockpit language — kind badge (audio green / instrument cyan), insert list with bypass glow dots and empty states, sends with destination + mini-fader, output picker (Master or any bus), pan knob, long-throw fader with unity detent and monospaced dB readout, Mute (red) / Solo (cyan) / Arm (amber breathing halo) buttons, and a live glowing meter per strip. Buses render as a visually divided group (no arm/sends/output, per the routing model); the MASTER strip is pinned right with an accent border and stereo meter. ARRANGE⇄MIX toggle in the header; every control drives ProjectStore directly so undo/coalescing come free.
- Pure strip-derivation/formatting/geometry logic lives in `DAWAppKit.MixerModel` (headless, 10 tests); the console itself is Canvas-drawn custom controls (`VerticalFader`, `PanKnob`, `SendMiniFader`), not stock AppKit. A minimal debug-tier `ui.showMixer` command (same tier as `debug.captureUI`, not on the MCP surface) lets headless runs drive the view for self-render verification. The strip anatomy and control-color semantics are codified in DESIGN-LANGUAGE.md as the "Mixer console" pattern. Master insert chain deferred until DAWCore grows a master effect chain; hosted-AU insert picking from the UI deferred (control-plane adds work today).
- Verified: 493 tests in 58 suites (+10), 0 warnings, and two independent live captureUI renders (agent's and orchestrator's) confirming full strip anatomy with real content — audio + instrument + bus tracks, a −3.1 dB send, EQ/Compressor/Reverb inserts — with no layout breakage.

## 2026-07-05 — M4 (v): AU effect hosting (headless)
- Third-party and Apple `aufx` Audio Units are now first-class inserts in every chain. `HostedAUEffect` adapts the AU pull model behind the `EffectRendering` seam: the incoming in-place buffers are served through a `@Sendable` pull block, rendered into a preallocated scratch buffer, and copied back — no allocation or main-actor state on the render path; a render failure passes dry rather than silencing the strip. The registry reuses the instrument hosting machinery (timeout-raced instantiate/prepare, strict-select on explicit add, placeholder-with-warning on project open), and adds are async-prepare → single-strip republish — playback never stops, the graph is never rebuilt.
- Real plugin latency lands on the wire: `latencySamples` comes from `au.latency` at prepare (AUPeakLimiter: 96 samples @ 48 kHz) and feeds the same per-effect plumbing the built-in limiter uses — PDC groundwork. AU fullState persists in `.dawproj` (set a parameter, save, reopen — it's restored). New `fx.listAudioUnits` command + `fx_list_audio_units` MCP tool (47 total); `fx.add` takes `kind: "audioUnit"` with a fourCC triple. Hosting bug found and fixed along the way: the AUv2 bridge leaves the input bus disabled by default, which fails renders with kAudioUnitErr_NoConnection until enabled before allocateRenderResources.
- Verified: 483 tests in 57 suites (+11), measured: AUDelay impulse delayed to frame 48001 (Δ1 sample from nominal at its parameter-tree-read 1.0 s default), AULowpass fullState round-trip restores 1234 Hz exactly, placeholder passthrough bit-exact. Live E2E 12/12: 23 aufx components listed, AUDelay echoes in the bounce window (0.2018 vs dry 0.0000), mid-play AUPeakLimiter add with continuous playback and latency 96 on the wire, bogus component rejected with a pointer to fx.listAudioUnits, hosted AU survives reopen.

## 2026-07-05 — M4 (iv): built-in FX pack 2 — reverb, delay, saturator, gate, chorus
- The space-and-color pack completes the built-in FX suite (9 kinds). Freeverb-topology reverb (8 damped combs + 4 series allpasses per channel, 23-sample stereo spread, up to 200 ms pre-delay, mid/side width control); stereo delay with integer-sample lines (echo lands at exactly round(timeMs×rate/1000) samples), feedback-path high-cut, and ping-pong crossfeed; tanh saturator with fixed −driveDb/2 dB level compensation (documented alias-honest, no oversampling in v0); stereo-linked noise gate whose ramps land exactly on 1/0 — fully open is bit-exact passthrough, fully closed writes true zeros; and a 2-voice chorus (sine LFO around a 15 ms center, 90° stereo / 180° inter-voice phase offsets).
- All five follow the pack-1 RT-safety conventions: atomic POD param publishes with a ≥1 s retire bin, prepare-time allocation, denormal flushes, zero added latency. Params live on the generic `fx.setParam` surface with schemas in `fx.describe`; MCP kind enum now spans all nine.
- Verified: 472 tests in 56 suites (+14), measured: delay echoes at samples 16800/15984/48 exactly with feedback ratio 0.5000000023, saturator H3/H1 = 0.316 with even harmonics at 1.1e-15, gate open-null 0.0 and closed residual 0.0, reverb tail decays ~32 dB from early to late window, all five render-to-render deterministic (diff 0.0). Live E2E 12/12: delay echoes ring in the 0.8–1.2 s bounce window (0.0909 vs dry 0.0000), mid-play reverb add with continuous playback, −1 dB gate silences to 0.0000 live, saturator+chorus chain audible, five-kind persistence round-trips.

## 2026-07-05 — M4 (iii): built-in FX pack 1 — EQ, compressor, limiter
- Three real processors join the insert chain: a 4-band parametric EQ (low shelf, two peaking bands, high shelf — RBJ biquads with Float64 accumulators; 0 dB bands are skipped so neutral settings null bit-exact), a soft-knee stereo-linked compressor (true peak detector, log-domain quadratic knee, one-pole attack/release, makeup), and a 5 ms-lookahead brickwall limiter whose output can never exceed the ceiling — guaranteed for every sample by construction (monotonic-deque sliding-window max), not just after settling.
- The limiter is the first effect with real latency: `latencySamples` (240 @ 48 kHz) now flows per-effect from the live DSP instance through the engine protocol and store to every snapshot and fx.* response — the PDC groundwork M4 (viii) will consume. All params live on the generic name/value surface with schemas in `fx.describe`/MCP (kind enum now gain|eq|compressor|limiter).
- Verified: 458 tests in 55 suites (+14), measured: EQ boost +11.99999999 dB on target band (+0.16 dB bleed at 100 Hz), compressor static curve −14.88 dBFS vs −15 theory with nominal 63% attack/release points, limiter impulse exactly 240 samples late, chain determinism nulls 0.0. Live E2E 14/14: mid-play EQ shelf cuts to ratio 0.026, heavy squash to 0.028, wire latency 240, boosted bounce peak exactly at the −6 dB ceiling (0.5012), all kinds persist.

## 2026-07-05 — M4 (ii): FX insert-chain architecture
- Every track and bus now has a pre-fader insert chain. The architecture answer to the M4 (i) live-mutation bugs: a permanent per-strip insert point (`ChainHostAU`, an in-process runtime-registered Audio Unit — spike-proven to instantiate synchronously from the SPM binary with bit-exact passthrough) walks an atomically published immutable chain snapshot. Chain edits — add, remove, reorder, bypass, param — are lock-free publishes and NEVER touch graph topology; instrument tracks process their chains inside the existing renderer. Effect DSP state survives reorders; un-bypass resets tails; every effect reports latency for future PDC.
- New `fx.*` command family (add/remove/reorder/setBypass/setParam/describe — `fx.describe` serves param schemas so agents can discover controls) + 6 MCP tools (46 total). Chains persist additively in `.dawproj` (unknown future kinds drop with a warning instead of failing the load). v0 ships the gain/trim effect to prove the seam; the real FX arrive in M4 (iii)/(iv) as `EffectRendering` implementations.
- Verified: 444 tests in 54 suites (+29), all chain-math nulls bit-exact (×0.5 gain, compose, bypass, empty-chain transparency on audio AND bus sandwiches, order-dependence). Live E2E 16/16 — the headline: mid-play `fx.add` gain 0.25 dropped the track meter to ratio 0.257 with playback position advancing continuously (no transport cycle, no glitch), live bypass/param/reorder all seamless, bounced gain ratio exactly 0.5000, persistence round-trips.

## 2026-07-05 — M4 (i): bus routing & sends (landed with one known live defect)
- Bus tracks are now real mix destinations: route any audio/instrument track's output to a bus (`track.setOutput`, nil = master) and add post-fader sends into buses (`track.addSend`/`setSend`/`removeSend` — one per destination, levels clamp 0–2). Engine: per-bus mixers + dedicated send-gain nodes behind AVAudioEngine fan-out connections; send LEVEL changes are provably non-structural (fader drags never interrupt audio — pinned); structural routing edits ride a quiesce → engine-bounce → transport-primitive resume. Solo v0 is solo-in-place (soloing a track keeps its send buses audible; soloing a bus keeps its feeders audible); bus deletion reroutes orphans to master and drops its sends in one undo step. Buses meter like tracks; persistence is additive (`outputBusId`/`sends`, pre-M4 bundles byte-identical); 4 new MCP tools (40 total).
- Verified: 415 tests in 50 suites (+31), incl. exact gain math (0.5 send × 0.5 bus = ×0.25 measured), bit-exact unity-bus null, solo matrix, both-restart-paths-identical regression. Live E2E 18/19; two live-only engine bugs were found by verification — a segfault removing a live bus (FIXED: fan-out severed before node teardown + engine bounce for structural rewires) and silent mid-play send addition (NOT yet fixed after two rounds — parked under Blocked; workaround: stop/play revives the send; everything else works live).
- Roadmap box (i) deliberately unchecked until the remaining defect clears.

## 2026-07-05 — M3 (vii): MIDI hardware input — M3 COMPLETE
- Plug in a MIDI keyboard and play: CoreMIDI input (UMP protocol-1.0, omni-connect, hot-plug) feeds armed instrument tracks live — through the poly synth, sampler, or a hosted AU — with ≤ one buffer of latency, even while the transport is stopped. The path is fully real-time-safe: the CoreMIDI receive thread pushes 16-byte events into per-renderer lock-free SPSC rings behind an atomically published fanout; render quanta merge live events with the schedule (schedule wins ties, so off-before-on survives); ring overflow flags an all-notes-off so a lost note-off can never stick a voice.
- Recording captures incoming MIDI on armed instrument tracks using the exact same host-time anchor as audio takes — audio and MIDI recorded together land in one "Record Take N" undo step. Open notes clamp at stop, retriggers close the previous note, pre-anchor (count-in) notes drop. Punch windows trim audio only in v0 (pinned by test). New: `midi.listInputs`, snapshot `midiInputs` + pollable `midiEventCount`, `midi_list_inputs` MCP tool (36 total); arming now works on instrument tracks.
- Found & fixed during integration: the CoreMIDI receive block inherited @MainActor isolation and trapped on the real receive thread — the project's documented Swift 6 pitfall, third occurrence; now pinned by an in-process CoreMIDI integration test with a real virtual source.
- Verified: 384 tests in 46 suites (+38). Live E2E 4/4 via a virtual MIDI source against the running app: hot-plug discovery, live-thru meter rise/decay while stopped, a recorded arpeggio landing as one clip with exact pitches on beats 0/1/2/3 (±0.1), and single-undo take removal.

## 2026-07-05 — M3 (vi-a): AU instrument hosting (headless)
- Third-party and Apple instrument plugins now play inside DAW Pro: AUv2/v3 music devices are discovered (`instrument.listAudioUnits`), instantiated asynchronously with a timeout race (a stalled plugin can never hang the app — it degrades to a silent placeholder with a readable `status`), and hosted behind the same `InstrumentRendering` seam as the built-ins. Our sample-accurate scheduler remains the only clock: note events reach the AU via `scheduleMIDIEventBlock` at in-quantum sample offsets; stop/seek flush maps to CC 123 + 120 (the render thread never touches the AU's ObjC surface — only two blocks captured at init).
- Component identity + full plugin state (`fullStateForDocument`) persist in `.dawproj` (additive, base64); projects referencing an uninstalled AU keep the descriptor intact and load silently with `status: "missing"`. `track.setInstrument` gains `audioUnit: {type, subType, manufacturer}` (strict selection with discovery hint); MCP adds `instrument_list_audio_units` (35 tools). `render.mixdown` became async end-to-end — offline renders instantiate fresh AU instances so live playback is never disturbed.
- Verified: 346 tests in 39 suites (+15), incl. DLS onset energy windows (pre-onset exactly 0.0, body RMS 0.062), note-off decay ratio 0.093, reset-flush 0.064 → 0.0002, AUSampler fullState round-trip (1290-byte plist → fresh instance ready), 100ms-timeout fallback. Live E2E 13/13: GM piano audible through hosted DLSMusicDevice (peak 0.10), stop flushes to 0.0000, save/reopen keeps identity and re-readies, bounced WAV peak 0.124.

## 2026-07-05 — M3 (v): built-in sampler
- Instrument tracks can now play audio files across the keyboard: `SamplerZone`s map files to key spans with a root pitch; playback resamples by `2^(Δsemitones/12)` (linear interpolation, native-rate buffers loaded immutably at reconcile — never on the render thread), first-matching-zone routing, one-shot mode for drums (ignores note-off), anti-click attack/release ramps. Zone changes rebuild the track's node; scalar tweaks (one-shot/attack/release/gain) update in place mid-note via the atomic-publish pattern.
- `track.setInstrument` gains a `sampler` object (zones wholesale-replaced like clip notes; field-path validation errors); the MCP tool mirrors it. Sampler zone files become project media: saved bundles copy them into `media/` (deduped, relative refs, counted in `mediaFilesCopied`) and reopened projects rewrite zone paths into the bundle.
- Verified: 331 tests in 36 suites (+22), incl. measured 440.000/880.000/220.000 Hz transposition through 44.1k→48k conversion, frequency-proven zone routing, exact-zero release tails, determinism nulls. Live E2E 16/16: two-zone kit audible (system sounds), mid-play one-shot/gain update gapless, save copied 2 zone files into the bundle, reopened bundle paths load and sound, bounced WAV peak 0.210.

## 2026-07-05 — M3 (iv): built-in poly synth
- The default sound of instrument tracks is now a real 16-voice subtractive synth: PolyBLEP-corrected saw/square (aliasing suppressed), triangle, sine; linear ADSR with exact-zero release tails; per-voice Simper SVF low-pass (cutoff/resonance); velocity scaling + output gain. Parameters live on the track as `InstrumentDescriptor` (additive model field, nil ⇒ default) and update in place mid-note via the scheduler's atomic-publish pattern — tweaking the filter never cuts held voices; switching instrument kind (polySynth ↔ testTone) rebuilds just that track's node.
- New `track.setInstrument` control command (partial update: omitted fields keep current values, numbers clamp) + `track_set_instrument` MCP tool (surface now 34). Snapshot always shows the resolved descriptor on instrument tracks, omits it on audio tracks. Undo label "Change Instrument" (coalescing); persistence is additive so older .dawproj bundles still open.
- Verified: 309 tests in 34 suites (+29), incl. Goertzel harmonic identity (square H2/H1 = 1.6e-16 vs saw 0.499), ADSR frame timing, 17-note oldest-steal, bit-identical determinism nulls. Live E2E 23/23: sine chord audible (RMS 0.168), mid-play cutoff change keeps sounding (RMS 0.164), mid-play kind switch survives, undo/redo, save/reopen keeps the descriptor, bounced WAV peak 0.783.

## 2026-07-05 — M3 (iii): sample-accurate MIDI scheduler
- MIDI clips now make sound. One `AVAudioSourceNode` per instrument track pulls from an immutable, pre-built event schedule published through a C11 atomic pointer (new `CAtomics` shim target) — the render thread never allocates, locks, or touches Swift shared state. Live playback derives sample time from the shared host-time anchor (host-delta epoch); offline render latches the first `mSampleTime`. Every stop/seek/tempo/loop-wrap/reschedule raises a flush flag → all-notes-off + `reset()` on the next quantum.
- New `InstrumentRendering` seam (AU-shaped for M3 vi) with `TestToneInstrument` (16-voice sine) and `EventCaptureInstrument` (test-only event ring). Cross-kind solo now works: soloing an instrument track silences audio tracks and vice versa. This settles the sequencer-clock decision in ARCHITECTURE.md.
- Verified: 280 tests in 32 suites (+20), incl. frame-exact event timestamps (on p60 @ sample 24000, off @ 48000 — exact `==`), 0-frame-tolerance onsets, bit-identical 512-frame-quantum captures, exact-zero null tests. Live E2E 8/8: audible arpeggio (track RMS 0.139), mid-play `clip.setNotes` reschedule survives, mute → 0.0000 RMS, bounced WAV peak 0.197.

## 2026-07-05 — M3 (ii): piano-roll editor + timeline lanes
- Timeline lanes replace the arrange placeholder: per-track clip blocks (green audio / cyan MIDI / violet AI), bar ruler, glowing playhead. Piano roll (bottom panel): keyboard sidebar, snap grid (Off/Bar/Beat/1/8/1/16), add/move/resize/select/delete, velocity lane, Simple ↔ Pro modes — all edits drafted locally, submitted as whole-array `setClipNotes` (one undo step per gesture).
- New `DAWAppKit` library target holds the testable geometry model (16 unit tests). New `debug.captureUI` control command: the app renders its own window to PNG (no Screen Recording permission needed) — now the standard UI-verification path; `selectClip` param opens the piano roll for capture.
- Verified: 260 tests in 29 suites; pixel-level inspection of a live capture — the sent arpeggio renders exactly (positions, lengths, velocity→brightness), selection glow, design-language chrome throughout.

## 2026-07-05 — M3 (i): MIDI domain + commands
- `MIDINote` model + `Clip.notes` payload (mutual-exclusion invariant with audio; canonical sort; clamped values; non-destructive clip bounds; overlaps legal — the scheduler contract is locked in now). Commands `clip.addMIDI` / `clip.setNotes` (whole-array replace — one agent call writes a melody) / `clip.remove` + MCP tools (33 total). Persistence: additive `notes` field, schema stays v1. Undo: per-clip coalescing key.
- M3 decomposed into 7 dependency-ordered sub-items (piano roll, scheduler, synth, sampler, AU hosting [needs Xcode license], MIDI input).
- Verified: 240 tests in 28 suites; live E2E 18/18 — arpeggio written in one call, verbatim validation errors, undo restores melodies, notes survive .dawproj round-trip. MIDI clips are silent by design until the scheduler + instruments land.

## 2026-07-05 — M2 COMPLETE: pinned-device recording fixed
- Root cause found by experiment (the parked theory was disproven): (1) the same-device guard compared uids against the input engine's PRIVATE AGGREGATE device ID, so it never skipped; (2) the pin-induced benign AVAudioEngineConfigurationChange (~65 ms post-start, engine still running) was treated as fatal, silently self-aborting every pinned take.
- Fixes: two-phase InputCapture start (pin → format → writer → tap), guard now compares against the system default input, config-change triage (benign vs fatal), plus a 1.5 s first-buffer watchdog with a readable abort error.
- Verified: 216 tests in 24 suites; live E2E 10/10 including a real take on a pinned device; agent also live-tested ZoomAudioDevice (frames flowed) and unpinned regression.
- **M2 (recording & persistence) is now fully complete** — nothing parked.

## 2026-07-05 — M2: undo/redo (snapshot journal)
- Full undo/redo across all 16 document mutators: before-state snapshot journal (architect overruled the roadmap's "command-pattern" wording — closure mutators can't be inverted; COW makes KB snapshots free), 800 ms keyed coalescing (fader drag = 1 step, 8 agent commands = 8 steps), 100-entry cap, load barrier on open/new, refused while recording, async take completion lands on top.
- `edit.undo`/`edit.redo` commands + `edit_undo`/`edit_redo` MCP tools (30 total) + Edit menu ⌘Z/⇧⌘Z with live labels; `undoLabel`/`redoLabel` in snapshots.
- Post-review fixes: state-dependent labels (Arm/Mute/Solo were literal "Arm/Disarm" strings).
- Verified: 215 tests in 24 suites; live E2E 13/13 — coalesced burst undone to origin in one step, real recorded take undone ("Record Take 1" → clip removed, WAV kept), redo semantics, mid-take refusal.
- **M2 complete** except the Blocked pinned-device capture item.

## 2026-07-05 — M2: .dawproj project persistence
- Self-contained `.dawproj` bundles: versioned project.json (schema v1, git-diffable, no transient state) + media/ with dedupe and collision suffixes; open/save/save-as/new with flush-by-default transitions; 30 s autosave (in-place for titled, JSON recovery bundle for untitled); ⌘N/⌘O/⌘S/⇧⌘S in the app.
- Commands `project.save/open/new` + MCP tools `project_save/open/new` (28 total). Undo/redo seams left ready (markDirty funnel, applyOpenedState primitive).
- Verified: 174 tests in 21 suites; live E2E 15/15 — on-disk schema inspected, dedupe (2 clips → 1 file), idempotent re-save (0 copies), reopened project audible via meters, missing-media warnings, newer-version rejection.

## 2026-07-05 — M2: metronome + count-in
- Synthesized click (downbeat 1600 Hz accented, beats 1000 Hz) scheduled sample-accurately on its own player node, with top-up while rolling; `transport.setMetronome` command + `transport_set_metronome` MCP tool (25 total) + CLICK chip. Count-in (0-4 bars) delays the record anchor — clicks fill the gap, the take never includes them.
- Verified: 152 tests in 20 suites (offline: clicks at exact beat frames, correct pitches, 3/4 downbeats); live E2E 9/9 — click audible on an empty project via meters, silent when off, real count-in take excluded exactly the count-in duration.

## 2026-07-05 — M2: punch in/out recording
- `transport.setPunch` command + `transport_set_punch` MCP tool (24 total) + PUNCH chip: recording keeps only audio inside [inBeat, outBeat]; the take clip lands at punch-in with the window's length. Validation: range checks, refused mid-take, refused when the window is behind the playhead.
- Writer generalized to a two-sided accept window with a separate anchor-relative offset reference (one placement bug found by live E2E and regression-locked as W5); degrades honestly to a full take on timestamp-broken devices.
- Verified: 139 tests in 19 suites; live E2E 8/8 with REAL capture — punch [1,2] @120 BPM from beat 0 produced a clip at exactly startBeat 1.000, lengthBeats 1.000.

## 2026-07-05 — M2: input device enumeration/selection (partial)
- `input.listDevices` / `input.setDevice` commands + `input_list_devices` / `input_set_device` MCP tools (23 total) + themed input-picker chip in the header. CoreAudio HAL enumeration verified live (4 real devices found, default flagged); selection/validation/reset all verified over the control port; RecordingWriter hardened against invalid input timestamps (regression-tested).
- KNOWN ISSUE (see ROADMAP Blocked): recording with a *pinned* device captures zero frames — unpinned recording unaffected (re-verified live). 123 tests in 19 suites green.

## 2026-07-05 — M2: audio recording (Stage A)
- Arm tracks (`track.setArm` + `track_set_arm` MCP tool, "R" chip) and record the default input (`transport.record` + `transport_record` tool, wired record button; 21 MCP tools total). Record = capture + play; takes land as clips on every armed track (one shared WAV, host-time-aligned to the player start anchor, ±1 frame).
- Architecture: separate input-only AVAudioEngine (playback survives input device changes), serial-queue RecordingWriter (Float32 WAV at device rate, ≤2 ch), seek/tempo refused mid-take, loop wrap suspended while recording. Known v0 gap: no round-trip latency compensation (M4 PDC).
- Verified: 110 tests in 17 suites (writer bit-exact vs on-disk WAVs, alignment trim ±1 frame, permission/state-machine coverage); live E2E 10/10 including a REAL capture — 1.5 s of mic input became clip "Vocal Take 1" via the control protocol.

## 2026-07-05 — M1 COMPLETE: render.mixdown + test harness
- `render.mixdown` command + `render_mixdown` MCP tool (19 total): offline bounce to Float32 stereo 48 kHz WAV, default duration = project length + 0.5 s tail, default temp path, readable errors ("nothing to render…").
- Engine test harness closed: determinism null test (two renders per-sample identical, exactly 0.0), unity-graph-vs-source null, gain assertions.
- Verified: 88 tests in 15 suites; live E2E 8/8 — bounced WAV confirmed by afinfo (2.0015 s, 48 kHz, 772 KB), bit-exact write round-trip.
- **M1 (core audio engine) is complete**: import, sample-accurate multitrack playback, transport with loop + broadcast, per-track metering, wired mixer, offline mixdown.

## 2026-07-05 — M1: mixer parameters wired to engine
- Track volume/pan/mute/solo now audibly control the engine (per-track mixer nodes; parameter changes never interrupt playback). New master volume: `mixer.setMasterVolume` command + `mixer_set_master_volume` MCP tool (18 total) + vertical glow fader in the transport bar; `masterVolume` in snapshots.
- Two AVFoundation quirks found by experiment and worked around: mixer pan set before `engine.start()` is discarded, and same-value pan writes are swallowed by the property cache after an AU reset.
- Verified: 74 tests in 13 suites (offline renders: volume 0.5 → RMS exactly halved, mute/solo/master-0 → digital silence, pan −1 → right channel 0.0); live E2E 7/7 via snapshot meters (incl. pre-master vs post-master metering distinction).

## 2026-07-05 — M1: per-track + master metering
- Per-track meter taps on the track mixers → glowing MiniLevelBars in the track list; meters now included in `project.snapshot` (`meters.master` + `meters.tracks` keyed by track UUID) so AI agents can verify audio is actually rendering.
- Meters reset to silence on stop; entries dropped with their track.
- Verified: 64 tests in 12 suites (offline meter RMS within 5e-5 of theoretical); live E2E 5/5 — track + master meters register signal during looped playback over the control port, silent after stop.

## 2026-07-05 — M1: loop region + transport broadcast
- Loop region: `transport.setLoop` command + `transport_set_loop` MCP tool (17 total) + LOOP chip in the transport bar; engine wraps at loop end via the restart primitive (~60 ms gap, documented v0).
- Transport broadcast: control clients now receive pushed `{"event":"transport",...}` frames — immediately on state changes, ~4 Hz while playing — instead of polling; MCP bridge tolerates event frames.
- Verified: 59 tests in 11 suites; live E2E 8/8 (wrap bounded at loop end, 22 events over 5.5 s, loop-off passthrough, push-on-change while stopped).

## 2026-07-05 — M1: sample-accurate multitrack playback
- New engine core: per-clip AVAudioPlayerNodes under per-track mixers (overlapping clips sum), schedule math in exact file-rate frames, shared host-time start anchor, stop-reschedule-resume primitive for seek/tempo/mutations during playback, engine-derived playhead at 30 Hz.
- `OfflineRenderer` renders the same graph headlessly (manual rendering mode) — now the sample-accuracy test harness, later `render.mixdown`.
- Engine protocol: `transportDidChange` → four intent methods (`startPlayback/stopPlayback/seek/setTempo`) + `playheadHandler`.
- Verified: 48 tests in 10 suites; measured onset error 0 frames same-rate, +17 frames through 44.1→48 kHz SRC (±64 spec, pitch-verified); live E2E 7/7 (playhead rate, import-while-playing, seek/tempo mid-playback, stop/resume).
- Notable fix found during implementation: track mixers must connect at explicit graph-rate format — `format: nil` leaves them at 44.1 kHz and silently double-resamples.

## 2026-07-05 — M1: audio file import
- `clip.addAudio` control command + `clip_add_audio` MCP tool (16 tools total): import wav/aiff/mp3/m4a onto audio tracks; length auto-computed from duration at current tempo, append-after-last-clip default, `atBeat` override.
- New: `AudioFileInfo`/`MediaImporting`/`ProjectError` (DAWCore), `AudioFileImporter` via AVAudioFile (DAWEngine), clip-count badges in the track list.
- Verified: 29 Swift tests in 7 suites; live E2E 10/10 against the running app incl. real AIFF import (1.5 s → 3.003 beats @ 120 BPM), readable errors for missing files and non-audio tracks.

## 2026-07-05 — M0 Foundation
- SPM monorepo: DAWCore (domain), DAWEngine (AVAudioEngine + metering + test tone), DAWControl (loopback WebSocket control server, 12 commands), AIServices (Anthropic/OpenAI/Suno/GPT-Image clients), DAWApp (SwiftUI glass-cockpit shell).
- MCP server (`mcp-server/`, TypeScript): 15 tools — 12 bridged DAW commands + generate_lyrics / generate_song_suno / generate_image.
- 17 Swift tests passing (`./scripts/test.sh`); live E2E: 11/11 control-protocol checks against the running app.
- Fixed: Swift 6 isolation trap in the metering tap (`@Sendable` on the AVFAudio tap closure).
- Docs: VISION, ARCHITECTURE, ROADMAP (M0–M9), AI-INTEGRATIONS, DESIGN-LANGUAGE. Agent fleet (8) + skills (6).

## 2026-09-04i — the lesson wave: 20 videos, and four gates that were not gates

**Videos.** Eight lessons (L1–L8) and twelve Shorts now exist, all
`verify.py`-green and all shipped to `~/Movies`. Tracker: `docs/lessons/PROGRAM.md`.

**`brand.json` was making a false claim on every video.** `line2` read
"Written, mixed and measured in DAW Pro" — true for the DAW-built lessons, not
true for the Shorts, L2 or L4, whose audio is generated in Python. It now reads
"Every number in this video was measured, not estimated", which is true of all
of them, and **all 16 already-shipped videos were re-rendered**.

**A demonstration is not a bed** (`assemble.py`, `shortsmith.py`). Each stage's
audio used to carry on under the *next* stage's narration — right for music,
wrong for a measurement, and in the tuning lesson a pair of beating test tones
droned under the speaker. Stages now set `"bedEligible": false`. Verified with a
control: the same manifest with the flag stripped still beats at 6.03 Hz under
the narration; with it, 0.55 Hz.

**A `[ FAIL ]` was printed and then ignored** (`shortsmith.py`). The Amen lesson
failed its true-peak check and was copied to `~/Movies` anyway, one line below
the word FAIL. Shipping now raises on any `[ FAIL ]`; `[BROKEN]` still does not
block, since that means the probe could not judge.

**True-peak backstop** (`assemble.py`). `loudnorm`'s single-pass `TP=` is a
target, not a guarantee. The finished concat is now measured and, if over
ceiling, given a **static trim** — no limiter, no transient reshaped — then
re-measured, up to four passes, failing loudly if it will not converge.

**`factCheck` may be a list of spellings** (`shortsmith.py`). It rejected eight
perfect takes of "seventy two beats per minute" because the transcriber writes
"72". Any one listed spelling now satisfies an entry; the entry is still
required. Control-tested both ways.

**A/B stages reach `assemble.py` again** (`shortsmith.py`). `assemble.py` has
implemented before/after alternation with badges for some time, but shortsmith
never passed the spec's `ab` block through, so such a stage silently played only
the "after" file. `beforeShots`/`afterShots` are translated from card indices.

## 2026-09-04j — a session film: a whole track from four waveforms

`scripts/video/session/` drives DAW Pro over the control protocol to build a
64-bar track on camera, photograph the app doing it, and narrate it with
numbers measured off the renders. No generation model is used anywhere: every
sound is written as notes and shaped with the app's own synth and effects.

The constraint that turned out to be the story: the poly synth accepts
`saw|square|triangle|sine` and refuses `noise`, so rain, thunder, a siren and a
singing vowel all had to come out of those four. Rain is the chapter that
failed, and it stays in — spectral flatness 0.0001 → 0.0157 against white
noise's 0.5615, which is 157x better and still 36x short.

Pipeline changes this needed:

- **`shortsmith.py`: a stage can reference a captured screenshot**, not only a
  rendered card. Cards-only made it impossible to put the app on screen, which
  is the point of a session film.
- **`assemble.py`: `zoom` and `to` on a shot** — cut into a region of a
  screenshot and pan within it. Two ffmpeg facts are documented in the code
  because each cost a build: a comma inside `min()` ends `crop`'s argument list
  and is reported as a MISSING FILTER, and `crop`'s width/height are evaluated
  once at configure time, so a moving crop can pan but cannot zoom. A `to` box
  of a different size is silently ignored rather than refused.
- **`shortsmith.py` names its own work dir.** `assemble.py --work` defaults to a
  relative `segments`, which had put 325 MB at the repo root and 276 MB under
  `scripts/video` before anyone noticed. Both are now gitignored, along with all
  generated media — only the tools are tracked.
- **`install.sh` is re-runnable.** It re-attempted the omlx install every time
  and dead-ended on a requires-python bound already worked around on the first
  run, so a user adding `--publish` to a working install was told their Python
  was wrong and never reached the flag they asked for.
- **`publish.py` accepts its global flags after the subcommand** as well as
  before. `publish.py auth --client-secret X` is the obvious spelling and it
  used to die with "unrecognized arguments" naming the flag it had just
  documented one line above.
- **`upload-batch.sh`** uploads a whole wave by filename match, keeps a ledger
  so no film is sent twice, validates every sidecar offline before the first
  upload, and prints the plan before it starts.
- **Synthetic-media disclosure now defaults to true** in both the sidecar
  generator and publish.py's fallback: this kit exists to make narrated films
  and the narration is synthetic, so the default should over-disclose.
