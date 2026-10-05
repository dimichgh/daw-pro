# Spike: one-finger chord buttons for Musical Typing

**Status: RESEARCH ONLY.** No code, tests, or wire/MCP surface is changed by this document. Every
claim below is either a citation with a URL, an in-repo fact cited by file and line, or explicitly
marked as an estimate / not verified. Author: `research-analyst`. Date: 2026-08-30.

**The ask, in the product owner's own words:** chords like "C# major or whatever" get used
"according to the melody style," should be playable "as a single button," and pressing one should
maybe "change the arrangement to be played with single finger," with "presets of the chords and
settings based on instrument being played." **The framing that must drive every recommendation
below: this user has no physical MIDI keyboard and is not a trained musician.** This is not a
power-user shortcut bolted onto a controller — it is the difference between this user being able to
play a bridge or a I–V–vi–IV loop at all, versus never touching real harmony.

---

## 0. Summary and recommendation

Build **scale/chord mode** first — every key on the *already-shipped* musical-typing keyboard
becomes a full, correctly-voiced diatonic chord in a key the user picks, instead of a single note
(§4). Ship it in the same phase as a small set of **named progression presets** (§2.2) that do
nothing but *highlight and relabel* four or five of those same keys — not a competing feature, a
data overlay on the first one (§7.4). Do **not** build a fixed single chord that only transposes,
the way Arturia's KeyStep or Logic's Chord Trigger "Single" mode do (§3, §4) — it is a sound-design
toy for a shape you already like, not a way to play a song you don't know how to voice.

This is cheap because **m23-ct (shipped 2026-08-29) already built the entire delivery pipe it
needs.** `MusicalTypingController` holds a set-shaped ledger of sounding pitches; its sink pushes
that set straight to `ProjectStore.playLiveNotes`, captured into a take exactly like single notes
are today (`Sources/DAWAppKit/MusicalTypingController.swift:308-338,396-416`;
`Sources/DAWAppKit/LiveNoteSink.swift`). The wire verb this rides, `note.play`, is *already
polyphonic* — it takes an array of up to 8 MIDI pitches per call and is already the capturable,
holdable sibling of `note.audition` (`Sources/DAWControl/Commands.swift:459,5366-5399`). **A chord
is already synth-playable through the existing wire surface today** — a call to `note.play` with
`pitches:[60,64,67]` sounds and records a C-major triad right now. That is a fact about plumbing,
not about the feature, and it must not be read as one: this project's owner was shown the "an agent
can already do this over the wire" argument for the adjacent composition-tools cluster (arpeggiator
/ step sequencer / chord track) and **explicitly ruled against it as a substitute for a manual
surface** — "add it anyway" (`docs/ROADMAP.md:1049`, §1.2 below). **The deliverable here is the
human-operable, visibly-indicated, one-key affordance.** The wire fact matters only for costing
§7's build, never as a reason to skip the button.

What is genuinely new, and where the real work is: (1) a small, pure `DAWCore` **chord-voicing
module** — chord symbol + prior voicing + instrument preset → a well-spaced pitch array (§5, §7.1);
(2) an **additive mode** on `MusicalTypingController` that changes what one key press produces
(§7.2); (3) the **on-screen affordance** — a mode toggle, a key/scale picker, a progression-preset
row, and a Roman-numeral legend on the keys, built on the exact Canvas legend path
`MusicalKeyboardStrip` already uses for note letters (§7.4). None of it touches `DAWEngine`, the
render thread, or adds new real-time state.

---

## 1. What already ships, and what this must not duplicate

### 1.1 Musical Typing (m23-ct) — the surface this feature extends

Verified directly in the tree at branch `m23-wip-2026-08-10`:

- **`Sources/DAWAppKit/MusicalTypingRouting.swift`** — a pure predicate plus the ONE layout table.
  **17 keys** (A/W/S/E/D…), semitones 0…16 (`semitoneSpan`, :237), keyed off virtual key code, never
  characters. `defaultBaseOctave = 4` (:324); `baseNote(forOctave:) = (octave+1)*12` (:335-337), so
  the default reachable span is MIDI 60…76. Confirmed against this codebase's own naming —
  `Fundamental.noteName(midiNote: 60)` resolves to `"C4"`
  (`Sources/DAWCore/InstrumentFrequencyReference.swift:167-175`, traced by hand: pitch class 0 →
  `"C"`, octave `⌊60/12⌋−1 = 4`) — so the shipped default window is **C4…E5**, and the full
  reachable range is C‑1…C8 with every octave's 17 keys landing inside MIDI 0…127 by construction.
  **One inconsistency worth flagging rather than silently picking a side of:** the file's own bounds
  comment at :328-329 says *"the highest whose top key still lands inside MIDI 0…127 (`C8` = 108, and
  108 + 17 = 125). So every reachable octave sounds every one of its **18** keys"* — but `noteCaps`
  is a 17-entry table and m23-ct's own close record is explicit: "17 keys, semitones 0…16," and a
  would-be 18th key (Logic also binds `'`→+17/F) was *deliberately not added*
  (`docs/ROADMAP.md:1055`). This document uses **17** throughout, matching the actual table and the
  close record; the "18" in the source comment's prose looks like a stale off-by-one in the comment
  itself, not a real discrepancy this design needs to resolve — but it is exactly the "two records
  disagree and nothing compares them" shape this project's own history warns about, so it is named
  here rather than reproduced silently.
- **`Sources/DAWAppKit/MusicalTypingController.swift`** — the session-state half: mode, octave,
  velocity, and the held-pitch ledger (`soundingPitches`, set-shaped, oldest-note-steals-a-voice at
  `maxVoices`). `maxVoices = AuditionController.maxVoices = 8`
  (`Sources/DAWCore/Audition.swift:40`) — **the hard polyphony ceiling any chord voicing must
  respect.**
- **`Sources/DAWAppKit/LiveNoteSink.swift`** — the seam protocol, `setHeldPitches(_:velocity:)`.
  Set-shaped by design specifically so a re-assertion of an unchanged set is a no-op — this is the
  property that later made a 500 ms liveness heartbeat safe (`docs/ROADMAP.md:1058`). Any chord-mode
  extension that reuses this seam inherits that safety for free.
- **`Sources/DAWApp/Components/MusicalKeyboardStrip.swift`** — the on-screen keyboard: a `Canvas`
  piano strip, ivory/ebony keys (`DAWTheme.keyWhite`/`keyBlack`), a per-key letter legend built from
  `MusicalTypingRouting.noteCaps` "so the two surfaces teach each other" (file comment, :211-217),
  and a header with mode/octave/velocity/recording-honesty readouts.
- **Wire**: `note.play` (`Sources/DAWControl/Commands.swift:459,5366-5399`) — `{trackId, pitches:
  [Int] (0…8 of them, each 0…127), velocity}`, set-shaped, an empty array releases everything held;
  captured into a take when the target track is armed. `note.audition`
  (`:426,5302-5314`) is the one-shot, non-capturable sibling, refused while recording. MCP:
  `note_play` (`mcp-server/src/server.ts:2208`), `note_audition` (`:2123`).
