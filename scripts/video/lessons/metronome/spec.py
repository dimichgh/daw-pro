#!/usr/bin/env python3
"""Emit the rebuilt metronome lesson's spec for shortsmith.py.

⭐ THE SUBJECT IS DISPUTED AND THIS FILM ENDORSES NOTHING. Three explanations for
Beethoven's fast metronome marks have real evidence and named advocates, and
none is settled. The film's job is not to pick one — it is to MEASURE what the
marks actually sound like, which every side of the argument agrees about, and
let the viewer hear the thing being argued over.

⚠ EVERY HISTORICAL NUMBER TRACES TO docs/research/video-facts-history.md §2, and
  FACTS below is the single place each is written. Anything not in that document
  is not stated: no composition date, no Maelzel patent date, no time signature,
  no notch spacing on the metronome's scale.

⚠ SCHULLER'S ~92 AND THE STOKOWSKI ~40 ARE IN THE FACT SHEET AND ARE CUT. 92 is
  the mean of sixty-six recordings of the Fifth's FINALE; 108 is the FIRST
  MOVEMENT's mark. The shipped 182 s film paired them, which compares two
  different things, and the fact sheet flags that line as a secondary citation
  to verify before use.

⚠ NUMBERS ARE SPELLED OUT IN THE NARRATION. The speech model reads digits
  unreliably and the content gate compares a TRANSCRIPT against the script; the
  spoken forms are therefore typed by hand, and `check()` asserts every one of
  them against MEASUREMENTS.json at build time. A narration that drifted from a
  measurement refuses to build. Every numeric factCheck carries its digit
  spelling too, because Whisper writes spelled-out numbers BACK as digits.
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
S, A = f"{HERE}/shots", f"{HERE}/audio"

P = M["prediction"]
C = M["clicks"]
PC = M["probeControl"]
D = M["drift"]
U = M["unit"]
AB = M["ab"]
BC = M["bothClicks"]
SE = M["stringEnvelope"]
AUD = M["audibility"]
CT = M["_chart"]

# ── the historical record, ONE HOME EACH ────────────────────────────────────
# Every entry is a line of docs/research/video-facts-history.md §2 with its
# confidence tag. Nothing here is measurable in a DAW; it is quoted, and the
# film says whose claim it is every time.
FACTS = dict(
    marks=135,            # [EXACT] Beethoven's metronome markings
    disputed=66,          # [EXACT] regarded as absurdly fast
    fifthHalf=108,        # [EXACT] Symphony No. 5, first movement
    eroicaHalf=76,        # [EXACT] Symphony No. 3 "Eroica", finale
    plosYear=2020,        # [MEASURED] Martin-Castro & Ucar, PLOS ONE
    plosRecordings=36,    # 36 complete symphonic recordings, 36 conductors
    plosSymphonies=9,     # the Ninth excluded
    plosHours=169,        # hours of music measured; SPOKEN but was in no
                          # FACTS entry and under no check until reviewed
    plosShortfall=12,     # ~12-13 bpm slower on average
    plosExplained=44,     # of 63 markings
    plosOf=63,
    forsenYear=2013,      # [DISPUTED] Forsen et al., damaged double pendulum
    ninthMark=84,         # [DISPUTED] dotted-quarter vs dotted-half = 84
    ninthFactor=3,
)


def check(spoken, measured, tol, what):
    """Refuse to build if a spoken number has drifted from the measured one."""
    if abs(spoken - measured) > tol:
        sys.exit(f"SPEC REFUSES TO BUILD — {what}: the narration says {spoken} "
                 f"but the measurement says {measured:.4f}")


# ── every figure the voice says, checked against the file it came from ──────
check(108, FACTS["fifthHalf"], 0, "the Fifth's mark")
check(108, CT["markHalf"], 0, "the mark, as the charts print it")
check(216, P["markQuarterBpm"], 0, "the app's tempo field")
check(135, FACTS["marks"], 0, "how many marks Beethoven left")
check(66, FACTS["disputed"], 0, "how many are called too fast")
check(555.6, C["mark216"]["meanIoiMs"], 0.05, "the measured tick interval")
check(555.6, C["mark216"]["predictedIoiMs"], 0.05, "the predicted tick interval")
check(0.0208, C["mark216"]["spreadMs"], 0.0001, "the spread across the ticks")
check(5.42, PC["jitterAudioMaxAbsMs"], 0.01, "the jitter the probe found in the audio")
check(5.42, PC["jitterProjectMaxAbsMs"], 0.01, "the jitter the project holds")
check(14, PC["syntheticSwingMs"], 0.05, "the synthetic control's swing")
check(9.7, SE["rangeDb"], 0.05, "how much a held string chord moves")
check(76, SE["localMaximaPerSecond"], 0.5, "how often it turns around")
check(12, FACTS["plosShortfall"], 0, "the study's average shortfall")
check(2020, FACTS["plosYear"], 0, "the study's year")
check(36, FACTS["plosRecordings"], 0, "how many recordings the study used")
# ⚠ `check(169, FACTS["plosHours"])` WOULD BE A LITERAL AGAINST A LITERAL --
#   unfalsifiable, and exactly the shape ("C[...] + 1") that shipped as coverage
#   on a previous lesson. plosHours is spelled out IN WORDS in the narration and
#   interpolated nowhere, so the only check with any force is one that reads the
#   words back. spoken_int() does that, and it fails if EITHER side moves.
_UNITS = {"zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
          "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
          "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
          "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
          "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
          "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90}


def spoken_int(words):
    """'a hundred and sixty nine' -> 169. Raises on anything it cannot read,
    so a silent mis-parse cannot masquerade as agreement."""
    total = 0
    for w in words.replace("-", " ").split():
        if w in ("and", "a"):
            continue
        if w == "hundred":
            total = (total or 1) * 100
        elif w in _UNITS:
            total += _UNITS[w]
        else:
            raise SystemExit(f"SPEC REFUSES TO BUILD: cannot read the spoken "
                             f"number {words!r} -- unknown word {w!r}")
    return total


def check_spoken(words, expect, why):
    got = spoken_int(words)
    if got != expect:
        raise SystemExit(f"SPEC REFUSES TO BUILD: {why} -- the voice says "
                         f"{words!r} = {got}, the fact sheet says {expect}")


check_spoken("a hundred and sixty nine", FACTS["plosHours"],
             "how many hours of music the study measured")


def check_says(stage_id, words, why):
    """⚠ AND the words have to be IN the stage. Asserting a spelling in the
    abstract proves nothing about the film; this ties it to the narration."""
    st = next((x for x in stages if x["id"] == stage_id), None)
    if st is None:
        raise SystemExit(f"SPEC REFUSES TO BUILD: no stage {stage_id!r}")
    if words.lower() not in st["narration"].lower():
        raise SystemExit(f"SPEC REFUSES TO BUILD: {why} -- {stage_id} does not "
                         f"say {words!r}")
check(44, FACTS["plosExplained"], 0, "how many marks the reading error explains")
check(63, FACTS["plosOf"], 0, "out of how many")
check(96, CT["driftHalf"], 0, "the performed tempo")
check(192, P["driftQuarterBpm"], 0, "the performed tempo in quarter notes")
check(69.4, D["perStatementMeasuredMs"] / 4, 0.05, "the drift per tick")
check(69.4, CT["perTickMs"], 0.05, "the drift per tick, as the chart prints it")
check(278, D["perStatementMeasuredMs"], 0.3, "the drift per statement")
check(833, D["afterFourStatementsMs"], 0.5, "the drift after four statements")
check(30, AUD["fusionThresholdMs"], 0, "the fusion threshold")
check(32, BC["distinctOnsetsHeard"], 0, "how many ticks you hear in the pair")
check(18, BC["ticksInMarkAlone"], 0, "how many one metronome alone has")
check(9, BC["coincidenceTicks"][0], 0, "the coincidence, faster grid")
check(8, BC["coincidenceTicks"][1], 0, "the coincidence, slower grid")
check(5, BC["coincidencePeriodSec"], 0.001, "when they land together again")
check(2013, FACTS["forsenYear"], 0, "the damaged-metronome paper's year")
check(76, FACTS["eroicaHalf"], 0, "the Eroica's mark")
check(152, P["eroicaQuarterBpm"], 0, "the Eroica in quarter notes")
check(789.5, C["eroica152"]["meanIoiMs"], 0.05, "the Eroica's tick")
check(2, U["measuredRatio"], 0.001, "the note-value ratio")
check(2.22, U["markStatementSec"], 0.005, "the statement at the mark")
check(4.44, U["unitStatementSec"], 0.005, "the statement read as quarter notes")
check(84, FACTS["ninthMark"], 0, "the Ninth's number")
check(3, FACTS["ninthFactor"], 0, "how far apart the Ninth's two readings are")
check(8, M["counts"]["notesPerStatement"], 0, "the note count")

sp = str.upper

# ═══════════════════════════════════════════════════════════════════ cards
cards = [
  dict(type="statement", size=64, y=250,                                       # 0
       lines=["BEETHOVEN LEFT NUMBERS", "ON HIS OWN MUSIC.",
              "ALMOST NOBODY PLAYS THEM."],
       sub=["Nobody knows why, and this film does not pretend to.",
            "What it can do is measure what those numbers actually sound like."]),

  dict(type="list", title=sp("three words, in plain English"), step=92,        # 1
       items=[["tempo", "how fast the music goes — nothing else"],
              ["beats per minute", "how many beats fit into one minute", "hot"],
              ["a metronome mark", "a note value, an equals sign, and a number"]]),

  dict(type="list", title=sp("what a mark does NOT say"), step=88,             # 2
       items=[["it names a NOTE VALUE", "not just a speed — a half note, or a quarter"],
              ["a half note is two quarters", "so the same number can mean two tempos",
               "hot"],
              ["it cannot govern a hold", "a fermata has no written length"],
              ["it is one number", "for a passage a performer shapes constantly"]]),

  dict(type="bignumber", value=f"{FACTS['disputed']} of {FACTS['marks']}",      # 3
       label=sp("of Beethoven's metronome marks"),
       sub=["have long been called absurdly fast — and possibly wrong.",
            "Source: Forsén and colleagues, cited via Smithsonian Magazine."]),

  dict(type="statement", size=70, y=270,                                       # 4
       lines=[f"THE SCORE SAYS {FACTS['fifthHalf']}.",
              f"THE APP SAYS {P['markQuarterBpm']}.",
              "BOTH ARE RIGHT."],
       sub=["A half note is two quarter notes, and a DAW counts in quarter notes.",
            "That gap is where the whole argument lives."]),

  dict(type="list", title=sp("what is on screen"), step=88,                     # 5
       items=[[f"{M['counts']['notesPerStatement']} notes", "the opening of the Fifth, typed in by hand"],
              ["G, G, G, E flat", "the app spells E flat as D sharp — same key", "hot"],
              ["then a step down", "F, F, F, D — the same shape, lower"],
              ["a woodblock on every tick", "that is the metronome, inside the render"]]),

  dict(type="list", title=sp("the two long notes carry a fermata"), step=92,    # 6
       items=[["a fermata", "hold this note — for as long as you judge right"],
              ["no number governs it", "not the mark, not the tempo field", "hot"],
              ["so this demo is wrong on purpose", "played strictly, which nobody does"]]),

  dict(type="list", title=sp("the clock, before anything is timed with it"),    # 7
       step=88,
       items=[[f"{C['mark216']['meanIoiMs']:.4f} ms", "between ticks, measured off the render"],
              [f"{C['mark216']['predictedIoiMs']:.4f} ms", "what the arithmetic predicted"],
              [f"spread {C['mark216']['spreadMs']:.4f} ms", "one sample at forty-eight kilohertz",
               "hot"],
              [f"control {PC['jitterAudioMaxAbsMs']:.2f} ms",
               f"a deliberately mistimed render, project says {PC['jitterProjectMaxAbsMs']:.2f}"]]),

  dict(type="list", title=sp("the study that measured it"), step=86,           # 8
       items=[[f"{FACTS['plosRecordings']} recordings",
               f"{FACTS['plosSymphonies']} symphonies, {FACTS['plosRecordings']} conductors, "
               f"PLOS ONE {FACTS['plosYear']}"],
              [f"about {FACTS['plosShortfall']} beats slower",
               "than the marks, on average, across all of it", "hot"],
              [f"{FACTS['plosExplained']} of {FACTS['plosOf']}",
               "marks explained if the scale was misread"],
              ["the Ninth excluded", "the most contested mark is not in the sample"]]),

  dict(type="list", title=sp("explanation one: the machine"), step=86,         # 9
       items=[["a damaged metronome", f"modelled mathematically, Forsén and colleagues, "
                                      f"{FACTS['forsenYear']}"],
              ["his letters complain", "of an uneven pulse, and of repairs"],
              ["the metronome survives", "and its weight is missing, so it cannot be tested",
               "hot"],
              ["DISPUTED", "the largest study argues against it"]]),

  dict(type="list", title=sp("explanation two: the reading"), step=86,         # 10
       items=[["the weight has a marker", "and you can read the wrong side of it"],
              [f"it would explain {FACTS['plosExplained']} of {FACTS['plosOf']}",
               "which is what that study found", "hot"],
              ["a constant offset", "the same size of error on every mark"],
              ["one study", "well evidenced — and not a consensus"]]),

  dict(type="list", title=sp("explanation three: the note value"), step=86,    # 11
       items=[["the tick does not move", f"{FACTS['fifthHalf']} a minute either way"],
              ["the note on it does", "a half note, or a quarter note", "hot"],
              ["so the music halves", f"{U['markStatementSec']:.2f} seconds becomes "
                                      f"{U['unitStatementSec']:.2f}"],
              ["the Ninth's march", f"argued at a factor of {FACTS['ninthFactor']}, "
                                    f"not {FACTS['ninthFactor'] - 1}"]]),

  dict(type="list", title=sp("what this film settled"), step=88,               # 12
       items=[["nothing about Beethoven", "and it was never going to", "hot"],
              ["what the marks sound like", "measured, to one sample"],
              ["that the argument is real", "three mistakes, three different shapes"],
              ["and that it is unresolved", "which is a fine place for a lesson to end"]]),

  dict(type="closing", lines=["Every number measured in DAW Pro.",
                              "Nothing here settles it — and nothing should pretend to."]),
]

ARRANGE = f"{S}/app-arrange.png"
ROLL = f"{S}/app-roll-notes.png"
CLICKROLL = f"{S}/app-click-notes.png"
CH_CLICKS = f"{S}/chart-clicks.png"
CH_DRIFT = f"{S}/chart-drift.png"
CH_HYP = f"{S}/chart-hypotheses.png"
CH_STR = f"{S}/chart-strings.png"
DRIFT_MID = f"{S}/driftchart-mid.png"
DRIFT_FIN = f"{S}/driftchart-final.png"
UNIT_MID = f"{S}/unitchart-mid.png"
UNIT_FIN = f"{S}/unitchart-final.png"

# ⚠ ZOOMS ARE 16:9, DELIBERATELY. assemble.py LETTERBOXES a crop to fit, so a
#   wide thin crop of a small region photographs as a sliver floating in black —
#   correct content, unreadably small. That shipped on a previous lesson.
# ⚠⚠ A ZOOM IS IN FRACTIONS OF THE SOURCE (0-1), NOT PIXELS, AND THE FIRST
#   VERSION OF THIS FILE USED PIXELS. assemble.py multiplies them BY the source
#   dimensions, so [700, 1010, 1400, 790] asked ffmpeg for a crop 4,480,000 px
#   wide and the build died with "Invalid too big or non positive size" — which
#   at least fails LOUDLY. Every one of these was cropped with ffmpeg and LOOKED
#   AT before it went in.
# ⚠ AND THE ASPECT MATTERS: assemble.py LETTERBOXES a crop to fit 16:9, so a
#   wide thin crop of a small region photographs as a sliver floating in black.
#   The source is already 16:9, so w == h in FRACTION terms is a 16:9 crop.
# ⚠ THE FIRST CROP HERE WAS TWO-THIRDS EMPTY BLACK and only a pulled frame
#   could see it: the transport bar is the bottom ~8 % of the window, so a
#   0.28-tall crop anchored at 0.72 catches the bar in its bottom quarter
#   and dead space above. Tightened to 0.20 and dropped to 0.845, which is
#   the best trade measured against the 3200x1800 source -- 0.15 is a 5x
#   upscale, visibly soft, and clips TIME mid-digit.
ZTEMPO = {"path": ARRANGE, "zoom": [0.30, 0.845, 0.20, 0.20]}    # the tempo field
ZRULER = {"path": ARRANGE, "zoom": [0.175, 0.09, 0.33, 0.33]}    # 4/4, 216, the clips
ZNOTES = {"path": ROLL, "zoom": [0.03, 0.27, 0.32, 0.32]}        # the eight notes, named

# ═══════════════════════════════════════════════════════════════════ stages
stages = [
  dict(id="00-open", shots=[0, ARRANGE], cut=5.0, brandCheck="DAW Pro",
       factCheck=[["a hundred and eight", "108"], ["nobody knows"]],
       narration=(
         "If you have never used one, a metronome is a machine that clicks at a "
         "steady speed so a player can keep time. Beethoven got hold of one, and "
         "then he did something almost no composer before him had done: he went "
         "back through his symphonies and wrote a number on each movement saying "
         "exactly how fast it should go. Those numbers survive. And here is the "
         "strange part — most of them are faster than almost anybody plays. Not a "
         "little faster. Uncomfortably faster. People have been arguing about why "
         "for two hundred years, and nobody knows. There are three serious "
         "explanations, and I am going to tell you all three and pick none of "
         "them, because picking one would be making it up. What I can do is "
         "build those numbers in DAW Pro, measure them, and let you hear the "
         "thing everybody is arguing about. We start from the mark on the first "
         "movement of the Fifth Symphony: half note equals a hundred and eight.")),

  dict(id="01-words", shots=[1], cut=6.2,
       factCheck=[["beats per minute"], ["metronome mark"]],
       narration=(
         "Three words first, in case any of this is new, because the whole "
         "argument turns on them. Tempo is just how fast the music goes. Nothing "
         "clever, nothing to do with loud or soft or the notes themselves — only "
         "speed. Beats per minute is how we count tempo: how many beats fit into "
         "one minute. Sixty beats per minute is one beat a second, the tick of a "
         "clock. A hundred and twenty is twice that, and it is roughly where a "
         "lot of dance music sits. And a metronome mark is how a composer writes "
         "the tempo onto the page. It is not just a number. It is a little "
         "picture of a note, then an equals sign, then a number. And that "
         "picture of a note is the part that is about to cause all the trouble.")),

  dict(id="02-notsay", shots=[2], cut=6.2,
       factCheck=[["note value"], ["fermata"]],
       narration=(
         "Here is what a metronome mark actually says, and what it does not. It "
         "says: this many of THIS note, every minute. So the mark has to name a "
         "note value. Written music has a whole family of them — a whole note, a "
         "half note, a quarter note, an eighth note — and each one is half the "
         "length of the one before it. A half note is exactly two quarter notes "
         "long. So if a mark says a hundred and eight, everything depends on "
         "which note is sitting next to that number. A hundred and eight half "
         "notes a minute, and a hundred and eight quarter notes a minute, are "
         "two different tempos, and one is twice the other. Hold on to that. "
         "There are two more things a mark cannot do. It cannot tell you how "
         "long to hold a note that is marked to be held — that mark is called a "
         "fermata, and it has no written length at all. And it is one number for "
         "a passage that a performer will push and pull the whole way through.")),

  dict(id="03-scope", shots=[3], cut=6.0,
       factCheck=[["sixty six", "sixty-six", "66"], ["a hundred and thirty five", "135"]],
       narration=(
         "So how big is this problem. Beethoven left a hundred and thirty five "
         "metronome marks across his music. Of those, sixty six have been "
         "regarded by performers and scholars as absurdly fast, and therefore "
         "possibly wrong. That figure comes from a mathematical study of his "
         "metronome, and I will come back to that study later. Sixty six out of "
         "a hundred and thirty five is not a handful of outliers. It is nearly "
         "half of everything he marked. Whatever went wrong, if something did, "
         "went wrong a lot. And notice what that already rules out: it is not "
         "one careless afternoon. It is a pattern.")),

  dict(id="04-tempofield", shots=[4, ZTEMPO, ZRULER], cut=5.4, holdLast=True,
       factCheck=[["two hundred and sixteen", "216"], ["a hundred and eight", "108"]],
       narration=(
         "Let me show you the trouble on a real screen before anything else. The "
         "mark on the first movement of the Fifth Symphony is half note equals a "
         "hundred and eight. A hundred and eight half notes every minute. Now "
         "here is that same tempo in DAW Pro. The tempo field reads two hundred "
         "and sixteen. Not a hundred and eight — two hundred and sixteen. "
         "Nothing is wrong. A digital audio workstation counts in quarter notes, "
         "because that is what a beat means to a machine, and a half note is two "
         "quarter notes, so a hundred and eight half notes a minute is two "
         "hundred and sixteen quarter notes a minute. Same tempo. Two numbers. "
         "If a piece of software can print the same speed as two different "
         "numbers, so can a person with a pen, and that is not a hypothetical.")),

  dict(id="05-notes", shots=[5, ROLL, ZNOTES], cut=5.2, holdLast=True,
       loop=f"{A}/motif-mark-216.wav", burst="b-mark", playMax=9.5,
       factCheck=[["eight notes"], ["D sharp", "D-sharp", "D#"]],
       narration=(
         "This is the music. Eight notes, typed in by hand — I have not "
         "downloaded a file of anybody's performance and I have not sampled a "
         "recording. Three short notes on the same pitch, then a longer note "
         "lower down. Then the same shape one step further down. G, G, G, E "
         "flat. F, F, F, D. You are looking at a piano roll: time runs left to "
         "right, pitch runs up and down, and each blue block is one note. One "
         "thing that will confuse you if I do not say it — the app labels that "
         "fourth note D sharp, and the score writes it E flat. On a piano those "
         "are the same key. Software tends to pick one spelling and stick to it. "
         "Underneath the strings there is a woodblock hitting every half note. "
         "That woodblock is the metronome, and it is inside the render, not "
         "added afterwards, which is what makes it something I can measure.")),

  dict(id="06-fermata", shots=[6], cut=6.4,
       factCheck=[["fermata"], ["as written"]],
       narration=(
         "One honest thing before we go on. In the score, both of those long "
         "notes carry a fermata — that instruction to hold. It has no length. "
         "The composer is handing the decision to whoever is conducting. Which "
         "means that in the most famous eight notes in music, two of the eight "
         "are notes that Beethoven's own metronome mark does not govern at all. "
         "A DAW cannot express that, and neither can any number. So what you are "
         "about to hear plays them strictly as written, which is not how any "
         "orchestra on earth performs them. I am not going to quietly let that "
         "slide. It is not a flaw in the demonstration, it is part of the "
         "lesson: a tempo mark was never the whole instruction, and the argument "
         "about Beethoven's marks is partly an argument about how much of the "
         "instruction a number was ever supposed to carry.")),

  dict(id="07-calibrate", shots=[7, CH_CLICKS], cut=5.6, holdLast=True,
       # ⚠ NOT the raw render: it peaks at -13.65 dBFS and played 10 LU under
       #   the narration. demo-click is the same audio, normalised and lifted.
       loop=f"{A}/demo-click.wav", playMax=8.6, bedEligible=False,
       factCheck=[["five hundred and fifty five", "555"],
                  ["one sample"]],
       narration=(
         "Before I ask you to believe a single timing measurement in this video, "
         "here is the clock being checked. At a hundred and eight ticks a minute, "
         "the gap between two ticks should be five hundred and fifty five point "
         "five six milliseconds. That is just sixty thousand divided by a hundred "
         "and eight. I rendered the click, then found every tick in the audio and "
         "measured the gaps. Five hundred and fifty five point five six "
         "milliseconds. The widest and the narrowest gap in the whole render "
         "differ by one sample — one forty-eight-thousandth of a second. Now, a "
         "perfect answer is exactly what a broken measurement looks like, so "
         "there is a control. I took the same click, deliberately knocked every "
         "tick off the grid by a known amount, and pointed the same probe at it. "
         "It found five point four two milliseconds of error where the project "
         "says five point four two. The probe can see a mistake. That is why the "
         "clean numbers mean something.")),

  dict(id="08-strings", shots=[CH_STR], cut=6.0, holdLast=True,
       factCheck=[["nine point seven", "9.7"], ["metronome"]],
       narration=(
         "And here is something I did not expect, which changed how the rest of "
         "this was measured. My first attempt timed the string notes instead of "
         "the woodblock, and it gave an answer that looked completely fine and "
         "was nonsense. This is why. That is the level of one single held string "
         "chord, with nothing else playing, over half a second. It moves by more "
         "than nine point seven decibels and turns around about seventy six times "
         "a second. A string ensemble is many instruments very slightly out of "
         "tune with each other, which is exactly what makes it sound rich, and it "
         "means there is no single instant that is the start of the note. So an "
         "onset detector correctly finds dozens of rises in one note. The "
         "woodblock is one instant. It is in the same render at the same tempo. "
         "So everything after this is timed off the metronome, which is, after "
         "all, what a metronome is for.")),

  dict(id="09-mark", shots=[ARRANGE, ZRULER], cut=5.0, holdLast=True,
       loop=f"{A}/motif-mark-216.wav", burst="b-arrange", playMax=9.5,
       factCheck=[["a hundred and eight", "108"], ["as he marked it"]],
       narration=(
         "So this is the Fifth Symphony's opening at the speed Beethoven wrote on "
         "it — half note equals a hundred and eight, exactly as he marked it, with "
         "his metronome clicking underneath. Two things worth saying while you "
         "listen. This is a general MIDI string patch, not an orchestra, so do "
         "not judge the sound; judge the speed. And this is a repeat of the same "
         "eight notes over and over, which is my doing and not his — he develops "
         "the idea, I am just looping it, because a drift of a quarter of a "
         "second only becomes visible once it has piled up over several goes.")),

# ⚠ cut=14.5, NOT the default. The still timer is n = round(total/cut) with
#   each slot total/n, so cut=5.6 over a 43.5 s stage gave EIGHT slots and
#   card 8 -- the card that carries "36 recordings", "9 symphonies",
#   "PLOS ONE 2020" -- was gone at 5.4 s, three seconds BEFORE the first of
#   those numbers is spoken (8.4 s, 9.7 s, 11.8 s; slotcheck.py). At 14.5
#   it holds for 14.5 s and the drift chart takes the rest, which is where
#   "ninety six" (36.2 s) and "twelve beats" (41.9 s) actually belong.
  dict(id="10-plos", shots=[8, CH_DRIFT], cut=14.5, holdLast=True,
       factCheck=[["twelve beats", "12 beats"], ["ninety six", "96"],
                  ["two thousand and twenty", "2020"]],
       narration=(
         "Now, what do conductors actually do. The largest measurement anyone has "
         "made of this was published in two thousand and twenty, in the journal "
         "PLOS ONE, by Almudena Martín-Castro and Iñaki Ucar. Thirty six complete "
         "recordings of nine symphonies, thirty six different conductors, over a "
         "hundred and sixty nine hours of music, with the tempo pulled out "
         "automatically and checked by hand on samples. What they found is that "
         "performances come in about twelve to thirteen beats a minute under the "
         "marks, on average. Now I want to be precise about what I am about to "
         "do, because it is my arithmetic and not their finding. They measured an "
         "average shortfall across everything. I am taking twelve off this one "
         "mark, in the mark's own unit, to get something you can listen to. A "
         "hundred and eight becomes ninety six. That is not a claim about how any "
         "particular conductor plays the Fifth. It is a way of hearing what "
         "twelve beats a minute feels like.")),

  dict(id="11-ab-tempo", shots=[CH_DRIFT], cut=6.0, holdLast=True,
       loop=f"{A}/ab-tempo-b.wav", normalize=False,
       ab={"before": f"{A}/ab-tempo-a.wav", "beforeShots": [4], "afterShots": [8],
           "cycles": 2, "seconds": 10.0},
       factCheck=[["two hundred and seventy eight", "278"],
                  ["eight hundred and thirty three", "833"]],
       narration=(
         "Here are both, ten seconds each, twice round. First the mark, then the "
         "average performance. The two halves are not level-matched by the "
         "software — one gain was set for the pair, so any difference you hear is "
         "the tempo and not a volume trick. Measured off the renders: each go "
         "through those eight notes takes two hundred and seventy eight "
         "milliseconds longer at the slower tempo, and by the fourth time round "
         "the slower version is eight hundred and thirty three milliseconds "
         "behind. That is a real difference and you can hear it. It is also, and "
         "this is the honest bit, not a shocking one. Twelve beats a minute is a "
         "difference of character, not a difference of kind. Which is precisely "
         "why it is possible to argue for two centuries about whether it is a "
         "mistake or a choice.")),

  # ⚠ cut=19.2, NOT the default. Same defect as 10-plos, found the same way:
  #   DRIFT_MID is the still that CARRIES "they come apart by 69.4 ms every
  #   tick" and "two attacks stop sounding like one at about 30 ms", and the
  #   voice says those two numbers at 12.6 s and 17.2 s -- but at cut=6.5 the
  #   mid still was gone at 6.4 s and both were spoken over DRIFT_FIN, whose
  #   caption reads "32 separate ticks" instead. 19.2 gives two slots, so the
  #   still that names a number is on screen while the number is read.
  dict(id="12-marker", shots=[DRIFT_MID, DRIFT_FIN], cut=19.2, holdLast=True,
       loop=f"{A}/bed-drift.wav", burst="driftchart", playMax=13.0,
       bedEligible=False, normalize=False,
       factCheck=[["sixty nine", "sixty-nine", "69"], ["thirty milliseconds", "30 milliseconds"]],
       narration=(
         "Let me make that difference impossible to miss, by putting both "
         "metronomes in the same ten seconds. Watch the two rows of ticks, and "
         "watch the playhead sweeping across in real time. The top row is the "
         "mark, the bottom row is the performance average. They start together. "
         "Then they come apart by sixty nine point four milliseconds every "
         "single tick — and two attacks stop sounding like one event at around "
         "thirty milliseconds, so by the second tick you are hearing two clocks "
         "instead of one. There is one more thing in there, and it is the "
         "chart's own control. At exactly five seconds they land on the same "
         "instant again, because nine ticks of the fast one take precisely as "
         "long as eight of the slow one. That is arithmetic, not luck, and when "
         "I counted the separate ticks in that file the answer was thirty two, "
         "which is what those two coincidences predict. One metronome alone has "
         "eighteen.")),

  dict(id="13-hyp1", shots=[9], cut=6.2,
       factCheck=[["two thousand and thirteen", "2013"], ["the weight"]],
       narration=(
         "Right. Three explanations, and this is where I stop measuring and start "
         "reporting other people's work. Explanation one: the machine was broken. "
         "In two thousand and thirteen, Forsén and colleagues modelled "
         "Beethoven's kind of metronome mathematically — it is a pendulum with "
         "weights on both sides of its pivot, which is a fussier thing than it "
         "looks — and showed that a mechanically damaged one could produce "
         "readings consistent with unusually fast marks. It fits something real: "
         "Beethoven's own letters complain about the device's uneven pulse and "
         "record repeated repairs. His actual metronome was tracked down and "
         "still exists. And it cannot settle anything, because the weight is "
         "missing, so it cannot be tested. This one is marked disputed and it "
         "stays disputed.")),

  dict(id="14-eroica", shots=[9, CH_HYP], cut=5.6, holdLast=True,
       loop=f"{A}/ab-eroica-b.wav", normalize=False,
       ab={"before": f"{A}/ab-eroica-a.wav", "beforeShots": [4], "afterShots": [CH_HYP],
           "cycles": 2, "seconds": 8.6},
       factCheck=[["seventy six", "seventy-six", "76"], ["one fixed rate", "a fixed rate"]],
       narration=(
         "And there is an argument against the broken machine that you can "
         "actually listen to. The Eroica symphony's finale is marked half note "
         "equals seventy six. The Fifth's first movement is marked a hundred and "
         "eight. Both movements carry a fast tempo word. Here are those two marks "
         "as metronomes, one after the other. Seven hundred and eighty nine point "
         "five milliseconds between ticks against five hundred and fifty five "
         "point five six — they are plainly not the same speed. A machine stuck "
         "at one fixed rate could not produce both of those. Whatever was going "
         "on, the marks vary movement by movement, which is what you would expect "
         "if a person was doing something, and not what you would expect if a "
         "spring was.")),

  dict(id="15-hyp2", shots=[10], cut=6.2,
       factCheck=[["forty four", "forty-four", "44"], ["consistent offset"]],
       narration=(
         "Explanation two, and this is the one with the most evidence behind it. On the "
         "metronomes of that era, the thing you slide up and down the scale is a "
         "weight with a marker on it, and there is a well documented way to read "
         "it wrong: you read the scale against the wrong side of the marker. The "
         "same study I quoted earlier found that forty four of sixty three marks "
         "could be explained if Beethoven, or somebody helping him, made exactly "
         "that error. And the shape of the evidence is what makes it persuasive. "
         "They found a consistent offset — roughly the same size of discrepancy "
         "on mark after mark — and a consistent offset is what a reading error "
         "looks like. A physical fault would be more likely to scale with the "
         "setting. The paper explicitly rejects the broken metronome as the main "
         "cause on those grounds. It is one study. It is not a consensus. But it "
         "is the most data anybody has brought to this.")),

  dict(id="16-hyp3", shots=[11, UNIT_MID, UNIT_FIN], cut=6.5, holdLast=True,
       loop=f"{A}/bed-unit.wav", burst="unitchart", playMax=14.0,
       bedEligible=False, normalize=False,
       factCheck=[["note value"], ["has not moved", "did not move"]],
       narration=(
         "Explanation three, and this is the one you can check with your own ears "
         "right now. Remember that a mark has to name a note value. What if some "
         "of them were read against the wrong one. Listen to this. You are going "
         "to hear a metronome set to a hundred and eight, and then a metronome "
         "set to a hundred and eight. Those are the same sound, because they are "
         "the same setting — a tick every five hundred and fifty five and a half "
         "milliseconds, either way. The metronome has not moved. But on the first "
         "one I am putting a half note on each tick, and on the second one a "
         "quarter note, and since a half note is two quarter notes, the music "
         "underneath the second reading runs at half the speed. Nothing about the "
         "machine changed. Only what somebody wrote next to the number.")),

  dict(id="17-ab-unit", shots=[UNIT_FIN, ROLL], cut=5.6, holdLast=True,
       loop=f"{A}/ab-unit-b.wav", normalize=False,
       ab={"before": f"{A}/ab-unit-a.wav", "beforeShots": [4], "afterShots": [11],
           "cycles": 2, "seconds": 8.888888888888889},
       factCheck=[["twice", "two times"], ["same number"]],
       narration=(
         "Now the same thing with the music. Both of these are the same eight "
         "seconds of clock time, and both are the same number on the metronome. "
         "The first is read as half notes, and the second is read as quarter notes. "
         "Measured off the two renders, one time through takes two point two two "
         "seconds in the first and four point four four in the second — a ratio "
         "of two, to five decimal places. So in the same window you get twice as "
         "much Beethoven out of one reading as the other, and that is not "
         "interpretation, or taste, or a difference of twelve beats. It is a "
         "factor of two, from the same number, and it is the largest thing any of "
         "the three explanations can do.")),

  dict(id="18-ninth", shots=[11, CH_HYP], cut=5.8, holdLast=True,
       factCheck=[["eighty four", "eighty-four", "84"], ["three times"]],
       narration=(
         "And this is not a thought experiment. The single most argued-over mark "
         "in Beethoven is the march in the finale of the Ninth Symphony. It is "
         "recorded, through his nephew, as eighty four. But the note value was "
         "not written down by the person who took the note — it was added later. "
         "Read one way the march crawls. Hermann Beck argued in the nineteen "
         "fifties for the other reading, which is three times faster, and that is "
         "now widely but not universally accepted. Three times. From the same "
         "number eighty four, with nothing changed except which note somebody "
         "drew beside it. And I want to be careful here, because this is the "
         "explanation with the tidiest story, and the tidiest story is the one to "
         "be most suspicious of. It is still marked disputed in the literature. "
         "It is not the answer. It is a third possibility that happens to be "
         "beautifully demonstrable.")),

  dict(id="19-settle", shots=[12, CH_HYP], cut=6.0, holdLast=True,
       factCheck=[["three", "3"], ["sixty three", "sixty-three", "63"]],
       narration=(
         "So put the three side by side, because they are three different SHAPES "
         "of mistake and that is the useful way to hold them. A broken machine "
         "would give you an error that depends on the mechanism. A misread scale "
         "gives you a constant offset — the same twelve beats off, everywhere. A "
         "wrong note value gives you a clean factor of two, or of three. Here is "
         "what each of those does to the two marks I have quoted in this video. "
         "And here is the honest limit of this chart, stated on it: two marks "
         "cannot choose between three explanations. The study that argues for a "
         "constant offset used sixty three. This is arithmetic on the three "
         "claims, not a measurement of Beethoven, and I would rather show you "
         "that plainly than draw a curve through two points and let it look like "
         "evidence.")),

  dict(id="20-close", shots=[13, ARRANGE], cut=5.2, brandCheck="DAW Pro",
       factCheck=[["nobody knows"], ["a hundred and eight", "108"]],
       narration=(
         "So where does that leave it. Nobody knows why Beethoven's metronome "
         "marks read too fast. A damaged machine, a misread scale, a wrong note "
         "value — all three have real evidence and named people defending them, "
         "and the best study anybody has done leans one way while excluding the "
         "symphony with the most contested mark in it. What is not in doubt is "
         "the sound. Half note equals a hundred and eight is a real speed, you "
         "have heard it, and you have heard what twelve beats a minute under it "
         "does, and what happens when the note value changes instead. Every "
         "number in this video came off a render made in DAW Pro, the clock was "
         "checked against a control before anything was timed with it, and the "
         "one thing I have deliberately not done is tell you which explanation is "
         "right. If a video about measurement quietly picked a winner because it "
         "made a tidier ending, it would be doing the exact thing it is warning "
         "you about.")),
]

# ── the spoken numbers that appear NOWHERE ELSE, tied to the stage that says
#    them. These run AFTER `stages` exists, which is why they are not up with
#    the other checks.
check_says("10-plos", "a hundred and sixty nine hours",
           "the study's hours are spoken but interpolated nowhere")
check_says("10-plos", "thirty six complete recordings",
           "the study's recording count")

spec = dict(
    id="L7v2", theme="history", size="1920x1080",
    # ⚠ DELIBERATELY NOT the shipped film's name. --finalize is not run for this
    # rebuild, but if it ever is, it must not overwrite the published file
    # before the user has watched this one.
    filename="DAW Pro Lesson 7 - Beethovens Metronome (rebuild)",
    title="Beethoven's metronome marks are too fast. Nobody knows why.",
    playlist="Mixing, measured", categoryId="27",
    cut=5.4, playMax=9.5, introSeconds=4, outroSeconds=3, meter="br",
    bursts=f"{HERE}/bursts",
    cards=cards, stages=stages,
    tags=["Beethoven", "metronome", "tempo", "music history", "Symphony No. 5",
          "music theory", "BPM", "classical music", "music production"],
    description=(
        "Beethoven wrote metronome marks on his own symphonies, and almost nobody "
        "plays them. Nobody knows why. This film presents all three explanations "
        "and endorses none of them — what it does instead is measure what the "
        "marks actually sound like.\n\n"
        "THE SUBJECT IS DISPUTED\n"
        f'Of Beethoven\'s {FACTS["marks"]} metronome marks, {FACTS["disputed"]} have '
        "long been regarded as absurdly fast. Three explanations compete: a damaged "
        f'metronome (Forsén and colleagues, {FACTS["forsenYear"]}, DISPUTED — his own '
        "metronome survives but is missing its weight, so it cannot be tested), a "
        f'misread scale (Martín-Castro and Ucar, PLOS ONE {FACTS["plosYear"]} — '
        f'{FACTS["plosRecordings"]} recordings, {FACTS["plosSymphonies"]} symphonies, '
        f'a consistent ~{FACTS["plosShortfall"]} bpm shortfall, '
        f'{FACTS["plosExplained"]} of {FACTS["plosOf"]} marks explained), and a '
        "notational-unit confusion (the Ninth's march, argued at a factor of "
        f'{FACTS["ninthFactor"]}, still disputed). None of them is the answer and '
        "this film does not pick one.\n\n"
        "MEASURED HERE\n"
        f'The clock first: a metronome at half note = {FACTS["fifthHalf"]} should tick '
        f'every {C["mark216"]["predictedIoiMs"]:.4f} ms and measured '
        f'{C["mark216"]["meanIoiMs"]:.4f} ms, with a spread across the whole render of '
        f'{C["mark216"]["spreadMs"]:.4f} ms — ONE SAMPLE at 48 kHz. Positive control: '
        "the same probe on a deliberately mistimed render read "
        f'{PC["jitterAudioMaxAbsMs"]:.4f} ms against the project\'s '
        f'{PC["jitterProjectMaxAbsMs"]:.4f} ms, and on a synthetic train with a known '
        f'14 ms swing recovered {PC["syntheticSwingMs"]:.2f} ms.\n'
        f'The drift: taking the {FACTS["plosShortfall"]} bpm shortfall off this mark '
        f'gives half note = {CT["driftHalf"]}. Predicted drift per statement '
        f'{D["perStatementPredictedMs"]:.3f} ms, measured '
        f'{D["perStatementMeasuredMs"]:.3f} ms; after four statements '
        f'{D["afterFourStatementsMs"]:.0f} ms. The two metronomes summed into one file '
        f'give {BC["distinctOnsetsHeard"]} separate ticks in ten seconds where one '
        f'alone has {BC["ticksInMarkAlone"]} — and they land together again at '
        f'{BC["coincidencePeriodSec"]:.0f}.000 s, {BC["coincidenceTicks"][0]} ticks '
        f'against {BC["coincidenceTicks"][1]}, which is the count\'s own control.\n'
        f'The note value: the same setting read as half notes and as quarter notes '
        f'gives an identical tick and a music ratio measured at '
        f'{U["measuredRatio"]:.5f} — {U["markStatementSec"]:.2f} s becomes '
        f'{U["unitStatementSec"]:.2f} s.\n\n'
        "WHAT WAS FOUND BY MEASURING\n"
        "The timing is read off the METRONOME, not off the strings, and that was "
        "forced rather than chosen: one held General MIDI string chord's level moves "
        f'{SE["rangeDb"]:.1f} dB and turns around {SE["localMaximaPerSecond"]:.0f} '
        "times a second, so there is no single instant that is the onset of a string "
        "chord and an onset detector correctly finds dozens of rises in one note.\n\n"
        "HONESTLY\n"
        "The eight notes are Beethoven's and are public domain; they were typed in by "
        "hand, and no recording of any orchestra was read or analysed. The repetition "
        "is mine. Both long notes carry a fermata, which no metronome mark governs, "
        "and they are played strictly as written here, which nobody does — the film "
        "says so. Taking 12 bpm off a single mark is MY arithmetic applied to a study's "
        "average, not that study's finding about this movement.\n\n"
        "DISCLOSURE\n"
        "The narration is a synthetic voice, generated locally. No music-generation "
        "model was used; every note was programmed by hand.\n\n"
        "#beethoven #metronome #tempo #musichistory #musictheory #musicproduction"),
)

if __name__ == "__main__":
    json.dump(spec, open(f"{HERE}/L7v2.json", "w"), ensure_ascii=False, indent=1)
    words = sum(len(s["narration"].split()) for s in stages)
    print(f"{HERE}/L7v2.json  {len(cards)} cards, {len(stages)} stages, "
          f"{words} words of narration")
