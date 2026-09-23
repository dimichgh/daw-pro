# Public-domain classical themes for film — verified note data

Research date: 2026-09-20/21. All three works are centuries-old public-domain compositions
(oldest 1704–1750s, newest 1875) — nothing about PD status is close or contestable. The
real work here was pitch accuracy, not legal status.

**Revision note:** this replaces two earlier drafts. Draft 1 read engraved PDF scores as
*images* and pixel-estimated the denser passages — a review found its Grieg melody wasn't
scalar motion as claimed, and its Bach descending run was a fabricated 15-note scale not
actually on the page. Draft 2 went back to the **LilyPond source text** (`.ly` files Mutopia
publishes alongside every PDF — literal note names/durations as text, e.g. `b,,8 cis d e
fis`) and hand-traced LilyPond's `\relative`-octave algorithm token by token instead of
reading pixels; that fixed both melodies. A second review of draft 2 caught two more
mistakes — a transposition-interval typo and, more importantly, a place where I overrode a
correct citation (and the user's own correct belief) on the strength of a typesetter's
rendering choice instead of weighing evidence properly. Both are fixed below, in part C.

---

## A. Grieg — "In the Hall of the Mountain King" (PRIORITY)

### 1. Public-domain confirmation
- **Composer:** Edvard Grieg (1843–1907). Died 1907 → PD under any life+70 regime (expired
  1977), and separately PD in the US as a pre-1929 publication.
- **Why PD:** Composed 1875 for Ibsen's *Peer Gynt*; this excerpt is from Peer Gynt Suite
  No. 1, Op. 46, No. 4 (published 1888). Nothing unusual — a clean case.
- The Mutopia engraving I transcribed from (ref. Mutopia-2013/12/07-1888, typeset by
  "Coyau") carries its own separate public-domain dedication.

### 2. Key confirmation
**B minor** — confirmed by Wikipedia's article, by the engraving's printed 2-sharp (F#, C#)
key signature, and by every note in the traced melody below being diatonic to B minor except
two clearly-marked chromatic passing tones. (I did not directly see a `\key` directive in
the fetched source excerpt, so I'm not claiming to have read one — the signature and the
pitch content agree closely enough that I'm confident regardless.) Tempo: **"Alla marcia
molto marcato," ♩ = 138**, printed on the score and matching Wikipedia. Meter: **4/4**,
confirmed both from the engraving and from every bar's note durations summing to 4 beats
(checked by hand below).

### 3. Melody — traced from the literal LilyPond source, not pixel-read

The relevant voice, exactly as published (`rightOne`), starts:
```
<fis,, fis'>1\p\fermata->
b,,8 cis d e fis-> d fis4
eis8-> cis eis4  e8-> c e4
b8 cis d e fis-> d fis b
a fis d fis a2->
b8 cis d e fis-> d fis4
eis8-> cis eis4  e8-> c e4
b8 cis d e fis-> d fis b
a fis d fis <a, a'>2->
```
I hand-traced LilyPond's `\relative`-octave rule (each note lands in the octave nearest the
previous sounding note, before any `'`/`,` shift is applied) through all of this — it is
**not** a repeated-note ostinato as I first guessed from the image; it is exactly the
"upward scalar motion" every secondary source described: scale degrees **1-2-3-4-5-3-5**
(B–C#–D–E–F#–D–F#) as six eighth notes and a closing quarter note = one full bar, stated
twice with a chromatic "sighing" bar in between (E#→E♮, C#→C♮ — Grieg momentarily sharpens
then un-sharpens the 4th and 2nd degrees), then repeats the whole thing **one octave
higher** for the second statement — which is exactly how a theme built for a slow orchestral
crescendo would need to work. That octave relationship isn't assumed; I reran the
`\relative` algorithm fresh for bars 5–8 rather than just copying bars 1–4, and it lands an
octave up on its own.

**One notation point worth naming, now resolved simply:** plain `b` in this file is
B-natural, and B-flat is spelled `bes` — this is the same convention Bach's `.ly` source
uses below (its closing chord is written `<bes, cis e>`, and its `b` tokens are B-natural in
context), so it's consistent across two independently-typeset Mutopia files, not a one-off
guess. (An earlier pass of mine worried this might be LilyPond's Dutch/`deutsch`-style
naming, where plain `b` means B-flat and B-natural needs `h` — but that convention requires
`\language "deutsch"` or similar, isn't the default, and doesn't match either file's actual
spelling pattern. Dropping that worry.)

Octave: register matches "lowest registers of the orchestra" — the literal source's first
melodic note computes to **B2**.

9 bars total (1-bar dominant-pedal pickup + 8 bars = 2 statements of the verified 4-bar
phrase, second an octave up). All pitches below are traced from the literal tokens above,
not estimated.

```json
{"name":"Grieg - In the Hall of the Mountain King - melody","key":"B minor","tempoBPM":138,"beatsPerBar":4,
 "notes":[
  {"beat":0.0,"midi":54,"len":4.0},
  {"beat":4.0,"midi":47,"len":0.5},{"beat":4.5,"midi":49,"len":0.5},{"beat":5.0,"midi":50,"len":0.5},{"beat":5.5,"midi":52,"len":0.5},
  {"beat":6.0,"midi":54,"len":0.5},{"beat":6.5,"midi":50,"len":0.5},{"beat":7.0,"midi":54,"len":1.0},
  {"beat":8.0,"midi":53,"len":0.5},{"beat":8.5,"midi":49,"len":0.5},{"beat":9.0,"midi":53,"len":1.0},
  {"beat":10.0,"midi":52,"len":0.5},{"beat":10.5,"midi":48,"len":0.5},{"beat":11.0,"midi":52,"len":1.0},
  {"beat":12.0,"midi":47,"len":0.5},{"beat":12.5,"midi":49,"len":0.5},{"beat":13.0,"midi":50,"len":0.5},{"beat":13.5,"midi":52,"len":0.5},
  {"beat":14.0,"midi":54,"len":0.5},{"beat":14.5,"midi":50,"len":0.5},{"beat":15.0,"midi":54,"len":0.5},{"beat":15.5,"midi":59,"len":0.5},
  {"beat":16.0,"midi":57,"len":0.5},{"beat":16.5,"midi":54,"len":0.5},{"beat":17.0,"midi":50,"len":0.5},{"beat":17.5,"midi":54,"len":0.5},
  {"beat":18.0,"midi":57,"len":2.0},
  {"beat":20.0,"midi":59,"len":0.5},{"beat":20.5,"midi":61,"len":0.5},{"beat":21.0,"midi":62,"len":0.5},{"beat":21.5,"midi":64,"len":0.5},
  {"beat":22.0,"midi":66,"len":0.5},{"beat":22.5,"midi":62,"len":0.5},{"beat":23.0,"midi":66,"len":1.0},
  {"beat":24.0,"midi":65,"len":0.5},{"beat":24.5,"midi":61,"len":0.5},{"beat":25.0,"midi":65,"len":1.0},
  {"beat":26.0,"midi":64,"len":0.5},{"beat":26.5,"midi":60,"len":0.5},{"beat":27.0,"midi":64,"len":1.0},
  {"beat":28.0,"midi":59,"len":0.5},{"beat":28.5,"midi":61,"len":0.5},{"beat":29.0,"midi":62,"len":0.5},{"beat":29.5,"midi":64,"len":0.5},
  {"beat":30.0,"midi":66,"len":0.5},{"beat":30.5,"midi":62,"len":0.5},{"beat":31.0,"midi":66,"len":0.5},{"beat":31.5,"midi":71,"len":0.5},
  {"beat":32.0,"midi":69,"len":0.5},{"beat":32.5,"midi":66,"len":0.5},{"beat":33.0,"midi":62,"len":0.5},{"beat":33.5,"midi":66,"len":0.5},
  {"beat":34.0,"midi":69,"len":2.0}
 ]}
```
(Bar 0 pickup: source is a `<fis,, fis'>` octave chord [F#3+F#4]; I used the lower note,
54=F#3, same "use the lower of the pair" choice I made for the closing chord in bar 8 below.
Bars 1&5: 47=B2/59=B3, 49=C#3/61=C#4, 50=D3/62=D4, 52=E3/64=E4, 54=F#3/66=F#4. Bars 2&6:
53=E#3/65=E#4, 49/61=C#, 52/64=E♮, 48/60=C♮. Bars 3&7 repeat bar 1/5's pitch set, ending on
59=B3/71=B4. Bars 4&8: 57=A3/69=A4, 54/66=F#, 50/62=D, closing note 57/69=A again — bar 8's
source chord is `<a, a'>` [A3+A4 octave]; I again used the lower note, 69=A4 in that octave.)

**Sanity check performed:** every bar's beat lengths sum to exactly 4.0 (verified by hand
for all 9 bars); every pitch class present (B, C#, D, E, F#, E#, C, A) is accounted for by a
literal token in the source above — none were invented.

### 4. Bass line
The real left-hand part ("bassoons in octaves playing a staccato ostinato of alternate
notes," per Wikipedia) is literally in the source too: alternating B/F# under the first two
phrase-bars, alternating D/A under the third. It sits an octave lower than your requested
28–48 range (real notes: B0=23, F#1=30, D1=26, A1=33), so I've shifted it up one octave —
disclosed, not hidden — to land in range.

```json
{"name":"Grieg - In the Hall of the Mountain King - bass","key":"B minor","tempoBPM":138,"beatsPerBar":4,
 "notes":[
  {"beat":4.0,"midi":35,"len":1.0},{"beat":5.0,"midi":42,"len":1.0},{"beat":6.0,"midi":35,"len":1.0},{"beat":7.0,"midi":42,"len":1.0},
  {"beat":8.0,"midi":35,"len":1.0},{"beat":9.0,"midi":42,"len":1.0},{"beat":10.0,"midi":35,"len":1.0},{"beat":11.0,"midi":42,"len":1.0},
  {"beat":12.0,"midi":35,"len":1.0},{"beat":13.0,"midi":42,"len":1.0},{"beat":14.0,"midi":35,"len":1.0},{"beat":15.0,"midi":42,"len":1.0},
  {"beat":16.0,"midi":38,"len":1.0},{"beat":17.0,"midi":45,"len":1.0},{"beat":18.0,"midi":38,"len":1.0},{"beat":19.0,"midi":45,"len":1.0},
  {"beat":20.0,"midi":35,"len":1.0},{"beat":21.0,"midi":42,"len":1.0},{"beat":22.0,"midi":35,"len":1.0},{"beat":23.0,"midi":42,"len":1.0},
  {"beat":24.0,"midi":35,"len":1.0},{"beat":25.0,"midi":42,"len":1.0},{"beat":26.0,"midi":35,"len":1.0},{"beat":27.0,"midi":42,"len":1.0},
  {"beat":28.0,"midi":35,"len":1.0},{"beat":29.0,"midi":42,"len":1.0},{"beat":30.0,"midi":35,"len":1.0},{"beat":31.0,"midi":42,"len":1.0},
  {"beat":32.0,"midi":38,"len":1.0},{"beat":33.0,"midi":45,"len":1.0},{"beat":34.0,"midi":38,"len":1.0},{"beat":35.0,"midi":45,"len":1.0}
 ]}
```
(35=B1, 42=F#2, 38=D2, 45=A2 — within 28–48. Silent during the bar-0 pickup, matching the
source's `r1\fermata` rest in the left hand there.)

### 5. Sources
- [Wikipedia — "In the Hall of the Mountain King"](https://en.wikipedia.org/wiki/In_the_Hall_of_the_Mountain_King) — key, tempo, register, "two groups of instruments move in and out of different octaves," transposition-up-a-fifth-with-flattened-sixth for the *later* variation (confirms the G# I originally misplaced in draft 1 belongs to that later section, not the opening statement).
- **Primary, literal source:** [Mutopia Project `.ly` (LilyPond source text)](https://www.mutopiaproject.org/ftp/GriegE/O46/Dans_l_antre_du_roi_de_la_montagne/Dans_l_antre_du_roi_de_la_montagne.ly) — the actual note tokens quoted and traced above. Rendered PDF for cross-reference: [same directory, `-let.pdf`](https://www.mutopiaproject.org/ftp/GriegE/O46/Dans_l_antre_du_roi_de_la_montagne/Dans_l_antre_du_roi_de_la_montagne-let.pdf).

### 6. Plain-English description
The music that starts as a quiet, sneaky little rising phrase — like something creeping
closer in the dark — and then repeats itself an octave higher, faster, and louder until
it's a full-blown chase. Constant shorthand in movies/TV/games for "the danger is getting
closer." Most people know it even without knowing its name.

---

## B. Beethoven — Symphony No. 5, 1st movement, opening

### 1. Public-domain confirmation
- **Composer:** Ludwig van Beethoven (1770–1827). Died 1827 → PD by a huge margin.
- **Why PD:** Composed 1804–1808, published 1809. Nothing unusual.

### 2. Your stated belief — CONFIRMED on pitches, CORRECTED on one duration
You said: *"the motif is G G G E-flat / F F F D in C minor."* **Pitches and key: correct.**
Meter: **2/4**, confirmed. Rhythm of the two 3-note pickups (eighth rest + three eighth
notes) is also correct and is the detail that makes the motif "lean in" rather than land on
the downbeat.

**What needs correcting, because I initially got it wrong too:** the two fermata-held notes
are **not** symmetric. Reading the primary score directly (below) shows the E♭ held for one
full bar, but the **D is tied across two bars** — the second "pause" is measurably longer
than the first. This matches the source I cited for the rhythm, which independently
describes the ending as "followed by a **longer** pause." My first draft gave both notes
the same length; that was wrong, and it's exactly the kind of detail a listener who knows
the piece would notice. The corrected motif is **5 bars**, not 4.

### 3. Melody — motif and its asymmetric ending verified; continuation not fabricated
Beethoven's own `.ly` source on Mutopia is only distributed zipped, and I could not extract
literal text from a zip through the tools available to me — so unlike Grieg and Bach, this
one is **not** traced from raw source text. It rests on: (a) a public-domain piano-solo
reduction I read directly as an engraved image (Mutopia ref. Mutopia-2015/01/17-497), which
visually confirmed the rest+3-eighths+fermata shape and the tie on the D, and (b) the cited
secondary source's "longer pause" description agreeing with that image. Two independent
things agreeing is real evidence, but it's a lower tier than literal source text, so I'm
not overstating it as fully source-verified the way Grieg and Bach's core melodies are.

For "the first few bars that follow": mm. 6+ in the real orchestral score is imitative
counterpoint across multiple string parts, not one melodic line, and I found no source
giving me verified exact pitches for it — I chose not to guess. The excerpt below is the
**verified 5-bar unit, repeated once**, clearly an arrangement choice, not a transcription
of Beethoven's actual continuation.

Octave: **G4** anchor (a normal, hummable octave; the real orchestral unison spans several
octaves at once, so no single octave is uniquely correct).

10 bars total (2 × the verified 5-bar unit), 2/4, C minor, Allegro con brio ♩=108 (per
Eastman's program-note page reproducing Beethoven's own marking — flagged, since Beethoven's
own metronome markings are a long-debated subject and many performances run faster).

```json
{"name":"Beethoven - Symphony No.5 - opening motif","key":"C minor","tempoBPM":108,"beatsPerBar":2,
 "notes":[
  {"beat":0.5,"midi":67,"len":0.5},{"beat":1.0,"midi":67,"len":0.5},{"beat":1.5,"midi":67,"len":0.5},
  {"beat":2.0,"midi":63,"len":2.0},
  {"beat":4.5,"midi":65,"len":0.5},{"beat":5.0,"midi":65,"len":0.5},{"beat":5.5,"midi":65,"len":0.5},
  {"beat":6.0,"midi":62,"len":4.0},
  {"beat":10.5,"midi":67,"len":0.5},{"beat":11.0,"midi":67,"len":0.5},{"beat":11.5,"midi":67,"len":0.5},
  {"beat":12.0,"midi":63,"len":2.0},
  {"beat":14.5,"midi":65,"len":0.5},{"beat":15.0,"midi":65,"len":0.5},{"beat":15.5,"midi":65,"len":0.5},
  {"beat":16.0,"midi":62,"len":4.0}
 ]}
```
(67=G4, 63=E♭4, 65=F4, 62=D4. The E♭ fills one 2-beat bar; the D is `len:4.0` — two bars —
which is the correction above. Each unit is 10 beats = 5 bars; two units = 20 beats = 10 bars.)

**Sanity check performed:** each 2-beat bar sums to exactly 2.0 except the final D, which
deliberately spans two bars (4.0) — that asymmetry is now intentional and cited, not an
arithmetic error; pitches match your stated belief and both sources exactly; `beatsPerBar`
is 2 (the piece's actual meter), not the JSON template's example value of 4.

### 4. Bass line
The real opening is unison across the whole orchestra — no separate bass note under it — so
this, like Bach's below, is a DJ-arrangement addition, not a transcription. Tonic pedal,
held under each 5-bar unit:

```json
{"name":"Beethoven - Symphony No.5 - bass","key":"C minor","tempoBPM":108,"beatsPerBar":2,
 "notes":[
  {"beat":0.0,"midi":36,"len":10.0},
  {"beat":10.0,"midi":36,"len":10.0}
 ]}
```
(36=C2, within 28–48.)

### 5. Sources
- ["Sublime Nothingness: On 'The First Four Notes'," Los Angeles Review of Books](https://lareviewofbooks.org/article/sublime-nothingness-on-the-first-four-notes/) — eighth-rest + three-eighth-notes-G + fermata-E♭ notation, 2/4 meter, and the "followed by a longer pause" phrasing that corroborates the tied D.
- [Eastman School of Music, "Beethoven Symphony Basics," Symphony No. 5](https://www.esm.rochester.edu/beethoven/symphony-no-5/) — key, tempo marking Allegro con brio MM=108.
- Read directly as an image (not literal text — the `.ly` is zip-only): [Mutopia Project PD piano-solo reduction](https://www.mutopiaproject.org/ftp/BeethovenLv/O67/beethoven_fifth_op67/beethoven_fifth_op67-let.pdf) (ref. Mutopia-2015/01/17-497) — visual confirmation of the motif notation and the tie on the D.

### 6. Plain-English description
The four notes everyone can hum even without knowing whose piece it's from: "da-da-da-DUM."
The most famous opening in classical music — shorthand for "something ominous and
unstoppable is arriving."

---

## C. Bach — Toccata and Fugue in D minor, BWV 565, opening flourish

### 1. Public-domain confirmation
- **Composer (attributed):** Johann Sebastian Bach (1685–1750). Died 1750 → PD by a huge
  margin regardless of the point below.
- **Why PD:** Written between 1704 and the 1750s. Nothing about timing is close.
- **Unusual, as you asked me to flag:** authorship isn't 100% settled scholarship. Since
  1981 a minority of musicologists (Peter Williams) have questioned whether Bach wrote it —
  possibly a transcription of a lost violin piece, or written after Bach's death. Christoph
  Wolff (widely regarded as the leading living Bach scholar) maintains it's genuinely
  Bach's. **Doesn't affect PD status either way** — whoever wrote it has been dead for
  centuries — but "by J.S. Bach" is the conventional, not 100%-certain, attribution.

### 2. Your stated belief — CONFIRMED, including the mordent direction (corrected back after I second-guessed it)
You said: *"it opens A–G–A then a descending run."* This is correct, and I want to be
explicit that I briefly talked myself out of it and back into it, because the reasoning
matters for how much to trust the rest of this file.

The literal `.ly` source (quoted in full below) marks the opening note's ornament `\prall`,
which in strict ornament terminology names a *pralltriller*/upper mordent (A–B–A), not a
lower mordent (A–G–A). My first pass took that literal symbol at face value and corrected
you to A–B–A. On review, that was the wrong call: there's no surviving Bach autograph for
this piece (see below) — `\prall` here is a **20th/21st-century typesetter's interpretive
choice**, not Bach's own notation, so it isn't the trump card I treated it as. Weighed
against that: (a) a specialist organ-journal source I found independently states this
passage opens with "the mordent A–G–A"; (b) A–G–A is the standard performance-practice
realization cited across organ pedagogy for this specific passage; (c) internal evidence —
the descending run that immediately follows *starts on G5*, so A–G–A leads directly into it,
while A–B–A would introduce a B5 that appears nowhere else in the phrase. All three point
the same way. **Your belief was right; I'm going with A–G–A.**

- The descending run: real, confirmed, but **much shorter than a full two-octave scale** —
  literally 7 notes (G5-F5-E5-D5-C#5-D5-B4), not a smooth long descent. My first draft
  fabricated a 15-note two-octave descent that isn't on the page; replaced with the literal
  notes below.
- The gesture immediately **repeats one octave lower** (starting on A4, not A5 — I mislabeled
  this "a fourth lower" earlier in review; it's an octave, matching A5→A4 exactly), with a
  shorter 4-note run (E4-F4-C#4-D4), before landing on an **arpeggiated diminished chord**
  (B♭3-C#4-E4) — this second, varied statement is real and verified, not something I added.

**Ornament timing, disclosed:** I realized the A–G–A mordent by borrowing time from the main
note's own notated eighth-note (0.125+0.125+0.25 beats = 0.5 beat total). That's one standard
convention; the other common one plays the ornament *before* the beat as a grace figure. Pick
whichever reads better against your drum-machine grid — the pitches are the fixed part, the
exact placement is a performance-style choice either way.

### 3. Melody — traced from the literal LilyPond source
```
\relative c''' {
a8 \fermata \prall b,32 \rest g'64 f e d cis32 d16 b \rest b8 \rest \fermata
a \fermata \prall b32 \rest e, f cis d16 b' \rest b8 \rest \fermata
s2. <bes, cis e>4 ~ \arpeggio
```
`\rest` here is LilyPond's pitch-plus-rest shorthand (keeps the octave-tracking chain intact
through a silence) — those tokens are silent, not sounding notes; I traced the octave chain
through them anyway since later real notes are relative to them.

Key: D minor (1-flat signature, confirmed both from the engraving and the `.ly`). Tempo
marking is **Adagio with no fixed BPM** — the passage is deliberately free/rubato, its
rhythm suspended by fermatas and grand-pause rests, so unlike the other two pieces **beat
positions here don't need to sum to tidy bar totals**, and forcing them to would misrepresent
what a fermata does. I'm supplying **66 BPM** as a practical grid for your build script,
explicitly not claimed as Bach's own tempo — for a film build the more idiomatic treatment
is to let this sit free before the beat drops.

```json
{"name":"Bach - Toccata BWV565 - opening flourish","key":"D minor","tempoBPM":66,"beatsPerBar":4,
 "notes":[
  {"beat":0.0,"midi":81,"len":0.125},{"beat":0.125,"midi":79,"len":0.125},{"beat":0.25,"midi":81,"len":0.25},
  {"beat":0.625,"midi":79,"len":0.0625},{"beat":0.6875,"midi":77,"len":0.0625},{"beat":0.75,"midi":76,"len":0.0625},{"beat":0.8125,"midi":74,"len":0.0625},
  {"beat":0.875,"midi":73,"len":0.125},{"beat":1.0,"midi":74,"len":0.25},{"beat":1.25,"midi":71,"len":0.25},
  {"beat":2.25,"midi":69,"len":0.125},{"beat":2.375,"midi":67,"len":0.125},{"beat":2.5,"midi":69,"len":0.25},
  {"beat":2.875,"midi":64,"len":0.125},{"beat":3.0,"midi":65,"len":0.125},{"beat":3.125,"midi":61,"len":0.125},{"beat":3.25,"midi":62,"len":0.25},
  {"beat":4.25,"midi":58,"len":0.25},{"beat":4.5,"midi":61,"len":0.25},{"beat":4.75,"midi":64,"len":0.5}
 ]}
```
(81=A5, 79=G5 [mordent lower aux, and also the first note of the descending run right after],
77=F5, 76=E5, 74=D5, 73=C#5, 71=B4, 69=A4, 67=G4 [mordent lower aux for the second, octave-down
statement], 64=E4, 65=F4, 61=C#4, 62=D4, 58=B♭3 [root of the closing arpeggio], then 61=C#4,
64=E4 completing the rolled diminished chord.)

**Sanity check performed:** rather than "sums to whole bars" (not meaningful here — see the
tempo note above), I checked that every note token traces back to the literal source quoted
above with no invented pitches, that the two statements are appropriately different lengths
(7 sounding notes then 4, matching the source, not forced into false symmetry), and that the
closing chord (B♭-C#-E) is a diminished triad, consistent with the "diminished seventh
chord" that secondary sources describe appearing in this piece. Total span ≈ 5.25 beats
(≈1.3 bars at 4 beats/bar) for the fully-verified core gesture — short of "8 bars" in raw
beat count, which is honest given how little of this piece is actually metered; loop it for
a longer build, same as you'd do with Grieg's or Beethoven's repeating units above.

### 4. Bass line
**Important disclosure:** the authentic score has no pedal (bass) here at all — Wikipedia
notes the line is "doubled at the octave" between the two manual hands, and the pedal part
is rests for roughly the first 16 bars. Any bass below is a pure arrangement addition, not
a simplification of something Bach wrote.

```json
{"name":"Bach - Toccata BWV565 - bass","key":"D minor","tempoBPM":66,"beatsPerBar":4,
 "notes":[
  {"beat":0.0,"midi":33,"len":2.25},
  {"beat":2.25,"midi":38,"len":2.0}
 ]}
```
(33=A1 under the first statement, 38=D2 resolving under the second/landing — both in 28–48.)

### 5. Sources
- **Primary, literal source:** [Mutopia Project `.ly` (LilyPond source text)](https://www.mutopiaproject.org/ftp/BachJS/BWV565/ToccataFugue/ToccataFugue.ly) — the note tokens quoted and traced above, including the `\prall` marking (and why I didn't defer to it for ornament direction — see §C.2).
- [thediapason.com, "Exploring the unknown of BWV 565, Part 3"](https://www.thediapason.com/content/exploring-unknown-bwv-565-part-3) — specialist source stating the opening mordent is realized A–G–A; this is what tipped me back to your original belief.
- [Wikipedia — "Toccata and Fugue in D minor, BWV 565"](https://en.wikipedia.org/wiki/Toccata_and_Fugue_in_D_minor,_BWV_565) — composition date range, authorship-doubt discussion (Williams vs. Wolff), "doubled at the octave," diminished-seventh-chord description.
- Rendered PDF for cross-reference: [same Mutopia directory, `-let.pdf`](https://www.mutopiaproject.org/ftp/BachJS/BWV565/ToccataFugue/ToccataFugue-let.pdf).

### 6. Plain-English description
The classic "mad scientist's organ" sound — a quick decorative flick on one high note, a
beat of tense silence, then a short dramatic tumble of notes downward, echoed lower and
shorter, landing on an unsettled chord. The single most recognizable "haunted house /
vampire movie" musical cliché there is.

---

## Confidence summary

| Theme | Traced from literal source text | Image-verified only (no `.ly` access) | Disclosed arrangement additions |
|---|---|---|---|
| A. Grieg | Full 9-bar melody + bass, all pitches and durations | — | Bass shifted up one octave to fit 28–48 |
| B. Beethoven | — | Full 5-bar motif incl. the corrected tied-D duration (piano-reduction image + a citation that independently agrees) | Bars 6–10 are a disclosed repeat, not Beethoven's actual continuation (unverified, not fabricated); bass line entirely added |
| C. Bach | Full opening gesture incl. the corrected A–G–A mordent direction and the short (not 15-note) descending runs | — | Tempo (66 BPM) and bass line entirely added; real piece has neither a fixed tempo nor a bass here |

Net effect of the review passes: Grieg's melody went from a wrong repeated-note guess to a
verified ascending scale; Bach's descending run went from a fabricated 15-note scale to the
literal 7-then-4-note runs, and its mordent direction was corrected, un-corrected, and
correctly re-confirmed as A–G–A (your original belief); Beethoven's D-fermata duration went
from 1 bar to the correct 2. Every correction came from either primary source text or
weighing citations properly instead of trusting a first-pass read.