- **Restraint precedent, and it is load-bearing for §7.3**: m23-ct's own close record predicted four
  new wire verbs and shipped **one**. `typing.setEnabled` / `typing.configure` / `typing.state` were
  *deliberately not built* — the seam they'd expose is already reachable through the app-tier-only
  `debug.musicalTyping`, and three permanent public verbs "to drive an on-screen keyboard is a wire
  surface we would owe forever for a need no gate or agent has" (`docs/ROADMAP.md:1062`). The
  session-only mode toggle itself is explicit, never ambient, and never persisted — "a fresh launch
  always starts with Musical Typing OFF" (`MusicalTypingController.swift:25-30`).
- Roadmap status: **`m23-ct` box is deliberately left unticked** pending a human hands-on pass — no
  gate in this tree can press a key or look at a pixel (`docs/ROADMAP.md:1072`). This chord-mode
  proposal inherits that same caveat: nothing here can be gate-verified as "feels good," only as
  "computes the documented pitches."

### 1.2 Two open roadmap items this must not re-derive or collide with

- **`m23-cq-3`, "Chord track (+ scale lock)"** (`docs/ROADMAP.md:1052`, open, unstarted). This is a
  **global timeline lane other tracks follow** — changing a chord retunes every following clip. It
  needs new harmonic-vocabulary types in `DAWCore` (`struct Chord`/`enum Chord`/`chordSymbol`/
  `scaleLock` all return **zero** hits across `Sources/` as of 2026-08-04) and interacts with
  `TempoMap`/`MeterMap`'s beat-domain machinery. Weight **L** for the chord-track half, **S** for
  scale-lock alone. Route: `daw-architect` then `swift-app-engineer`. **This document is not that
  item.** A per-key performance chord and a project-wide harmonic timeline are different products
  with different failure modes (one is "what does pressing G sound like right now," the other is
  "what does every track sound like from bar 9 on"). The two *should* eventually share one
  vocabulary — see §7.1's recommendation to make the voicing module that home — but building the
  track is out of scope here.
- **`m23-cq-2`, "Arpeggiator"** (`docs/ROADMAP.md:1051`). Real-time-only per the owner's own ruling
  (the offline "arpeggiate a clip" shape was explicitly declined as redundant with what Copilot can
  already do via `clip.setNotes`). It was **blocked on m23-ct**, which has now shipped, so it is
  unblocked. A chord-mode key makes this feature strictly more valuable on delivery day: a single
  held key becomes a *held chord*, which is what an arpeggiator actually wants to chew on — a held
  single note is much thinner input, and §3's Ableton/Logic Arpeggiator rows make the same point from
  the competitive side: both are devices that take a held chord as their entire input and do nothing
  chord-selecting themselves. Worth flagging to whoever schedules m23-cq-2 next.
- **The provenance ruling that decides how this whole feature must be scoped**
  (`docs/ROADMAP.md:1049`): the `research-analyst` parity audit argued that DAW Pro's AI-native
  answer to "arpeggiate this" is asking Copilot to call a wire command, which is arguably more
  aligned with the product's own AI-native thesis than parallel manual UI. **The user was shown that
  argument and rejected it** — "add it anyway" — which the roadmap records as "a RULING AGAINST THE
  RATIONALE, NOT MERELY A REQUEST FOR THE FEATURE." Any chord-buttons proposal that leans on "well,
  an agent can already assemble a pitch array and call `note.play`" is re-shipping exactly the thing
  that was declined. §7 treats the wire/MCP surface as a *secondary* deliverable that makes agents
  better at authoring chords into clips, never as a substitute for the on-screen button.

---

## 2. Which chords actually get used

Not music theory in the abstract — what corpus studies of real recorded/published songs actually
find, with genre attributions kept separate from what is merely commonly asserted.

### 2.1 The diatonic seven — the vocabulary everything below is drawn from

For any major key: **I ii iii IV V vi vii°**. For natural minor: **i ii° III iv v VI VII**. Every
progression named below is a subset or rotation of these seven triads in some key — there is no
separate "genre vocabulary" underneath; genre lives in which subset is favored, in what order, and
—far more than either of those — in *how the chords are voiced and played* (§2.3, §5). This is the
single fact that should drive the architecture: a mapping that covers "every key is one of these
seven chords" covers essentially everything below as a side effect, plus whatever the user
personally wants that no preset anticipated.

### 2.2 The progressions that dominate, genre by genre

