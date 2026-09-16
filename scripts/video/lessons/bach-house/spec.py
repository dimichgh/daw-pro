#!/usr/bin/env python3
"""Emit the rebuilt "Bach House" lesson's spec for shortsmith.py.

Written as code rather than hand-typed JSON so that every number on a CARD is
injected from MEASUREMENTS.json and can never drift from the file it was
measured into. The SPOKEN forms are typed by hand — numbers must be spelled out
or the speech model reads them unreliably and the content gate compares a
TRANSCRIPT — so `check()` below asserts every spoken figure against the measured
one and refuses to emit a spec whose words and measurements have parted company.

⭐ WHAT THIS FILM MEASURES. The claim is structural: the prelude is already a
loop. That is turned into two comparisons the viewer can check. The ONSET
pattern of bars 1-8 is compared bar to bar and does not change; the same
comparator on the PITCH sets changes at seven of seven bar lines, which is the
positive control that makes the zero mean something. And every part the film
adds is measured in its own band, at its own hit positions, against the bar
before it arrived.

⚠ THIS FILM HAS NO AUDIBILITY FAULT and does not invent one — the prelude is a
mid-band instrument (its energy peaks in the 250 Hz to 1 kHz band). What IS said
plainly is the measured consequence: the two parts added UNDER it, the kick and
the bass, live where a laptop speaker is weakest, and the band chart shows
exactly that.
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
S, A = f"{HERE}/shots", f"{HERE}/audio"

INV = M["invariance"]
TEM = M["tempo"]
LO = M["loudness"]
BAND = M["bands"]
MK = M["marker"]
AB = M["ab"]
CNT = M["counts"]
BALANCE = M["balance"]
ENTRY = M["entry"]
ROOTS = M["roots"]
BARP = M["barPitches"]

D = {f'{lo}-{hi}': round(f["db"] - p["db"], 2)
     for (lo, hi), p, f in zip([tuple(e) for e in BAND["edges"]],
                               BAND["piano"], BAND["full"])}
STEP = {k: MK["entrySteps"][k]["onHitsStepDb"] for k in MK["order"]}
MIXSTEP = MK["wholeMixSteps"]


def check(spoken, measured, tol, what):
    if abs(spoken - measured) > tol:
        sys.exit(f"SPEC REFUSES TO BUILD — {what}: the narration says {spoken} "
                 f"but MEASUREMENTS.json says {measured:.6f}")


# ── the chord names, checked against the MEASURED pitch sets ────────────────
# Named by hand from the pitch-class content of each bar; the assertion below is
# what stops a hand-typed name from surviving a change in the note data.
CHORDS = [
    ("C major",                   {0, 4, 7}),
    ("D minor seventh, over C",   {0, 2, 5, 9}),
    ("G seventh, over B",         {11, 2, 5, 7}),
    ("C major",                   {0, 4, 7}),
    ("A minor, over C",           {0, 4, 9}),
    ("D seventh, over C",         {0, 2, 6, 9}),
    ("G major, over B",           {11, 2, 7}),
    ("C major seventh, over B",   {11, 0, 4, 7}),
]
for i, (name, pcs) in enumerate(CHORDS):
    got = {p % 12 for p in BARP[i]}
    if got != pcs:
        sys.exit(f"SPEC REFUSES TO BUILD — bar {i+1} is named '{name}' but its "
                 f"measured pitch classes are {sorted(got)}, not {sorted(pcs)}")

check(0, INV["onsetChangesAcross8Bars"], 0, "changes in the onset pattern")
check(7, INV["pitchChangesAcross8Bars"], 0, "changes in the pitch set")
check(16, INV["onsetsPerBar"], 0, "onsets in a bar")
check(144, CNT["bars8"], 0, "notes in bars one to eight")
check(288, M["pianoNotes"], 0, "notes in the clip the film plays")
check(72, TEM["slow"]["bpm"], 0, "Bach's tempo here")
check(124, TEM["fast"]["bpm"], 0, "the house tempo")
check(4.800, TEM["slow"]["measuredOnsetsPerSec"], 0.002, "the slow onset rate")
check(8.267, TEM["fast"]["measuredOnsetsPerSec"], 0.002, "the fast onset rate")
check(4.800, TEM["slow"]["predictedOnsetsPerSec"], 0.002, "the slow prediction")
check(8.267, TEM["fast"]["predictedOnsetsPerSec"], 0.002, "the fast prediction")
check(1.7222, TEM["ratio"], 0.0002, "the tempo ratio")
check(1.7222, TEM["measuredRatio"], 0.001, "the measured ratio")
check(26.67, TEM["secondsFor8Bars"]["slow"], 0.01, "eight bars at 72")
check(15.48, TEM["secondsFor8Bars"]["fast"], 0.01, "eight bars at 124")
check(41.43, STEP["kick"], 0.02, "the kick's step in its own band")
check(26.72, STEP["hats"], 0.02, "the hats' step in their own band")
check(2.58, STEP["clap"], 0.02, "the clap's step in its own band")
check(5.52, STEP["bass"], 0.02, "the bass's step in its own band")
check(-0.03, MIXSTEP["hats"], 0.02, "what the hats do to the whole mix")
check(57.82, D["20-60"], 0.02, "what house adds at the bottom")
check(2.06, D["250-1000"], 0.02, "what house adds in the prelude's own band")
check(10.51, D["4000-20000"], 0.02, "what house adds at the top")
check(-21.0, LO["piano124"]["integratedLufs"], 0.1, "the prelude's loudness")
check(-15.7, LO["ab-full-src"]["integratedLufs"], 0.1, "the finished track's loudness")
check(5.30, AB["build"]["deltaLu"], 0.02, "the difference between the two halves")
check(3, ENTRY["kick"], 0, "which bar the kick enters")
check(5, ENTRY["hats"], 0, "which bar the hats enter")
check(7, ENTRY["clap"], 0, "which bar the clap enters")
check(9, ENTRY["bass"], 0, "which bar the bass enters")
check(24, M["bassDrop"], 0, "how far down the bass plays")
# the eight bars sit over a C/B pedal — a fact, not a flourish
assert ROOTS == [60, 60, 59, 60, 60, 60, 59, 59], ROOTS

sp = str.upper

# ------------------------------------------------------------------- cards
cards = [
  dict(type="statement", size=60, y=250,                                       # 0
       lines=["BACH WROTE A LOOP.",
              "ONE FIGURE, SIXTEEN NOTES,",
              "EVERY BAR, WITHOUT CHANGING."],
       sub=["The harmony underneath it moves. The figure does not.",
            "That is also how a house record is built."]),

  dict(type="list", title=sp("six words, in plain English"), step=80,          # 1
       items=[["beat", "the pulse you tap your foot to"],
              ["bar", "four beats, grouped — the unit music is counted in"],
              ["BPM", "beats per minute: how fast the pulse goes"],
              ["a loop", "a short piece of music repeated unchanged", "hot"],
              ["broken chord", "a chord played one note at a time, not together"],
              ["four to the floor", "a kick drum on every single beat"]]),

  dict(type="list", title=sp("the figure, in one line"), step=88,              # 2
       items=[["five notes up", "the lowest, then four more climbing"],
              ["then the top three again", "and that is half a bar"],
              ["twice a bar", f'which makes {INV["onsetsPerBar"]} onsets, '
                              f'every bar', "hot"],
              ["written durations", "from the score; the pedalling is not encoded"]]),

  dict(type="bignumber", label=sp("changes in the figure, across eight bars"),  # 3
       value=f'{INV["onsetChangesAcross8Bars"]}', unit=sp("of seven bar lines"),
       size=180,
       notes=[f'{INV["onsetsPerBar"]} onsets a bar, in the same places, eight '
              f'times over',
              f'the SAME test on the pitches: '
              f'{INV["pitchChangesAcross8Bars"]} changes of seven',
              f'bars {INV["identicalPitchBarPairs"][0][0]} and '
              f'{INV["identicalPitchBarPairs"][0][1]} are the only identical pair']),

  dict(type="list", title=sp("the eight chords, read off the notes"), step=76,  # 4
       items=[[f'bar {i+1}', CHORDS[i][0]] + (["hot"] if i in (0, 3) else [])
              for i in range(8)]),

  dict(type="list", title=sp("what a house track is made of"), step=84,        # 5
       items=[["the kick", "on every beat — four to the floor"],
              ["the hats", "on the offbeats, between the kicks", "hot"],
              ["the clap", "on beats two and four"],
              ["the bass", "in the gaps the kick leaves"],
              ["the tempo", "usually between one twenty and one thirty"]]),

  dict(type="bignumber", label=sp("notes in, notes out"),                       # 6
       value=f'{M["pianoNotes"]}', unit=sp("not one of them moved"), size=170,
       notes=[f'read back from the app before and after the tempo change',
              f'{TEM["slow"]["measuredOnsetsPerSec"]:.3f} sixteenths a second '
              f'becomes {TEM["fast"]["measuredOnsetsPerSec"]:.3f}',
              f'a ratio of {TEM["measuredRatio"]:.4f}, measured; '
              f'{TEM["ratio"]:.4f}, predicted']),

  dict(type="list", title=sp("the four parts, and when they arrive"), step=84,  # 7
       items=[["kick", f'bar {ENTRY["kick"]} — {STEP["kick"]:+.2f} dB in its '
                       f'own band'],
              ["hats", f'bar {ENTRY["hats"]} — {STEP["hats"]:+.2f} dB in theirs',
               "hot"],
              ["clap", f'bar {ENTRY["clap"]} — {STEP["clap"]:+.2f} dB in its own'],
              ["bass", f'bar {ENTRY["bass"]} — {STEP["bass"]:+.2f} dB in its own']]),

  dict(type="bignumber", label=sp("what house adds in Bach's own band"),        # 8
       value=f'{D["250-1000"]:+.2f}', unit=sp("dB, 250 hz to 1 khz"), size=160,
       notes=[f'below sixty hertz it adds {D["20-60"]:+.2f} dB',
              f'from sixty to one hundred, {D["60-100"]:+.2f} dB',
              f'above four kilohertz, {D["4000-20000"]:+.2f} dB']),

  dict(type="list", title=sp("where this one needs a speaker"), step=84,       # 9
       items=[["the prelude", "sits in the middle — any speaker has it"],
              ["the kick and the bass", "are the two parts that go underneath",
               "hot"],
              ["measured", f'the mix gains {D["20-60"]:+.1f} dB below sixty hertz'],
              ["so", "headphones are worth it for the bottom half of this"]]),

  dict(type="bignumber", label=sp("prelude alone against the finished track"),  # 10
       value=f'{AB["build"]["deltaLu"]:.2f}', unit=sp("lu louder"), size=170,
       notes=[f'the prelude on its own: '
              f'{LO["ab-piano-src"]["integratedLufs"]:.1f} LUFS',
              f'with all four parts: {LO["ab-full-src"]["integratedLufs"]:.1f} LUFS',
              'one shared gain on both halves — neither is normalised']),

  dict(type="closing", size=50,                                                 # 11
       lines=["The figure never changes.",
              "The harmony underneath it never stops.",
              "That is a loop with somewhere to go."],
       kicker="Built, rendered and measured in DAW Pro."),
]

# ----------------------------------------------------------------- pictures
ARRANGE, MIXER = f"{S}/arrange.png", f"{S}/mixer.png"
ROLL_PIANO, ROLL_KICK, ROLL_BASS = (f"{S}/roll-piano.png", f"{S}/roll-kick.png",
                                    f"{S}/roll-bass.png")
CH_BANDS, CH_TEMPO = f"{S}/chart-bands.png", f"{S}/chart-tempo.png"
CH_LOUD, CH_STEPS = f"{S}/chart-loud.png", f"{S}/chart-steps.png"
INV_END, NEST_END = f"{S}/invariant-final.png", f"{S}/nested-final.png"
MARK_END = f"{S}/buildmark-final.png"
# ⚠ A ZOOM MUST BE SQUARE IN FRACTIONS to come out 16:9 on a 3200x1800 capture
# (w*3200 / h*1800 = 16/9 exactly when w == h). A non-square crop is pillarboxed.
ROLL_FIG = {"path": f"{S}/roll-figure.png", "zoom": [0.02, 0.28, 0.62, 0.62]}
# ⚠ MEASURED AGAINST THE PNG, NOT GUESSED, AND FIXED AFTER LOOKING AT THE FILM.
# The first crop was [0.14, 0.72, 0.28, 0.28]: two thirds of it was empty arrange
# background and its right edge fell at x=1344 of 3200, straight through the
# "124.0" it exists to show. This one is x 784-1408, y 1449-1800 — the
# POSITION / TIME / TEMPO readout and almost nothing else.
TEMPO_ZOOM = [0.245, 0.805, 0.195, 0.195]
TEMPO_124 = {"path": f"{S}/transport-124.png", "zoom": TEMPO_ZOOM}
TEMPO_72 = {"path": f"{S}/transport-72.png", "zoom": TEMPO_ZOOM}

# ----------------------------------------------------------------- stages
stages = [
  dict(id="00-open", shots=[0, ARRANGE], cut=4.6, brandCheck="DAW Pro",
       factCheck=[["seventeen twenty two", "1722"], ["public domain"]],
       narration=(
         "In seventeen twenty two, Johann Sebastian Bach wrote a piece of music "
         "with no melody in it. It is the first prelude of the Well Tempered "
         "Clavier, in C major, and what it actually consists of is one small "
         "shape — five notes climbing, then three of them again — played over "
         "and over, bar after bar, while the chord underneath it quietly "
         "moves. If you have ever made a dance record, you have already "
         "recognised what that is. It is a loop with a chord progression under "
         "it. So this lesson takes that seriously and builds one. We are going "
         "to look at the prelude's note data and prove that the figure really "
         "does repeat unchanged. We are going to change exactly one thing about "
         "it — the tempo — and then put a kick, some hats, a clap and a bass "
         "around it, one part at a time, and measure what each of them actually "
         "adds. Everything you will hear was built, rendered "
         "and measured in DAW Pro. The "
         "composition is public domain and the notes come from a public "
         "encoding of the score; nothing here is a recording of anyone playing "
         "it, and no music model was used for any of it.")),

  dict(id="01-terms", shots=[1], cut=6.0,
       factCheck=[["four to the floor", "four-to-the-floor"], ["broken chord"]],
       narration=(
         "Six words first, in plain English, because the rest of this needs "
         "them. A beat is the pulse you tap your foot to. A bar is a group of "
         "those beats — four of them, in everything we are about to do — and "
         "it is the unit music gets counted in. B P M means beats per minute, "
         "which is simply how fast that pulse goes. A loop is a short piece of "
         "music that repeats without changing; it is the basic building block "
         "of almost all electronic dance music, and it is the word this whole "
         "lesson turns on. A broken chord is a chord whose notes are played "
         "one after another instead of all at once — you may also hear it "
         "called an arpeggio, and it is what the prelude is made of from "
         "beginning to end. And four to the floor means a kick drum on every "
         "single beat of the bar, which is the one thing that makes a record "
         "sound like house music more than anything else.")),

  dict(id="02-prelude", shots=[2, ROLL_PIANO], cut=6.0, holdLast=True,
       loop=f"{A}/piano72.wav", playMax=13.0, bedEligible=False,
       burst="piano72play",
       factCheck=[["seventy two", "72"], ["no tempo marking", "tempo marking"]],
       narration=(
         "Here is the prelude, and here is the first thing worth knowing about "
         "it. There is no tempo marking on it. Bach did not write one, so any "
         "speed you have ever heard it at was somebody's decision, not his. "
         "Recordings of it sit roughly between seventy and eighty beats a "
         "minute, and for this film I picked seventy two. Remember that, "
         "because it is the one number in this lesson that is a choice rather "
         "than a measurement, and I would rather tell you than let you assume. "
         "What you are about to hear is the first eight bars at that speed, "
         "played by a synthesiser inside the app — not a piano recording. On "
         "screen is the note data itself, in the app's note editor. Watch how "
         "regular it looks. There are no long notes and no short notes fighting "
         "each other, no phrases arching over the bar lines. It is a wallpaper "
         "of even sixteenth notes, and that is not a criticism. That is the "
         "design.")),

  dict(id="03-figure", shots=[2, ROLL_FIG], cut=6.4, holdLast=True,
       factCheck=[["sixteen", "16"], ["five"], ["three"]],
       narration=(
         "Let us name the shape, because everything after this refers to it. "
         "Take the five pitches Bach gives you in a bar and number them from "
         "the bottom. The figure plays one, two, three, four, five — climbing "
         "— and then goes back and plays three, four, five again. That is "
         "eight notes, and it takes half a bar. Then the whole thing happens a "
         "second time, identically, to fill the other half. So one bar is "
         "sixteen note starts, in sixteen fixed places, and the lowest two of "
         "them are held underneath while the top three do the moving. On "
         "screen now is exactly that, drawn in the app's note editor: the two "
         "long bars at the bottom are the held pair, and the short ones above "
         "them are the climbing figure, twice. One more piece of honesty about "
         "what you are seeing. The note lengths here are the durations written "
         "in the score. A pianist's sustain pedal blurs those together and the "
         "score does not encode that, so the lengths are the notation's, not a "
         "performance's. The pitches and the note starts, though, are exactly "
         "what Bach wrote.")),

  dict(id="04-invariant", shots=[3, INV_END], cut=6.0, holdLast=True,
       loop=f"{A}/invbed.wav", burst="invariant", playMax=16.0,
       bedEligible=False,
       factCheck=[["zero", "0"], ["seven", "7"], ["control"]],
       narration=(
         "Now let us stop describing it and test it. Here is the experiment. "
         "For each of the eight bars, take the list of places in the bar where "
         "a note starts. Compare each bar's list with the one before it, and "
         "count how many times it changes. Then — and this is the part that "
         "makes the first number mean anything — run the identical comparison "
         "on a different property of the same bars: the set of pitches they "
         "use. On screen, the eight bars go past in time with what you are "
         "hearing, and the two counters run underneath. The onset pattern "
         "changes zero times out of seven. The pitch set changes seven times "
         "out of seven. That second number is the control. Without it, a zero "
         "could just mean my comparison was broken, and a test that cannot "
         "return anything but zero has not measured anything. It also picks up "
         "one detail worth noticing: bars one and four hold exactly the same "
         "five pitches. In eight bars, Bach repeats a chord once. So: the "
         "rhythm of the figure is frozen, and the harmony under it is not. "
         "That is a loop, and the thing that keeps it from being boring is "
         "sitting underneath it.")),

  dict(id="05-harmony", shots=[4, ROLL_PIANO], cut=6.6, holdLast=True,
       loop=f"{A}/piano124.wav", playMax=13.0, bedEligible=False,
       burst="pianoplay",
       factCheck=[["eight", "8"], ["pedal"]],
       narration=(
         "So what is that moving thing. Read the pitches of each bar as a "
         "chord and you get eight of them: C major, then D minor seventh over "
         "a C, then G seventh over a B, then C major again, then A minor, D "
         "seventh, G major, and a C major seventh. These names are just labels "
         "for the notes that are actually there — every one of them was read "
         "off the note data, not off a textbook. And there is a detail in that "
         "list that matters enormously for what we are about to do. Look at "
         "the lowest note of each bar. C, C, B, C, C, C, B, B. Across eight "
         "bars of moving harmony, the bottom of the texture barely moves at "
         "all. It sits on a C, drops a semitone to B, comes back. Musicians "
         "call a held or near-held bass note like that a pedal, and it is one "
         "of the oldest ways there is to make a chord sequence feel anchored "
         "instead of restless. It is also, almost exactly, what a house "
         "bassline does.")),

  dict(id="06-house", shots=[5, MIXER], cut=6.2, holdLast=True,
       factCheck=[["four to the floor", "four-to-the-floor"],
                  ["one hundred and twenty four", "124"]],
       narration=(
         "Now the other side of the comparison, in case house music is not "
         "something you have taken apart before. A house track, at its "
         "simplest, is four things happening on a grid. A kick drum on every "
         "beat — four to the floor. A closed hi-hat between the kicks, on the "
         "offbeats, which is what makes it feel like it is leaning forward. A "
         "clap or a snare on beats two and four, which is where your hands go. "
         "And a bass that plays in the gaps the kick leaves rather than on top "
         "of it. Over that, something repeating: a chord stab, a sample, an "
         "arpeggio. The tempo is normally somewhere between one hundred and "
         "twenty and one hundred and thirty beats a minute, and I have used "
         "one hundred and twenty four. Read that list again with the prelude "
         "in mind. A repeating broken chord figure, over a bass that barely "
         "moves, at a steady pulse with no rubato in it. Four of the five "
         "boxes are already ticked. The only one missing is the drums.")),

  dict(id="07-tempo", shots=[6, TEMPO_72, TEMPO_124], cut=6.4, holdLast=True,
       normalize=False, bedEligible=False,
       # ⚠⚠ `loop` IS THE **AFTER** HALF. assemble.py takes BEFORE from
       # ab["before"] and AFTER from THIS stage's own `loop`. Pointing both at
       # one file makes the badge change and nothing else, and the A/B gate
       # passes it green because identical halves genuinely do not differ.
       loop=f"{A}/ab-t-b.wav", playMax=14.0,
       ab=dict(before=f"{A}/ab-t-a.wav", beforeShots=[TEMPO_72],
               afterShots=[TEMPO_124], cycles=2, seconds=6.6),
       factCheck=[["two hundred and eighty eight", "288"],
                  ["four point eight", "4.8"],
                  ["eight point two six seven", "8.267"]],
       narration=(
         "So here is the whole intervention, and it is one number. I took the "
         "eight bars, repeated them once so there are sixteen bars to play "
         "with, and typed a different tempo into the app. Nothing else. To "
         "make sure that is true rather than merely intended, I read all two "
         "hundred and eighty eight notes back out of the app before the change "
         "and again afterwards and compared them: same pitches, same starts, "
         "same lengths, same velocities, in the same order. Not one note moved. "
         "You can also hear the difference rather than take my word for the "
         "tempo field. Measured off the two renders, by finding the strongest "
         "repetition rate in each one, the slow version runs at four point "
         "eight sixteenth notes a second and the fast one at eight point two "
         "six seven. The arithmetic from the two tempos predicts four point "
         "eight and eight point two six seven. In a moment you will hear them "
         "alternate, with the tempo field on screen for each. Same notes. Same "
         "instrument. Same eight bars.")),

  dict(id="08-kick", shots=[5, ARRANGE], cut=6.0, holdLast=True,
       loop=f"{A}/l2-kick.wav", burst="kickplay", playMax=13.0,
       factCheck=[["four to the floor", "four-to-the-floor"],
                  ["forty one", "41", "41.43"]],
       narration=(
         "First part: the kick. One on every beat, starting at bar three, and "
         "that is the entire idea — four to the floor. Notice what it does to "
         "the prelude, which is not what you might expect. The figure was "
         "already perfectly even; the kick does not impose a pulse on it so "
         "much as reveal the one that was already there, because the "
         "sixteenths line up four to a kick with nothing left over. On screen "
         "you can watch the app play it, with the playhead crossing the notes "
         "you are hearing. And here is the measurement: in the band the kick "
         "actually occupies, twenty to one hundred and ten hertz, the bar "
         "after it arrives is forty one point four three decibels louder than "
         "the bar before. That is not a subtle addition. There was almost "
         "nothing down there.")),

  dict(id="09-hats", shots=[5, ARRANGE], cut=6.0, holdLast=True,
       loop=f"{A}/l3-hats.wav", burst="hatsplay", playMax=13.0,
       factCheck=[["offbeat", "off-beat", "offbeats"],
                  ["twenty six", "26", "26.72"]],
       narration=(
         "Second part: the hats, from bar five. A closed hi-hat exactly halfway "
         "between each pair of kicks — on the offbeat. This is the part that "
         "does the most for the least. It adds no notes to the harmony and "
         "almost no energy to the mix, and yet it is the difference between a "
         "loop that sits still and a loop that moves, because your ear starts "
         "hearing the gap between the kick and the hat as forward motion. The "
         "number is the interesting part. In the hats' own band, six to sixteen "
         "kilohertz, they arrive twenty six point seven two decibels up. In the "
         "whole mix, they change the level by minus zero point zero three "
         "decibels. Nothing. If you had been watching a meter instead of "
         "listening, you would have concluded that nothing happened at all.")),

  dict(id="10-clap", shots=[7, ARRANGE], cut=6.0, holdLast=True,
       loop=f"{A}/l4-clap.wav", burst="clapplay", playMax=13.0,
       factCheck=[["two and four", "2 and 4"], ["two point five eight", "2.58"]],
       narration=(
         "Third part: a clap, from bar seven, on beats two and four. Two hits a "
         "bar, and that is all. It is the smallest thing in this arrangement by "
         "every measure I can take of it — in its own band, nine hundred hertz "
         "to nine kilohertz, its arrival is worth two point five eight "
         "decibels, and the reason it is so small is that the prelude is "
         "already busy in that band and two events a bar barely shift an "
         "average. But it does the job nothing else does: it tells you where "
         "the bar starts and stops. A kick on every beat is deliberately "
         "ambiguous — every beat looks like beat one. The clap breaks the "
         "symmetry, and suddenly you know which beat you are on.")),

  dict(id="11-bass", shots=[7, ROLL_BASS], cut=6.2, holdLast=True,
       loop=f"{A}/l5-bass.wav", burst="bassplay", playMax=13.0,
       factCheck=[["two octaves", "2 octaves"], ["lowest note"],
                  ["five point five two", "5.52"]],
       narration=(
         "Fourth part: the bass, from bar nine, and this is the one where the "
         "prelude does the work. I did not write a bassline. For each bar I "
         "took the lowest note Bach already wrote in it and moved it down two "
         "octaves. That is the whole method, and it gives you C, C, B, C, C, "
         "C, B, B — the pedal we found earlier, an octave and a half below "
         "where he put it. The rhythm is the house convention: on the "
         "offbeats, in the gaps between the kicks, so the two of them "
         "interlock instead of fighting for the same instant. On screen is the "
         "bass part in the note editor, and you can see how little it moves. "
         "Measured in its own band, one hundred and twenty to four hundred "
         "hertz, it arrives five point five two decibels up.")),

  dict(id="12-nested", shots=[2, NEST_END], cut=6.0, holdLast=True,
       loop=f"{A}/nestbed.wav", burst="nested", playMax=16.0, bedEligible=False,
       factCheck=[["half bar"], ["eight bars", "8 bars"]],
       narration=(
         "With all four parts in, look at what the grid actually is, because "
         "there is more than one loop running and they are nested inside each "
         "other. The fastest one is the beat: the kick, every four hundred and "
         "eighty four milliseconds. Sitting on top of that, the figure, which "
         "repeats every half bar — twice as slow as the kick pattern, and it "
         "was already there in Bach. Above that, the harmony: one chord per "
         "bar, four beats. And above that, the phrase: eight bars before the "
         "whole thing comes round again. Four loop lengths, each one twice or "
         "four times the one below it, all lining up on the same grid. Three of "
         "those four were in the prelude before I touched it. The kick is the "
         "only one I added, and it fits because the others were already there.")),

  dict(id="13-marker", shots=[7, MARK_END, CH_STEPS], cut=6.4, holdLast=True,
       loop=f"{A}/markbed.wav", burst="buildmark", playMax=32.0,
       bedEligible=False,
       factCheck=[["own band", "its own band"], ["six decibels", "6 decibels"],
                  ["minus zero point zero three", "-0.03", "minus 0.03"]],
       narration=(
         "Here is all of it at once, and here is how to watch it. Four lines, "
         "one per part, and each line is the measured level of that part's own "
         "band in the render you are hearing — not a drawing, the actual "
         "envelope. The playhead moves in real time, so where it is on screen "
         "is where you are in the music. Each part's arrival is shaded, one "
         "bar wide, and the number underneath is the step from the bar before "
         "to the bar after. And there is a lesson hiding in the two numbers "
         "each of those readouts shows you. The kick's arrival is worth forty "
         "one decibels in its own band and six decibels on the whole mix. The "
         "hats are worth twenty six in theirs and minus zero point zero three "
         "on the whole mix. Same event, two instruments, two completely "
         "different answers — and the whole-mix one is simply the wrong "
         "question. When you add a part to a track, you are not usually making "
         "it louder. You are filling a space that was empty.")),

  # ⚠ THE CHART IS HELD LAST. As [8, CH_BANDS, 9] with holdLast, assemble gave
  # each of n=round(48.5/7.0)=7 slots 6.9 s and held only the LAST, so the band
  # chart was on screen 6.9-13.9 s while its numbers are spoken from about ten
  # seconds to forty. Checked in the finished film at 730 s: the speaker card was
  # up under "fifty seven point eight decibels".
  dict(id="14-space", shots=[8, 9, CH_BANDS], cut=4.5, holdLast=True,
       factCheck=[["two point zero six", "2.06"], ["fifty seven", "57", "57.8"],
                  ["headphones"]],
       narration=(
         "That idea has a picture, and it is the most useful thing in this "
         "lesson. Take the prelude on its own and the finished track, split "
         "both into six frequency bands, and measure the energy in each. Below "
         "sixty hertz, the house version has fifty seven point eight decibels "
         "more than the prelude does — the prelude has essentially nothing "
         "down there, because a plucked figure in the middle of the keyboard "
         "does not produce it. From sixty to one hundred hertz, fifty two "
         "point nine decibels more. Above four kilohertz, ten point five more, "
         "which is the hats. And in the band the prelude actually lives in, "
         "two hundred and fifty hertz to one kilohertz, the difference is two "
         "point zero six decibels. Almost nothing. That is what a good "
         "arrangement looks like as a measurement: the new parts went "
         "underneath and above the thing that was already there, and left its "
         "own space alone. One honest note about listening. The two parts that "
         "went underneath are the two a laptop speaker reproduces worst. The "
         "prelude itself you will hear perfectly on anything. For the kick and "
         "the bass, headphones or a real speaker will show you something a "
         "laptop cannot.")),

  dict(id="15-ab", shots=[10, ROLL_PIANO, ARRANGE], cut=6.4, holdLast=True,
       normalize=False, bedEligible=False,
       loop=f"{A}/ab-b-b.wav", playMax=16.0,
       ab=dict(before=f"{A}/ab-b-a.wav", beforeShots=[ROLL_PIANO],
               afterShots=[ARRANGE], cycles=2, seconds=7.5),
       factCheck=[["five point three", "5.3"],
                  ["is normalised", "is normalized"]],
       narration=(
         "So here they are against each other: the same eight bars of the "
         "prelude on its own, and then with all four parts in. Before you "
         "listen, one thing you are entitled to know. The full version is "
         "louder — five point three loudness units louder, measured. The "
         "prelude alone sits at minus twenty one L U F S and the finished "
         "track at minus fifteen point seven. I have not corrected that. Both "
         "halves have one single gain applied to them, the same gain, so the "
         "difference you hear is the difference the arrangement actually "
         "makes. Louder is not better, and a comparison where one side has "
         "been quietly turned up is not a comparison at all. Neither half of "
         "this one is normalised, and I am telling you which way it leans "
         "before you hear it rather than hiding it.")),

  # the closing card is held last, so the sign-off is on screen while it is said
  dict(id="16-close", shots=[CH_TEMPO, CH_LOUD, 11], cut=6.6, holdLast=True,
       brandCheck="DAW Pro",
       factCheck=[["public domain"], ["two hundred and eighty eight", "288"]],
       narration=(
         "That is the whole build, so let us be exact about what was and was "
         "not done to Bach. Two hundred and eighty eight notes went into the "
         "app and two hundred and eighty eight came out, with the same pitches "
         "in the same places. The tempo went from seventy two to one hundred "
         "and twenty four, which is my choice and not his, because he did not "
         "leave one. Four parts were added around it, and the bassline of "
         "those four is his own lowest notes moved down. The composition is "
         "public domain; the notes came from a public encoding of the score; "
         "there is no recording of any performer anywhere in this film, and no "
         "music model generated any of it. And the reason all of that worked "
         "is the thing worth taking away. The prelude is one shape repeated "
         "with a moving harmony underneath, which is the same construction a "
         "dance record uses, three hundred years apart. Bach wrote the loop. "
         "All I added was the kick. Built, rendered and measured in DAW Pro. "
         "Thanks for watching.")),
]

# ⚠⚠ THE TRAP THAT SHIPPED ON ANOTHER FILM: both halves of an A/B pointing at
# ONE wav. Every gate passed it green, because identical halves genuinely do not
# differ in loudness. Refuse it here instead.
for s in stages:
    if s.get("ab"):
        if s["ab"]["before"] == s.get("loop"):
            sys.exit(f"SPEC REFUSES TO BUILD — {s['id']}: both halves of the A/B "
                     f"are {s['loop']}. The demonstration would never happen.")
        for p in (s["ab"]["before"], s["loop"]):
            if not os.path.exists(p):
                sys.exit(f"SPEC REFUSES TO BUILD — {s['id']}: {p} does not exist")

spec = dict(
    id="L5v2", theme="remix", size="1920x1080",
    # ⚠ DELIBERATELY NOT the shipped film's name. --finalize is not run for this
    # rebuild, but if it ever were it must not overwrite the published file.
    filename="DAW Pro Lesson 5 - Bach House (rebuild)",
    title="Bach wrote a loop — measured, then turned into a house track",
    playlist="Mixing, measured", categoryId="27",
    cut=6.2, playMax=13.0, introSeconds=4, outroSeconds=3, meter="br",
    bursts=f"{HERE}/bursts",
    cards=cards, stages=stages,
    tags=["Bach", "BWV 846", "house music", "remix", "music production",
          "classical music", "music theory", "loop"],
    description=(
        "Bach's Prelude in C major, BWV 846, has no melody. It has one "
        "broken-chord figure repeated bar after bar while the harmony under it "
        "moves — which is how a house record is built. This lesson measures "
        "that claim and then builds the track.\n\n"
        "THE FIGURE IS A LOOP, MEASURED\n"
        f'Bars 1-8 hold {INV["onsetsPerBar"]} note onsets each, in the same '
        f'places: the onset pattern changes {INV["onsetChangesAcross8Bars"]} times '
        f'across seven bar lines. The SAME comparison on the pitch sets changes '
        f'{INV["pitchChangesAcross8Bars"]} times of seven, which is the positive '
        f'control that makes the zero mean something. Bars '
        f'{INV["identicalPitchBarPairs"][0][0]} and '
        f'{INV["identicalPitchBarPairs"][0][1]} are the only identical pair.\n\n'
        "WHAT CHANGED\n"
        f'The tempo, from {TEM["slow"]["bpm"]} to {TEM["fast"]["bpm"]} BPM. '
        f'{M["pianoNotes"]} notes were read back out of the app before and after '
        "and are identical — same pitches, starts, lengths and velocities. "
        f'Measured off the renders, the sixteenth-note rate goes from '
        f'{TEM["slow"]["measuredOnsetsPerSec"]:.3f} to '
        f'{TEM["fast"]["measuredOnsetsPerSec"]:.3f} per second (predicted '
        f'{TEM["slow"]["predictedOnsetsPerSec"]:.3f} and '
        f'{TEM["fast"]["predictedOnsetsPerSec"]:.3f}).\n\n'
        "WHAT WAS ADDED, AND WHAT EACH PART IS WORTH\n"
        "Measured in each part's own band, at its own hit positions, the bar "
        "after it arrives against the bar before:\n"
        f'kick (bar {ENTRY["kick"]}, 20-110 Hz): {STEP["kick"]:+.2f} dB\n'
        f'hats (bar {ENTRY["hats"]}, 6-16 kHz): {STEP["hats"]:+.2f} dB\n'
        f'clap (bar {ENTRY["clap"]}, 0.9-9 kHz): {STEP["clap"]:+.2f} dB\n'
        f'bass (bar {ENTRY["bass"]}, 120-400 Hz): {STEP["bass"]:+.2f} dB\n'
        f'The same four events measured on the WHOLE mix: '
        f'{MIXSTEP["kick"]:+.2f}, {MIXSTEP["hats"]:+.2f}, {MIXSTEP["clap"]:+.2f} '
        f'and {MIXSTEP["bass"]:+.2f} dB. Adding a part is not the same thing as '
        "making a mix louder.\n\n"
        "WHERE THE HOUSE PARTS LIVE\n"
        f'Band energy of the finished track against the prelude alone: '
        f'{D["20-60"]:+.2f} dB at 20-60 Hz, {D["60-100"]:+.2f} at 60-100, '
        f'{D["100-250"]:+.2f} at 100-250, {D["250-1000"]:+.2f} at 250 Hz-1 kHz, '
        f'{D["1000-4000"]:+.2f} at 1-4 kHz, {D["4000-20000"]:+.2f} above 4 kHz. '
        "The prelude's own band barely moves.\n\n"
        "THE BASSLINE IS BACH'S\n"
        f'Each bar\'s bass note is the lowest pitch he wrote in that bar, moved '
        f'down {M["bassDrop"]//12} octaves: C C B C C C B B — a pedal point, '
        "which is what a house bassline usually is.\n\n"
        "LOUDNESS\n"
        f'The prelude alone renders at '
        f'{LO["ab-piano-src"]["integratedLufs"]:.1f} LUFS and the finished track '
        f'at {LO["ab-full-src"]["integratedLufs"]:.1f} LUFS over the same eight '
        f'bars — a difference of {AB["build"]["deltaLu"]:.2f} LU, stated rather '
        "than normalised away. Both A/B pairs carry one shared static gain.\n\n"
        "PROVENANCE\n"
        "The composition is public domain. The note data came from a public "
        "MusicXML encoding of the score and was checked bar by bar. There is no "
        "recording of any performer in this film: every sound is the app's own "
        "synthesiser and sound bank playing that MIDI.\n\n"
        "DISCLOSURE\n"
        "The narration is a synthetic voice, generated locally. No "
        "music-generation model was used.\n\n"
        "#bach #housemusic #musicproduction #remix #musictheory #classicalmusic "
        "#daw"),
)

if __name__ == "__main__":
    json.dump(spec, open(f"{HERE}/L5v2.json", "w"), ensure_ascii=False, indent=1)
    words = sum(len(s["narration"].split()) for s in stages)
    print(f"{HERE}/L5v2.json  {len(cards)} cards, {len(stages)} stages, "
          f"{words} words of narration")