| Progression | Common name(s) | Genre association | Evidence |
|---|---|---|---|
| **I–V–vi–IV** and rotations (V–vi–IV–I, vi–IV–I–V, IV–I–V–vi) | "the four chords of pop," "axis progression" | Pop, pop-rock, much of EDM/house (same chords, different genre) | Hooktheory's public analysis of ~1,300 (later tens of thousands) Billboard-derived songs identifies this family as dominant; their Markov analysis finds V (G) follows I (C) 31% of the time, and that C's own relative minor (Am) plus F and G are the most common surrounding chords — [Hooktheory: "I analyzed the chords of 1300 popular songs for patterns"](https://www.hooktheory.com/blog/i-analyzed-the-chords-of-1300-popular-songs-for-patterns-this-is-what-i-found/), [Hooktheory Trends tool](https://www.hooktheory.com/trends) (dated: blog series ~2012, Trends tool and its 40k+/75k+-song database description current as of this search, 2026-08-30) |
| **vi–IV–I–V** specifically | "pop-punk progression," "sensitive female chord progression" | Pop-punk (blink-182/Green Day-era), late-90s singer-songwriter pop | Term coined by Boston Globe critic Marc Hirsh describing its late-1990s ubiquity (e.g. Lilith Fair-era singer-songwriters); same four chords as the row above, different starting rotation, which is why it reads as more "unresolved/melancholic" (opens on the minor vi) — [fachords: "The vi-IV-I-V Sensitive Female Chord Progression"](https://www.fachords.com/sensitive-chord-progression/) |
| **I–vi–IV–V** | "'50s progression," "doo-wop changes," "Heart and Soul chords," "Stand by Me changes," "ice-cream changes" | 1950s–60s doo-wop, and its many later pop revivals | [Wikipedia: '50s progression](https://en.wikipedia.org/wiki/%2750s_progression); dedicated chapter in the open-access theory textbook — [Open Music Theory: "The '50s doo-wop progression"](https://openmusictheory.github.io/popRockHarmony-dooWop.html). **Corpus-confirmed, not just named**: a K-means cluster analysis of chord-to-chord transitions across the 730-song McGill Billboard corpus (1958–1991 Hot 100 singles) independently surfaces a cluster the authors label "the authentic/doo-wop (VI–IV–V–I) cluster" — [Shaffer, "A cluster analysis of harmony in the McGill Billboard dataset," Empirical Musicology Review](https://ojs.library.osu.edu/index.php/EMR/article/view/5576/5604) |
| **ii–V–I** (major) | — | Jazz standards, the central cadential/building-block motion of the style | [Open Music Theory: ii–V–I](https://viva.pressbooks.pub/openmusictheory/chapter/ii-v-i/) states it plainly as one of jazz's most important progressions, occurring both at cadences and as a recurring internal building block. **Quantified corpus evidence not found**: real corpus studies of jazz harmony exist and are active research (Salley & Shanahan's phrase-rhythm corpus of 688 standards; a separate 1,086-composition corpus studying mid-century harmonic change; a 1,382-standard corpus with full chord sequences — see [ResearchGate: Phrase Rhythm in Standard Jazz Repertoire](https://www.researchgate.net/publication/311004652_Phrase_Rhythm_in_Standard_Jazz_Repertoire_A_Taxonomy_and_Corpus_Study)), but I could not find a single peer-reviewed number for "X% of jazz-standard chord motion is a ii–V–I." Treat the claim as theory-consensus (universally taught as *the* jazz building block), not as a measured corpus percentage. |
| **i–VI–III–VII** (natural minor) | "the four chords of pop, in minor" | Minor-key pop/rock | Practitioner sources describe it as the direct relative-minor cousin of IV–V–vi–I (e.g. Am–F–C–G) — [Guitar Lobby: minor chord progressions](https://www.guitarlobby.com/minor-chord-progressions/), [Native Instruments blog: minor chord progressions](https://blog.native-instruments.com/minor-chord-progressions/). **I did not find a dedicated academic corpus study isolating this exact rotation** the way De Clercq/Temperley or the McGill Billboard cluster analysis did for the major-key four chords — treat the genre association as practitioner-consensus, not corpus-verified. |
| **12-bar blues (I–IV–V)** | — | Blues, and the harmonic skeleton under a huge share of early rock & roll | Fixed 12-bar structure: bars 1–4 = I, bars 5–8 = IV then I, bars 9–12 = V, IV, I (with a V turnaround); idiomatically every chord carries a dominant 7th (I7–IV7–V7) — well-established form, [StudyBass: The 12-Bar Blues Form](https://www.studybass.com/lessons/blues-bass/the-12-bar-blues-form/). Uncontroversial enough that I have not sourced it further. |
| **Extended/7th-and-9th reharmonizations of the above** (Cmaj7–Am7–Fmaj7–G7 instead of C–Am–F–G; min9/maj9 stacks) | — | Lo-fi hip-hop, neo-soul, R&B | Lo-fi hip-hop and neo-soul "derive a lot of their harmonic language from jazz" and the standard move is literally re-voicing the same I–vi–IV–V/ii–V–I skeletons with 7ths/9ths — [lofiweekly: 7 Guitar Chords Perfect for Lofi Hip Hop](https://lofiweekly.com/2021/11/03/7-guitar-chords-perfect-for-lofi-hip-hop-with-tabs/), [Chordoo: 10 Lo-fi Chord Progressions](https://www.chordoo.com/blog/lofi-chord-progressions-for-chill-beats), [chordsequence.com: Neo Soul Guitar Chord Progressions](https://chordsequence.com/progressions/neo-soul/) |
| **EDM / house** | — | House, deep house, EDM | The same Am–F–C–G (vi–IV–I–V) is repeatedly named as a stock house progression; deep house specifically skews minor-key with jazz-influenced major-7/minor-7 color chords rather than plain triads — [emastered: 7 Top Chord Progressions for House Music](https://emastered.com/blog/house-chord-progressions), [Attack Magazine: Deep House Chords](https://www.attackmagazine.com/technique/passing-notes/passing-notes-deep-house-chords/) |

### 2.3 The synthesis this design leans on

Across every row above, the **root vocabulary is small and shared** — the same seven diatonic
triads of one key, with I/IV/V/vi doing most of the work. What actually distinguishes a pop-punk
verse from a lo-fi loop from a deep-house pad is almost never "which Roman numerals" — it's
**voicing** (bare triads vs. 7th/9th stacks), **register and spacing** (§5), and **rhythm/attack**
(strum vs. sustained pad vs. arpeggiated). The De Clercq/Temperley rock-harmony corpus makes the
voicing point sharply from the other direction: analyzing the 100 highest-ranked songs (20 per
decade, 1950s–1990s) from Rolling Stone's "500 Greatest Songs" list, hand-coded with inter-rater
agreement over 90%, **94.1% of chords in real recorded rock are in root position**, and IV is
*more* frequent than V (unusual relative to classical-theory expectation, and evidence that "IV has
a unique and primary status" in rock specifically) — [De Clercq & Temperley, "A corpus analysis of
rock harmony," Popular Music 30(1), 2011, full PDF](https://rockcorpus.midside.com/2011_paper/declercq_temperley_2011.pdf).
That root-position figure describes a *full band arrangement* (guitar/bass split the information
across instruments) — it is not a counter-argument to voice leading a single keyboard voice that has
to carry the whole chord alone (§5 explains why those are different problems), but it is direct
evidence for §6's guitar preset: on guitar specifically, root-position strummed triads are the
*idiomatic* sound, not a beginner mistake.

**Design consequence:** a small, generic "every key is a diatonic chord in this key" mapping
generalizes almost everywhere in §2.2's table for free. What needs to vary by genre/instrument is
voicing density and playback timing (§5, §6), not the chord-choice vocabulary itself.

---

## 3. How other products already solve one-finger chords

| Product | One key/pad produces | How the chord is chosen | Per-key or transposing? | UI affordance |
|---|---|---|---|---|
| **Ableton Live — "In Key" note mode (Push 1/2/3) + Chord MIDI effect** | A single in-scale note by default; a full chord *if* the Chord device sits before the instrument | "In Key" folds the pad grid to the current scale (root row highlighted); the separate **Chord** MIDI-effect device adds up to 6 extra pitches per incoming note, each independently offset ±36 semitones, with an optional "use current scale" toggle so shifted pitches stay in-key | **Per-key** (each pad is a different scale note; the Chord device transforms whatever note arrives, so the *shape* is fixed but *which* chord depends on which pad) | Hardware scale-locked grid + a separate on-screen MIDI-effect device with knob-per-pitch-offset UI. Official manual: [Ableton Live 12 MIDI Effect Reference](https://www.ableton.com/en/manual/live-midi-effect-reference/) |
| **Ableton — Scale MIDI effect** | Re-maps any incoming note to the nearest note of a chosen scale | 13×13 note-remap matrix, root + scale-name choosers, user-definable scales | N/A (single-note remapper, not a chord generator) | Same official manual as above |
| **Ableton — Arpeggiator MIDI effect** | Turns whatever is currently held (a chord, or a single note) into a rhythmic pattern — up/down/random-style patterns, with rate, gate/transposition, and retrigger controls | It does not choose the chord at all — it plays *whatever* pitches arrive, in a pattern instead of at once | N/A (a rhythm generator downstream of a chord, not a chord-choice mechanism) | On-screen MIDI-effect device; official manual, same page as above |
| **Ableton — "Expressive Chords" (Max for Live, tied to the 12.2 / Push 3 generation)** | A full MPE-aware chord per pad — pressure can swell one voice, slide can bend the top note alone | Reportedly 52 pre-built chord sets | Per-key | **Not manual-verified — search-summary-sourced.** The "52 pre-built chord sets" and "12.2" figures came from a search-result summary, not a fetched or quoted primary source, and the linked article is a Push 3 *launch* piece that does not itself contain those specific figures — treat both numbers as unconfirmed. What is solid: this ships as a bundled Max for Live device, not a feature native to the Push hardware itself, and as of an October 2024 forum thread users were still asking for a more integrated native chord mode in Push 3 standalone. [synthanatomy: Push 3 goes standalone with MPE](https://synthanatomy.com/2023/05/ableton-push-3-the-popular-live-midi-controller-goes-standalone-with-mpe.html), [Ableton Forum thread](https://forum.ableton.com/viewtopic.php?t=251114) |
| **Logic Pro — Chord Trigger MIDI plug-in** | **Single mode**: one memorized chord, transposed by where you press. **Multi mode**: a different chord assigned to every key | You record/define the chord(s) once; notes outside the defined trigger range pass through unaffected, so a left-hand chord and a right-hand melody can coexist | **Both, as two explicit modes** — this is the clearest real-world instance of the per-key-vs-transposing distinction being a first-class UI choice rather than an implementation detail | Apple Support overview page: [Chord Trigger overview in Logic Pro](https://support.apple.com/guide/logicpro/chord-trigger-overview-lgceb57e806c/mac) (page fetch returned only navigation chrome, not full body text — description above is corroborated across multiple Apple Support mirror pages returned by search, not a single deep-fetched quote; treat the mode *names* and *behavior split* as reliable, exact wording as unverified) |
| **Logic Pro — Arpeggiator MIDI plug-in** | Same idea as Ableton's: a held chord becomes a rhythmic pattern (up/down/random/etc.), with preset patterns, switchable variations, and **inversions** (changing which chord tone starts the pattern) | Reacts to whatever is currently held — like Ableton's, it sits *downstream* of a chord rather than choosing one | N/A (rhythm generator) | "Split and remote" controls let nearly every Arpeggiator function be driven without leaving the keyboard, explicitly positioned as a live-performance tool — [Apple Support: Arpeggiator MIDI plug-in overview in Logic Pro for Mac](https://support.apple.com/guide/logicpro/arpeggiator-overview-lgce2f607310/mac) (same caveat as the Chord Trigger row: corroborated across several Apple Support mirror pages from search, not one deep-fetched quote) |
| **Native Instruments — Komplete Kontrol "Smart Play"** | Every key in scale sounds a full chord | `SHIFT+SCALE` sets root/scale bank/scale type; a separate `Harmonizer`/`Chord Set` selector (knob 5, `SHIFT+SCALE`) picks the chord-generation style, explicitly documented as: "each key you press will trigger a whole chord instead of a single note. The notes of each chord also stay within the scale selected." | **Per-key**, and it is the cleanest real "every key is a diatonic chord" implementation found in this survey | Hardware knob + on-screen display; [Native Instruments: Using Smart Play (A-Series quickstart)](https://www.native-instruments.com/pages/a-series-quickstart-using-smart-play) |
| **Novation Launchkey — three chord modes** | **Chord Map**: 8 pads, each a different pre-built chord tied to the current scale, at an adjustable "Adventure" (harmonic complexity) level. **User Chord**: you assign your own favorite chords to pads by hand. **Fixed Chord**: build one chord on the keys, then play it transposed from any key | Chord Map = curated + scale-aware; User Chord = fully manual; Fixed Chord = record-once | **Chord Map / User Chord = per-key (per-pad). Fixed Chord = transposing**, i.e. Launchkey ships *both* models plus the transposing one, as three named, switchable modes | Dedicated pad bank + on-screen encoders; [Novation: Launchkey MK4 Chord Map Guide](https://support.novationmusic.com/hc/en-gb/articles/20346898821778-Launchkey-MK4-Chord-Map-Guide), [Launchkey MK3 Scale Mode explanation](https://support.novationmusic.com/hc/en-gb/articles/360016062800-Launchkey-MK3-Scale-Mode-explanation) |
| **Novation Circuit (Tracks)** | Scale-locked step/pad grid (root note + one of 16 scales incl. major, natural minor, pentatonic, Dorian, Lydian, Mixolydian); a documented "chord mode" usable as "a chord bank to jam with" | Root + scale selection, similar in spirit to Launchkey's Scale Mode | **Not independently confirmed which of per-key/transposing** — I found this described only in secondary tutorial/blog coverage, not Novation's own manual text describing the exact interaction; **do not treat the mechanism detail as verified**, only that a scale-locked grid and a named chord mode exist. [Synthtopia: Melodies, Scales & Chords on the Novation Circuit](https://www.synthtopia.com/content/2017/06/16/melodies-scales-chords-on-the-novation-circuit/) |
| **Arturia KeyStep — Chord mode** | Whatever chord (up to 16 notes) you played to define it, replayed and **transposed** by whichever key you press next | Hold `Shift`+`Hold` to enter; play the chord once; the lowest note you entered becomes the transposition anchor — keys above it transpose up, below it transpose down | **Transposing, single fixed chord** — chord memory is not saved across power-off | [ManualsLib: Arturia KeyStep Chord Mode manual excerpt](https://www.manualslib.com/manual/1166227/Arturia-Keystep.html?page=21) |
| **Roli — "Smart Chords" / NOISE app / ROLI Studio** | For every note across every octave, a selectable chord type (5th, Triad, Sus4, 6th, 7th, 9th, 11th) sounds instead of the single note | Pick a scale, then pick a global chord-type applied uniformly | Per-key (scale-derived) | **Could not fully verify which product layer owns this feature.** Search results describe "Smart Chords" in the context of ROLI's NOISE app and ROLI Studio / Studio Player (which bundles the Equator2/Strobe2/Cypher2 engines), not Equator as a standalone synth with its own native chord mode — [ROLI Support: NOISE Commands: Arp, Chord & Scale](https://support.roli.com/en/support/solutions/articles/36000027934-noise-commands-arp-chord-scale), [ROLI Studio Player manual](https://support.roli.com/en/support/solutions/articles/36000129214-roli-studio-player). Treat "Equator has a native chord mode" as **not verified**; what is verified is that the ROLI software ecosystem (Studio/NOISE) has one. |
| **Scaler 2 (Plugin Boutique)** — the dominant third-party product in this space | Clicking a chord slot plays/previews that chord; dragging it out creates a MIDI pattern | Two paths: (a) **detect** — analyze MIDI or audio (live input, DAW playback, or a dropped audio file) to identify key/scale/chords already present; (b) **browse** — a "Diatonic" tab surfaces the chosen scale's own diatonic chords with selectable density (triad/7th/9th/11th/13th) | **Per-key/per-slot**, a curated row, not a full 88-key mapping | Chord-slot grid + a "Perform" panel offering per-chord octave/timing/style controls (200+ performance styles) and a capture-to-MIDI button. [Sound on Sound: Plugin Boutique Scaler 2](https://www.soundonsound.com/reviews/plugin-boutique-scaler-2), [rekkerd.org: Scaler 2 launch coverage](https://rekkerd.org/plugin-boutique-launches-scaler-2-with-performance-mode-chord-audio-detection-midi-capture/). Exact slot count and the precise wording of any "progression browser" UI beyond the Diatonic tab were **not confirmed against Scaler's own manual** — treat those specifics as review-sourced, not manual-verified. |

**Why both arpeggiators are in this table despite not choosing a chord themselves:** they are the
clearest evidence that "hold a chord with one gesture" is a prerequisite most competitors assume
rather than an optional nice-to-have — an arpeggiator's *entire input* is a held chord; it generates
nothing harmonic on its own. This is the same point §1.2 makes about `m23-cq-2`: DAW Pro's own
real-time arpeggiator item was blocked specifically on having no way to hold anything at all, and a
chord-mode key is what makes the held input worth arpeggiating, not just a held single note.

**The per-key-vs-transposing axis, stated plainly because the task asks for it directly:** every
product surveyed that lets a beginner "just start playing a song" — NI's Harmonizer, Ableton's
In-Key-plus-Chord-device combination, Launchkey's Chord Map, Scaler's chord row — assigns
**different chords to different keys/pads**. The **transposing single-chord** model (KeyStep, Logic
Chord Trigger "Single," Launchkey's own "Fixed Chord") is real, shipped, and explicitly offered
*alongside* the per-key model in two of the four products that have it (Logic, Launchkey) — never
instead of it. No product in this survey ships transposing-single-chord as its *only* or *primary*
chord mode.

---

## 4. The two (really three) design models, and which DAW Pro builds first

Restating the task's framing precisely, then sharpening it against what §3 actually found:

- **Scale/chord mode** — every key becomes a diatonic chord in the chosen key. (NI's Harmonizer;
  Ableton's In-Key note grid feeding a Chord device; Launchkey's Chord Map at its default complexity
  tier; Scaler's Diatonic tab.)
- **Chord pads/buttons** — a small, curated, fixed set of named buttons. (Launchkey Chord Map at
  higher "Adventure" tiers; Scaler's chord row when populated from a detected/imported progression
  rather than the raw diatonic set; the owner's own "the four chords of a progression" framing.)
- **A third model the task's two-way split doesn't name, but §3 makes impossible to ignore:** a
  **single fixed chord that transposes** (KeyStep, Logic "Single," Launchkey "Fixed Chord"). This is
  meaningfully different from "chord pads" — there is only ever *one* chord shape; pressing a
  different key doesn't change *which* chord, only *where* it sits.

**Recommendation, not hedged: build scale/chord mode first, and ship named progression presets in
the same phase as a highlight/relabel overlay on it — not as a second, separate feature. Do not
build the transposing-single-chord model at all for v1.**

**Why scale/chord mode wins the "build first" question for this specific user:**

1. **It never runs out.** A curated 4-button set requires the user to already know which four
   buttons match the song stuck in their head. That is exactly the theory-literacy barrier this
   feature exists to remove. Scale/chord mode has an answer for *any* chord in the key, including
   ones no preset anticipated — the diatonic seven cover §2's entire table (§2.3).
2. **It reuses nearly everything already shipped.** The 17-key layout, the letter-legend rendering
   path, the set-shaped held-pitch ledger, and the capture-into-take pipe are all already built for
   single notes (§1.1). Scale/chord mode changes *what a key press computes*, not how it is drawn,
   held, released, or recorded. A curated N-button preset picker is a genuinely separate UI
   component with its own state and its own affordance to design from nothing.
3. **It teaches by doing, using this app's own stated philosophy.** `MusicalKeyboardStrip`'s letter
   legend exists explicitly "so the two surfaces teach each other"
   (`MusicalKeyboardStrip.swift:211-217`). A key that always sounds "the IV chord of whatever key
   you're in," labeled `IV`, teaches the same way — press it in different keys and the *relationship*
   stays legible, which is precisely how a self-taught musician actually learns Roman numerals.
4. **Competitive precedent agrees with this ordering, not just this document's opinion.** Every
   product in §3 that leads with "start playing with zero setup" (NI, Ableton's default In-Key
   layer, Launchkey's default Chord Map tier) is scale-derived. The purely curated set (Scaler's
   detected/imported row, Launchkey's higher-complexity Adventure tiers) is consistently positioned
   as the *second*, more advanced layer once a scale is already established — the industry's own
   layering matches this recommendation's phase ordering.
5. **The curated-set model's one genuine advantage is real, and this design captures it without
   making it a separate feature.** "Press 1, 2, 3, 4 in that order" with zero decisions is
   legitimately easier for a total beginner than "figure out which 7 keys are the diatonic set."
   §7.4 delivers exactly that: picking a named progression preset highlights and relabels four or
   five of the *same* scale-mode keys. The user gets both without the product having to choose.
6. **The transposing-single-chord model is excluded on the merits, not by omission.** Its entire
   value proposition is "explore where one chord-shape-you-already-like sounds good" — a sound-design
   / improvisation tool for someone who already has an idea. It does not let a user who doesn't know
   any chords play a *recognizable song*, which is the stated need. It is cheap to add later (§7.5)
   if ever requested, but nothing in the product owner's ask calls for it.

---

## 5. Voicing matters more than note-choice

### 5.1 Why a root-position stack sounds like a beginner *on a keyboard specifically*

§2.3 already surfaced the apparent tension: De Clercq & Temperley measured **94.1% root position**
in real recorded rock. That is not a counter-argument to voice leading — it describes a *full-band*
arrangement, where the bass instrument plants the root, the guitar strums a triad, and the
information a chord voicing would otherwise carry alone is split across multiple instruments and
registers. A one-finger chord button asks a *single voice* — one instrument, one register — to carry
one chord after another, alone, for an entire song. When one voice does that with bare stacked root
position triads, the ear hears exactly what it is: block chords with no relationship to each other,
jumping around registers between changes. That is the "toy keyboard" sound, and it is a voicing
problem, not a note-choice problem.

### 5.2 Nearest-tone / nearest-inversion voice leading

The standard fix, used by every serious keyboard-voicing approach and formalized rigorously by
Dmitri Tymoczko's work on **efficient voice leading**: when moving from one chord to the next, move
each voice by the *smallest possible distance*, choosing whichever inversion/spacing of the next
chord keeps the total melodic motion across all voices minimal — [Tymoczko, "The Geometry of
Musical Chords," Science 313 (2006): 72-74, full PDF](https://dmitri.mycpanel.princeton.edu/files/publications/science.pdf);
overview at [Tymoczko's own site](https://dmitri.mycpanel.princeton.edu/voiceleading.pdf). This is a
formal, citable grounding for what keyboard players do by ear: a I chord and a IV chord in the same
key already share two common tones, so a good voicing barely moves at all between them; only the V
chord that follows needs to leap, and even then the smallest available leap is chosen. Practically,
this is a **greedy nearest-neighbor** search: enumerate reasonable octave placements/inversions of
the target chord, score each by summed absolute semitone motion from the previously-sounding
voicing, and take the minimum that also satisfies §5.3 and §5.4's constraints.

### 5.3 Low interval limits — the mud floor

The canonical arranging term for "how low can an interval sit before it reads as mud instead of
harmony" is **low interval limits**: guidelines, not hard rules, for the lowest position each
interval type (minor 2nd up through major 10th) can sit without the pitches becoming indistinct
against each other — [Robin Hoffmann: Low Interval Limits](https://www.robin-hoffmann.com/dfsb/low-interval-limits/),
[Sleepfreaks: Voicing, Arpeggios, and Low Interval Limit](https://sleepfreaks-dtm.com/en/music-theory-beginner/voicing-arpeggio/).
A commonly cited rule of thumb: for any interval other than a 5th or octave, the *top* note
shouldn't sit lower than roughly the E below middle C, with 5ths and octaves tolerating much lower
placement — [BassOx: Why Do Bass Chords Sound Muddy?](https://www.bassox.com/why-do-bass-chords-sound-muddy/).
**I could not extract the full numeric per-interval table from a primary source** — the two tables I
found (Robin Hoffmann's page, a Funnell Jazz PDF) present the limits as staff-notation images, not
as text I could quote exactly; treat the *concept* and the general rule of thumb above as verified,
and the precise per-interval octave numbers as not directly confirmed. **Grounded in this codebase's
own note-naming convention** (verified in §1.1: MIDI 60 = `"C4"`), "the E below middle C" is **E3 =
MIDI 52** here — not E2. Voicing logic should therefore treat close (non-5th, non-octave) intervals
below roughly **MIDI 52** as a real risk, expressed in MIDI numbers to avoid the octave-naming
ambiguity that trips up this exact guideline across different software (Cubase/Yamaha and
Ableton/Logic have historically disagreed about which octave number MIDI 60 gets).

### 5.4 Register separation and bass handling

Two more standard techniques, both directly actionable:

- **Separate the bass from the chord body.** Even a simple version — root doubled an octave below a
  compact chord voiced above — avoids most of the "toy" sound on its own, and it is literally how
  every transposing-chord product in §3 already models a chord: the *lowest* note you define is
  treated as the anchor/bass, distinct from the body above it (this is explicitly how Arturia
  KeyStep's Chord mode and Logic's Chord Trigger both work).
- **Drop-2 / open voicings for a fuller, "played by a person" sound.** Drop-2 takes a 4-note close
  voicing and drops the second-from-top note down an octave, spreading the chord to more than an
  octave top-to-bottom; open voicings generally have no interval smaller than a third between
  adjacent chord tones — [Learn Jazz Standards: Drop 2 Voicings](https://www.learnjazzstandards.com/blog/drop-2-voicings/),
  [Piano With Jonny: Drop 2 Piano Voicings](https://pianowithjonny.com/piano-lessons/drop-2-piano-voicings-the-complete-guide/).
  Drop-2 voicings additionally have exactly one useful inversion per chord tone in the top voice,
  which is precisely the property that makes nearest-tone voice leading (§5.2) cheap to compute.

### 5.5 The concrete algorithm for DAW Pro

Stated as something an implementer can build directly (elaborated architecturally in §7.1):

1. Represent a chord as a **pitch-class set** plus a **preferred bass pitch class** (root, unless an
   explicit inversion/slash chord is requested).
2. Track **the last voiced pitch set**, scoped to the current musical-typing session (reset when the
   mode turns off, matching the "session-only, never persisted" law already governing every other
   piece of Musical Typing state — `MusicalTypingController.swift:25-30`).
3. On a new chord trigger: enumerate candidate octave placements of the target pitch-class set within
   the active instrument preset's register window (§6); score each by summed absolute semitone
   distance from the previous voicing (§5.2); discard any candidate that puts a non-5th/non-octave
   interval below the preset's mud floor (§5.3) or spills outside the register window; take the
   cheapest survivor.
4. With no prior voicing (first chord of a session, or after a rest longer than some threshold), fall
   back to a fixed **home voicing** — root position at the preset's home octave.
5. This is a **pure function**: `(chordSymbol, previousVoicing?, instrumentPreset) → [MIDI pitches]`.
   No clock, no engine state, no randomness — the same purity discipline this tree already applies
   to `BreathContour.generate` and `MusicalTypingRouting`'s layout table, which is what makes it
   headlessly unit-testable and safe to call from a wire verb (§7.3) with no engine involvement at
   all.

---

## 6. Per-instrument presets

The owner asked for presets that vary "based on instrument being played/selected." What actually
varies, concretely, is **register**, **note count/density**, **voicing spacing**, **whether the
instrument plays the full chord at all**, and **onset timing**. This codebase already has real,
verified register data for some of these families — cited below rather than invented — and an
honest gap for the rest.

| Instrument preset | Register (home window) | What plays | Voicing style | Onset timing | Why |
|---|---|---|---|---|---|
| **Piano** (`.piano`, full range **MIDI 21–108 / A0–C8** verified at `InstrumentFrequencyReference.swift:990`) | Bass note ~MIDI 36–48 (C2–C3), chord body ~MIDI 60–72 (C4–C5) — a sub-window inside the full range, near the shipped keyboard-strip's own default C4 window | Root (doubled low) + triad/7th, close-voiced above | Nearest-inversion (§5.2), drop-2 when the chord has 4+ tones | Block chord, or a light 5–15 ms stagger low-to-high mimicking a hand that isn't perfectly synchronized | Matches how a real pianist splits hands — bass note, then the chord |
| **Pad / synth pad** | Higher and narrower than piano — e.g. body MIDI 60–79 (C4–G5) — deliberately kept clear of the sub-bass region since a pad is usually held *under* everything else in a mix | Full extended voicing (7th/9th) | **Open/spread** spacing (intervals >3rd apart) — a pad's slow attack rewards air between notes rather than a tight cluster | Slow strum (40–120 ms) or none; long, sustained hold | Pads exist to fill harmonic space, not to be rhythmically sharp; extended color chords (§2.2) are idiomatic here |
| **Guitar (strum feel)** (`.electricGuitar`/`.acousticGuitar`, **MIDI 40–76 / E2–E5**, verified at `InstrumentFrequencyReference.swift:881,928`, citation "guitar standard tuning") | The verified guitar register above | Full triad/7th, **root-position is idiomatic here** — §2.3's 94.1%-root-position finding is about exactly this instrument | Close-to-medium, guitar-shaped (open-string-like spacing rather than jazz-piano spacing) | **Deliberate strum stagger**, ~15–40 ms low-to-high for a downstroke feel (an upstroke variant is the same idea reversed) | The one instrument where root position + strum is the *authentic* sound, not the beginner one — flagged explicitly as the exception to §5's general voice-leading rule |
| **Bass** (`.electricBass`/`.uprightBass`, **MIDI 28–43 / E1–G2**, verified at `InstrumentFrequencyReference.swift:779,838`, citations "Wikipedia, Bass guitar (New Grove tuning)" / "Wikipedia, Double bass") | The verified bass register above | **Root only — a single note, never a stacked chord** | N/A (monophonic) | Held/sustained for the chord's duration, or a simple root–fifth alternation for genres that want motion | Directly answers the owner's own question ("whether a bass instrument should play the root only") — **yes**, and this is not a simplification, it is how basslines work. Handing a bass instrument the full 3–5 note chord is the single most common way a naive auto-harmonizer sounds wrong. |
| **Strings (section)** | Wide spread, e.g. MIDI 48–84 (C3–C6) — deliberately much wider top-to-bottom than piano's window | Full extended voicing, spread across the whole window, optionally doubling a tone an octave apart for a "section" feel | **Open/spread**, large intervals between adjacent voices — a close-position string chord reads as an organ, not a section, precisely because a real section is physically spread across register | Slow attack, sustained | Orchestral strings are voiced wide almost universally; this preset differs from Pad mainly in spread width and doubling, not in note count |

**The honest gap, stated rather than papered over:** `InstrumentFamily`
(`Sources/DAWCore/InstrumentFrequencyReference.swift:116-130`) is this codebase's one existing
instrument-category enum, and its own header says so explicitly — **"NO bowed strings and NO winds
in v1."** It covers percussion, bass, guitar, piano, and vocals only; there is no `.pad`, `.strings`,
`.brass`, or `.synthLead` case today. That is not a blocker — the GM soundfont strategy already
ships full 128-program General MIDI coverage (Strings, Ensemble, Brass, Synth Pad, Synth Lead are
all standard GM program groups) on `.soundBank` tracks
(`docs/research/soundfont-survey-gm-banks.md`), so the *instruments* this preset table needs already
exist and are playable today — only the *category enum* the voicing engine would key off of needs to
grow. §7.1 recommends extending `InstrumentFamily` with the missing cases rather than inventing a
second, parallel instrument-category type, on this codebase's own stated principle: "**ONE home**,
not a parallel note store" (the exact phrase used to justify the step sequencer sharing the piano
roll's note storage, `docs/ROADMAP.md:1050`).

---

## 7. A concrete proposal for DAW Pro

### 7.1 `DAWCore`: the voicing engine — new, pure, ONE home

A new file, e.g. `Sources/DAWCore/ChordVoicing.swift`, following the exact idiom already proven by
`BreathContour.swift` and `MusicalTypingRouting.swift`: a free namespace, no store, no engine, no
clock, fully headlessly testable.

- `enum ChordQuality` — start small and additive: major, minor, diminished, augmented, maj7, min7,
  dom7, sus4. Extended qualities (maj9, min9, add9 — needed for §2.2's lo-fi/neo-soul row) are a
  cheap follow-up once the shape exists.
- `struct ChordSymbol { rootPitchClass: Int, quality: ChordQuality }` (an explicit bass/slash field
  can be added later without breaking anything).
- `static func diatonicChords(key: Int, mode: KeyMode) -> [ChordSymbol]` — the seven scale-degree
  chords from §2.1, in order, for either major or natural minor.
- `static func voice(_ chord: ChordSymbol, previous: [Int]?, preset: InstrumentVoicingPreset) ->
  [Int]` — §5.5's algorithm, pure and synchronous.
- **Recommendation on the instrument-category axis**: extend `InstrumentFamily` (§6's gap) with the
  missing GM-standard cases rather than adding a second, competing enum — one category type, used by
  both the existing frequency-reference feature and this new voicing engine.
- **This is also the shared vocabulary `m23-cq-3` (the chord track, §1.2) will eventually want.** A
  chord track needs `struct Chord`/`chordSymbol` types it does not yet have; this module is a
  reasonable place for those types to live so a future chord-track build extends this file instead
  of inventing a second, disagreeing one. This document does not design the chord track — it only
  names the seam so nobody re-derives it from scratch.

### 7.2 `MusicalTypingController`: an additive mode

`MusicalTypingController` gains a mode, defaulting to today's shipped behavior so nothing existing
changes:

```
enum PlayMode {
    case notes                                          // today's shipped behavior, unchanged
    case chords(key: Int, keyMode: KeyMode, preset: InstrumentVoicingPreset)
}
```

When `.chords` is active, `perform(.note(semitone))` computes `ChordVoicing.voice(...)` instead of a
single pitch and pushes the *whole voiced set* through the existing `sink?.setHeldPitches(_:velocity:)`
call — the same seam, the same capturable path to `note.play` → `ProjectStore.playLiveNotes`, zero
new engine plumbing. **One data-structure change is required and is worth calling out explicitly**:
`keyPitches: [UInt16: Int]` (today: one key holds one pitch) needs to become `[UInt16: [Int]]` (one
key holds a *group* of pitches) so that releasing one key's chord doesn't strand or wrongly release
notes another held key's chord happens to share. This is an additive generalization, not a rewrite —
note mode is the degenerate case where every group has exactly one element.

Two policy points that need a decision, stated so they aren't discovered mid-implementation:

- **New-chord-replaces-old, by default.** Pressing a second chord key while the first is still held
  should *replace* the held set (like a real hand moving from one chord to the next), not add on top
  of it — both to match what a beginner expects ("press a new chord, hear a new chord") and to
  protect the 8-voice ceiling (§1.1). Holding two *different* keys at once (an advanced layering
  move) stays possible because each key's group is tracked independently; only a *single* key's
  re-press or a mode-wide "new chord" gesture triggers the replace.
- **Voicing density must respect `maxVoices = 8` with headroom.** A 5-note voicing plus a
  simultaneously-struck root on a second key can approach the ceiling fast. §5.5/§6 already cap
  density per preset (piano/guitar ≤4 notes, pad/strings ≤5), leaving room for the bass note and one
  layered extra without silently stealing the oldest — and *specifically* without stealing a bass
  note struck first, which `MusicalTypingController`'s documented oldest-note-steals-a-voice policy
  (`:396-416`) would otherwise do first.

### 7.3 Wire + MCP surface

Following m23-ct's own restraint (§1.1: one verb shipped of four predicted; the mode itself stayed
behind `debug.*`), and honoring §1.2's ruling that the manual surface is the deliverable, not the
wire:

- **The mode toggle, key/scale picker, and instrument-preset picker stay app-tier**, reachable
  through a `debug.musicalTypingChords`-shaped staging seam exactly like `debug.musicalTyping`
  today — they are controls for a human's on-screen surface, not a capability an agent needs a
  permanent verb for.
- **One new, pure, stateless wire verb is worth adding: `chord.voice`.** Not a live-performance verb
  — a read-only computation, in the same spirit as a bare `note.audition` call being documented
  read-only. Shape: `{key, keyMode, chord: <roman numeral or explicit symbol>, preset, previousVoicing?}
  → {pitches: [Int], symbol: "Am7"}`. The reason this earns its place despite §1.2's caution: it
  makes an *existing, already-declined-to-duplicate capability* — an agent authoring MIDI into a clip
  via `clip.setNotes`/`clip.addMIDI` — measurably better, by giving it access to the same
  voice-leading engine the human's one-finger button uses, instead of an agent hand-rolling
  root-position stacks. It adds no new live-trigger surface: **an agent (or the app itself) that
  wants to literally *sound* a computed voicing already has everything it needs in `note.play`**,
  which accepts up to 8 pitches today. No new live-trigger verb is proposed.
- **MCP tool**: `chord_voice`, named to match the existing `note_play`/`note_audition` pair, with
  description text that frames it as "you don't have to do the music theory — pass a key and a
  Roman numeral and get back a well-voiced pitch array," which is squarely inside this product's
  AI-native thesis without re-triggering the objection §1.2 records.
- **Tests**: a `DAWCoreTests` suite for `ChordVoicing` — property tests for the nearest-tone
  minimization (§5.2), the low-interval-limit floor (§5.3), register-window clamping, and the
  8-voice density cap, all headless; a `DAWAppKitTests` suite extending
  `MusicalTypingControllerTests`/`MusicalTypingRoutingTests` for the new mode and the
  `[UInt16: [Int]]` ledger change; a `Commands.swift` test for `chord.voice`'s pure computation; an
  MCP test for `chord_voice` matching the shape already used for `note_play`. This is the same
  four-part "capability ships a control command + an MCP tool + a test" law this project already
  applies everywhere (`CLAUDE.md`).

### 7.4 UI affordance on the keyboard strip

- A **`CHORDS`** mode chip beside the existing **`KEYS`** chip in the transport bar — same toggle
  visual language, same "explicit, never ambient" law m23-ct already established
  (`MusicalTypingController.swift:60-66`).
- Inside `MusicalKeyboardStrip`'s header, when chord mode is active: a compact **key/scale picker**
  (root + major/minor) and an **instrument-preset picker** (Piano / Pad / Guitar / Bass / Strings),
  built from the same `DigitalReadout`-style chips the header already uses for octave/velocity.
- On the keys themselves: the existing per-key letter legend (`drawLegend`,
  `MusicalKeyboardStrip.swift:271-295`) gains a **Roman-numeral / chord-quality legend** as an
  alternate label source in chord mode — same Canvas rendering path, new legend content, no new
  drawing code. This is model (A) from §4, delivered with the smallest possible UI diff against what
  already ships.
- A **named-progression preset row** (Pop I–V–vi–IV, '50s I–vi–IV–V, Pop-punk vi–IV–I–V, 12-bar
  blues, Jazz ii–V–I, Minor-rock i–VI–III–VII — §2.2's table, verbatim) that on selection (a) sets
  the key/mode picker, and (b) applies a **stronger "suggested" glow** to the 4–5 keys that
  progression uses, reusing the strip's existing held/lit visual language at a lower intensity, so a
  zero-theory user can be told "these four keys, in this order" without the product ever *removing*
  access to the other three diatonic keys. This is §4's "capture the curated-set model's advantage
  without making it a second feature," made concrete.

### 7.5 Phasing

1. **Phase 1 (ship first):** `ChordVoicing` (DAWCore, major/minor triads + maj7/min7/dom7/sus4 only),
   the `MusicalTypingController` mode + ledger change, the Roman-numeral legend, the key/scale + Piano
   preset only. This alone delivers "press one key, hear a real chord in a key you picked" — the
   core of the ask — and is sized closer to the breath pad's P1 (a pure model plus a panel) than to
   `m23-cq-3`'s chord-track scope (weight S–M, no engine work, no new RT state).
2. **Phase 2:** the named-progression preset row + highlight overlay (§7.4); Guitar/Bass/Pad/Strings
   presets and their strum/roll timing (§6); the `chord.voice` wire verb + MCP tool (§7.3).
3. **Phase 3, opportunistic:** extend `InstrumentFamily` with the missing GM categories properly
   (rather than the narrower preset-only enum Phase 1/2 can ship with first); feed chord mode's held
   set into `m23-cq-2`'s real-time arpeggiator once that item is scheduled (§1.2, §3); consider
   whether `KeyEstimator`/`KeyEstimate` (`Sources/DAWEngine/Analysis/KeyEstimator.swift`, already
   used internally per `ProjectStore+Analysis.swift:84-86` but **not currently wire-exposed as a
   general "what key is this project in" verb** — confirmed by grep, no `analyzeKey`-shaped command
   exists in `Commands.swift`) is worth surfacing so the key picker can default to a project's
   detected key instead of always defaulting to C major.

---

## 8. Actionable takeaways

- **Recommend a new roadmap item** (ID left for the caller to assign, alongside the `m23-cq` family)
  scoped exactly as §7.5 Phase 1: `ChordVoicing` (DAWCore) + `MusicalTypingController` chord mode +
  Roman-numeral legend + one instrument preset. Weight **S–M** — it rides m23-ct's entire delivery
  pipe (§0, §1.1) and touches no engine/RT code.
- **Cross-reference, don't merge, with `m23-cq-3`** ("Chord track + scale lock," `docs/ROADMAP.md:1052`).
  Different product (global timeline lane vs. one-finger performance chord). Recommend the two
  eventually share `ChordVoicing`'s `ChordSymbol`/`ChordQuality` types (§7.1) rather than each
  inventing its own — flag this in whichever roadmap entry gets written so a future `daw-architect`
  pass on the chord track doesn't re-derive a second harmonic vocabulary.
- **Flag `m23-cq-2` (real-time arpeggiator)** as newly more valuable once chord mode exists — both
  Ableton's and Logic's arpeggiators take a held chord as their entire input (§3), and m23-cq-2 is
  already unblocked now that m23-ct has shipped (§1.2).
- **Scope fence, stated once so it isn't re-litigated**: this document does not design the chord
  track, does not propose a live-trigger wire verb beyond the existing (already-polyphonic)
  `note.play`, and does not propose the transposing-single-chord model for v1 (§4).
- **Ship order within the feature, if the owner wants the smallest possible first slice**: key/scale
  picker + Roman-numeral keys + Piano preset only, no progression-preset row, no
  guitar/bass/pad/strings presets. That alone answers "play a chord with one finger" and is a couple
  of days of work given everything in §1.1 it reuses.
- **One implementation risk worth flagging to whoever builds this**: the `keyPitches: [UInt16: Int]
  → [UInt16: [Int]]` ledger change (§7.2) touches the exact data structure `MusicalTypingController`'s
  own test suite (`Tests/DAWAppKitTests/MusicalTypingControllerTests.swift`) already exercises for
  note mode — that suite is the right place to prove the change is additive (note mode's existing
  tests must stay green unmodified) before any chord-mode-specific test is trusted.
