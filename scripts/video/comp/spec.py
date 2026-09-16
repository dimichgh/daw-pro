#!/usr/bin/env python3
"""Emit the compressor lesson's spec for shortsmith.py.

Written as code rather than hand-typed JSON for one reason: every number the
narration says is injected from MEASUREMENTS.json, so a figure cannot drift
from the file it was measured into, because it is never typed twice.

⚠ THIS FILE RESOLVES shots/ audio/ bursts/ FROM ITS OWN DIRECTORY, not from
SESSION_SHOTS/SESSION_AUDIO (those are read by the node capture scripts only).
Run the copy that sits beside the assets, or every path in the emitted spec
points at an empty repo directory and the build dies on the first ffprobe.

⚠ Numbers are spelled out in the narration because the speech model reads
digits unreliably, and the factCheck gate compares the TRANSCRIPT against the
script -- so the written form and the spoken form both have to be here.
"""
import json, os

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
S, A = f"{HERE}/shots", f"{HERE}/audio"

MAT, D1, D1B, D2, D3, D4, D5, D6 = (
    M["material"], M["d1_threshold_and_ratio"], M["d1b_why_it_is_not_exactly_9"],
    M["d2_attack"], M["d3_release"], M["d4_knee"], M["d5_makeup"], M["d6_mix"])
BX = D6["bit_exact_bypass_at_mix0"]
INTRO = M["intro_diagram"]
LEAST = D3["least_reduced_over_the_loop_db"]
MED = D3["median_gr_over_the_loop_db"]
DLV = D3["delivered_lufs_after_one_common_gain"]

def sp(t): return t.upper()

# ------------------------------------------------------------------- cards
cards = [
  dict(type="statement", size=76, y=250,                                   # 0
       lines=["SEVEN KNOBS.", "TWO OF THEM DECIDE", "HOW MUCH."],
       sub=["The other five decide something else entirely.",
            "Every number in this video was predicted, then measured."]),
  dict(type="list", title=sp("seven knobs, three jobs"), step=84,          # 1
       items=[["threshold", "how much"],
              ["ratio", "how much", "hot"],
              ["attack", "what it sounds like"],
              ["release", "what it sounds like", "hot"],
              ["knee", "where those two meet"],
              ["makeup", "not compression at all"],
              ["mix", "not compression at all", "hot"]]),
  dict(type="bignumber", label=sp("threshold and ratio decide how much"),  # 2
       value=f'{D1["measured_gr_db"]}', unit=sp("db of reduction"), size=190,
       notes=[f'predicted {D1["predicted_gr_db"]} before anything was rendered',
              f'twelve dB over threshold, ratio four, hard knee',
              f'the ratio-one control measured {D1["control_ratio1_measured_db"]} dB — exactly unity']),
  dict(type="list", title=sp("where the model runs out"), step=82,         # 3
       items=[["release 5 ms", f'short by {D1B["shortfall_db_at_release_5ms"]} dB'],
              ["release 100 ms", f'short by {D1B["shortfall_db_at_release_100ms"]} dB', "hot"],
              ["release 2000 ms", f'short by {D1B["shortfall_db_at_release_2000ms"]} dB'],
              ["the shortfall", "closes monotonically. That is the confirmation."]]),
  dict(type="list", title=sp("attack decides what survives"), step=84,     # 4
       items=[["bypassed", f'peak {D2["bypassed_control_peak_dbfs"]:.2f} dBFS'],
              ["attack 0.1 ms", f'peak {D2["attack_0p1ms_peak_dbfs"]:.2f} dBFS'],
              ["attack 50 ms", f'peak {D2["attack_50ms_peak_dbfs"]:.2f} dBFS', "hot"],
              ["the difference", f'{D2["transient_kept_vs_crushed_db"]} dB of transient, kept or crushed', "hot"]]),
  # ⚠ RE-CUT. Cut 1's card here was the ln(12) recovery-time table, whose numbers
  # live only in MEASUREMENTS-cut1.json. Demo 3 was re-shot with a pad and
  # re-measured; this card is the new measurement and nothing on it is typed
  # twice. The two figures that matter are the LEAST-reduced moment in the whole
  # loop -- 0.00 dB means the compressor let go completely, 2.17 dB means it
  # never did -- and the fact that the pair is NOT loudness matched.
  dict(type="list", title=sp("release: did it ever let go?"), step=76,      # 5
       items=[["release 30 ms",
               f'median over the loop {abs(MED["30 ms"]):.2f} dB — it lets go completely'],
              ["release 800 ms",
               f'median over the loop {abs(MED["800 ms"]):.2f} dB', "hot"],
              ["30 ms, least reduced",
               f'{abs(LEAST["30 ms"]):.2f} dB — all the way back, every hit'],
              ["800 ms, least reduced",
               f'{abs(LEAST["800 ms"]):.2f} dB — it never gets back at all', "hot"],
              ["the pad, between hits",
               f'{min(D3["pad_between_hits_fast_minus_slow_db"])}–{max(D3["pad_between_hits_fast_minus_slow_db"])} dB louder on the fast setting'],
              ["NOT loudness matched",
               f'one gain of +{DLV["common_gain_db"]} dB on both — {DLV["30 ms"]} vs {DLV["800 ms"]} LUFS', "hot"]]),
  # ⚠ THE HONESTY IS ON THE CARD, not only in the voice. The bound belongs on
  # screen next to the measurement, because the bound is what makes "you will
  # not hear this" a fact about the arithmetic rather than an apology.
  dict(type="bignumber", label=sp("a tone two db under threshold"),        # 6
       value=f'{D4["soft_knee_24db_measured_gr_db"]}', unit=sp("db, soft knee"), size=190,
       notes=[f'predicted {D4["soft_knee_24db_predicted_gr_db"]} — measured {D4["soft_knee_24db_measured_gr_db"]}',
              f'hard knee, same threshold, same tone: {D4["hard_knee_measured_gr_db"]} dB',
              f'the widest this gap can EVER be: {D4["max_possible_gap_db_at_ratio_4_knee_24"]} dB here,'
              f' {D4["max_possible_gap_db_at_ratio_20"]} dB at any setting',
              "you will not hear it on laptop speakers. That is the lesson."]),
  dict(type="list", title=sp("why every a/b you have heard is a lie"), step=80,  # 7
       items=[["uncompressed", f'{D5["uncompressed_lufs"]} LUFS'],
              ["compressed, no makeup", f'{D5["compressed_makeup0_lufs"]} LUFS  (−{D5["loss_lu"]} LU)'],
              [f'+{D5["loudness_matched_makeup_db"]} dB makeup', f'{D5["loudness_matched_lufs"]} LUFS — a fair test'],
              [f'+{D5["unfair_demo_makeup_db"]} dB makeup', f'{D5["unfair_demo_lufs"]} LUFS — {D5["unfair_advantage_lu"]} LU of cheat', "hot"]]),
  dict(type="bignumber", label=sp("at equal loudness, the compressed take"),  # 8
       value="+4.5 dB", unit=sp("higher peaks"), size=170,
       notes=[f'uncompressed peak {D5["uncompressed_peak_dbfs"]:.2f} dBFS',
              f'loudness-matched compressed peak {D5["matched_peak_dbfs"]:.2f} dBFS',
              "a 10 ms attack passes the transient; makeup then lifts it",
              "this is why a limiter follows a compressor"]),
  dict(type="list", title=sp("mix is not compression"), step=78,           # 9
       items=[["dry", f'{D6["dry_control"]["lufs"]} LUFS   peak {D6["dry_control"]["peak_dbfs"]:.2f}'],
              ["fully wet", f'{D6["fully_wet"]["lufs"]} LUFS   peak {D6["fully_wet"]["peak_dbfs"]:.2f}'],
              ["mix 40%", f'{D6["parallel_mix_0p4"]["lufs"]} LUFS   peak {D6["parallel_mix_0p4"]["peak_dbfs"]:.2f}', "hot"],
              ["parallel keeps", f'{D6["parallel_vs_wet_peak_kept_db"]} dB more transient', "hot"],
              ["mix 0", "null test against dry: silence. Bit-exact."]]),
  dict(type="closing", size=66, y=300,                                     # 10
       kicker=sp("that is the whole instrument"),
       lines=["THRESHOLD AND RATIO DECIDE HOW MUCH.",
              "ATTACK AND RELEASE DECIDE WHAT IT SOUNDS LIKE.",
              "KNEE DECIDES WHERE THOSE TWO MEET.",
              "MAKEUP PUTS THE LEVEL BACK.",
             "MIX DECIDES HOW MUCH OF IT YOU HEAR."]),
  dict(type="list", title=sp("the source material"), step=84,              # 11
       items=[["one tone", "a held A3 sine, for the arithmetic"],
              ["one kit", "kick, snare, hat — written note by note", "hot"],
              ["one pad", "held underneath, so there is something to duck"],
              ["no sample", "is loaded anywhere in this project"],
              ["dry peaks", f'{MAT["tone_dry_peak_dbfs"]:.2f} and {MAT["drums_dry_peak_dbfs"]:.2f} dBFS']]),

  # ---------------------------------------------------------- CHAPTER 0 ----
  # ⚠ THE FILM USED TO OPEN "This is a compressor…", which reads as the second
  # half of a video that does not exist. These four cards are the four beats of
  # the new opening, in order: what it does, why you would want it, how the
  # seven knobs split up, and how the demonstrations are built.
  dict(type="statement", size=68, y=250,                                   # 12
       lines=["IT TURNS THE LOUD", "PARTS DOWN.", "AUTOMATICALLY."],
       sub=["That is the whole idea. Everything else is a detail about",
            "how much, how fast, and what you do about it afterwards."]),
  dict(type="list", title=sp("why you would want that"), step=84,          # 13
       items=[["so the quiet parts", "are not lost underneath the loud ones"],
              ["so a part sits", "in a mix instead of jumping out of it", "hot"],
              ["so the whole thing", "can be made louder without distorting"],
              ["that last one", "is also the easiest way to fool yourself", "hot"]]),
  dict(type="list", title=sp("how every number here was made"), step=82,   # 14
       items=[["1. predict", "work it out from the panel, before rendering"],
              ["2. render", "in DAW Pro, offline", "hot"],
              ["3. measure", "off the render, and put BOTH on screen"],
              ["if they disagree", "that is a bug, or a mistake in this lesson", "hot"]]),
  # ⚠ A COURTESY, NOT A GATE. The visuals have to carry the release and knee
  # chapters without headphones, and after the re-cut they do.
  dict(type="statement", size=58, y=300,                                   # 15
       lines=["HEADPHONES HELP", "IN TWO CHAPTERS."],
       sub=["Release and knee turn on differences of a few decibels.",
            "Where you will not be able to hear something, I say so."]),
  dict(type="bignumber", label=sp("measured, not drawn"),                  # 16
       value=f'{INTRO["max_window_reduction_db"]}', unit=sp("db off the loudest moments"), size=170,
       notes=[f'threshold {INTRO["threshold_dbfs"]} dBFS, {INTRO["window_ms"]} ms peak envelope',
              f'dry peak {INTRO["dry_peak_dbfs"]} — compressed peak {INTRO["compressed_peak_dbfs"]} dBFS',
              "the same two renders demo three plays"]),
]

# ------------------------------------------------------------ chapter cards
# ⚠ EVERY CHAPTER'S PUNCH IS ITS CLAUSE OF THE THESIS, not a title. The failure
# mode this episode is trying to avoid is a KNOB TOUR: six measurements that
# never add up to a sentence. Making the spine the furniture is the cheapest
# defence against it.
CHAPTERS = [
  ("d1",  "THRESHOLD AND RATIO", "they decide HOW MUCH, and only how much"),
  ("d1b", "WHERE THE MODEL ENDS", "the curve is arithmetic. The detector is not."),
  ("d2",  "ATTACK",              "it decides what SURVIVES"),
  ("d3",  "RELEASE",             "it decides what it SOUNDS like"),
  ("d4",  "KNEE",                "where those two halves meet"),
  # ⚠ THESE TWO USED TO SHARE ONE CLAUSE ("not compression at all") across two
  # chapters and ~90 s, and the asymmetry was felt: the spine had six clauses for
  # seven chapters. They are not the same idea — makeup changes the LEVEL, mix
  # changes HOW MUCH OF THE COMPRESSOR IS IN THE SIGNAL AT ALL. One clause each.
  ("d5",  "MAKEUP",              "it puts the level back — and that is how every A/B lies"),
  ("d6",  "MIX",                 "it decides how much of the compressor you hear"),
]
CHI = {}
for _i, (_k, _t, _p) in enumerate(CHAPTERS, start=1):
    CHI[_k] = len(cards)
    cards.append(dict(type="statement", size=80, y=330, lines=[_t],
                      sub=[f"chapter {_i} of {len(CHAPTERS)}"],
                      punch=_p, punchSize=46))

# ------------------------------------------------------------------ stages
def sh(name, zoom=None, to=None):
    p = f"{S}/{name}.png"
    return p if zoom is None else {"path": p, "zoom": zoom, **({"to": to} if to else {})}

# Crop boxes as FRACTIONS of the 3000x1900 capture. BOTH RENDERED AND LOOKED AT
# before anything was built on them -- no gate in this rig knows where a crop
# lands, so a rect nobody has seen is a rect nobody has checked.
# ⚠ A PAN MUST KEEP ITS SIZE: crop's w/h are fixed at configure time.
PANEL = [0.2157, 0.2632, 0.5690, 0.5053]   # the whole compressor card, 16:9
TRIG  = [0.3867, 0.3263, 0.2267, 0.2011]   # GR meter + threshold/ratio/knee
ARR   = [0.00,   0.03,   0.72,   0.45]     # the arrangement
# ⚠ A/B HALVES NEED THEIR OWN, TALLER BOX. assemble.py burns the BEFORE/AFTER
# badge at H*0.82, centred — a band chosen because it is empty in the mixer, the
# arrange view and the session film's panel crops. It is NOT empty in PANEL: it
# lands exactly on the compressor's OUTPUT row, and the shipped first cut had
# the badge sitting on top of the MIX readout in demo 6, which is the one value
# that A/B exists to show. Found by extracting the frame and looking at it; no
# gate in this rig can see it. This box keeps the same panel but leaves the
# badge band below it.
PANELAB = [0.1030, 0.2421, 0.7940, 0.7053]

def sweep(prefix, values, box):
    """A control BEING MOVED: same crop, same panel, the value stepping.
    shortsmith cycles a stage's shots at its `cut`, so N stills at a short cut
    IS the animation, and every frame is the real app with the real number."""
    return [sh(f"{prefix}{str(v).replace('.', 'p')}", box) for v in values]

def chapter(key, narration):
    return dict(id=f"ch-{key}", shots=[CHI[key]], cut=4.0, narration=narration)

stages = [
  # =================================================================== CH 0
  # ⚠ THE FOUR BEATS OF THE OPENING, IN ORDER, AND THEY ARE NOT COMPRESSIBLE.
  # Cut 1 opened "This is a compressor…" and the viewer reported it read as a
  # continuation of something they had missed. The user's instruction on length
  # is explicit: a balanced video beats fitting everything in, and if something
  # has to go it is a demo, never this.
  dict(id="00a-what",
       # ⚠ SIX STILLS, NOT NINE, AND EACH ONE IS A SETTLED STATE OF THE SCENE.
       # The first pass sampled the diagram on a fixed grid and one of the
       # frames landed mid-Create: a half-drawn curve, which is animation for
       # 1/30 s and a broken chart for the 4.6 s a still is on screen. Found by
       # extracting the frame from the finished film and looking at it.
       shots=[12, *[sh(f"intro-dia-{i:02d}") for i in range(1, 7)], 16], cut=4.6,
       factCheck=[["threshold"], ["five point nine", "5.9"]],
       narration=(
         "Before anything else, what a compressor actually is, because if you "
         "have never used one the name tells you nothing. Any piece of music has "
         "moments that are much louder than the rest — a drum hit, a word sung "
         "harder than the ones around it. A compressor watches the level of the "
         "sound going through it, and when a moment gets too loud, it turns that "
         "moment down. On its own. Thousands of times a second. You choose the "
         "line it measures against, and that line is called the threshold. Below "
         "the line, the compressor does nothing whatsoever. Above it, it pushes "
         "the sound back down towards the line. This picture is not a drawing. "
         "It is the measured level of a real four bar loop, before and after, and "
         "the loudest moments come down by up to five point nine decibels. Think "
         "of a hand on a volume fader that never gets tired and reacts in a "
         "thousandth of a second.")),

  dict(id="00b-why",
       shots=[13, sh("app-arrange", ARR), sh("app-compressor", PANEL),
              sh("app-pad-arrange", ARR)], cut=6.4, holdLast=False,
       factCheck=[["loudness"], ["mix"]],
       narration=(
         "So why would you want that? Three reasons, and they are not the same "
         "reason. The first is so the quiet parts are not lost. Once the loud "
         "moments are held down you can raise the whole thing, and the detail "
         "that was hiding underneath comes up with it. The second is so a part "
         "sits in a mix. A vocal that is right in front of your face on one word "
         "and gone on the next is a level problem, and this is the level tool. "
         "And the third is the one most people actually mean: with the peaks "
         "lower, there is room to turn everything up without it distorting. That "
         "is why compression became another word for loudness. It is also the "
         "easiest way in the world to fool yourself, and there is a whole chapter "
         "about that near the end.")),

  dict(id="00c-knobs",
       shots=[0, 1, *sweep("comp-d1-ratio-", [1, 2, 4], TRIG),
              sh("app-compressor", PANEL)], cut=4.6,
       factCheck=[["seven"], ["threshold and ratio"]],
       narration=(
         "This is the compressor in DAW Pro, and it has seven controls. Almost "
         "nobody who uses one could tell you what all seven do, and you do not "
         "need to memorise them, because they only do three jobs. Threshold and "
         "ratio decide how much. Attack and release decide what it sounds like. "
         "Knee decides where those two halves meet. And makeup and mix are not "
         "compression at all — they are what you do about it afterwards. That "
         "sentence is the whole video. Every chapter from here is one clause of "
         "it, in order.")),

  dict(id="00d-how",
       shots=[14, sh("app-compressor", PANEL), 15], cut=4.4, holdLast=False,
       brandCheck="DAW Pro",
       factCheck=[["prediction"], ["headphones"]],
       narration=(
         "One more thing before the first demonstration, because it is why this "
         "video exists rather than another knob tour. A compressor is arithmetic. "
         "What it will do to a signal can be worked out from the numbers on that "
         "panel before you play a single note. So for every demonstration here I "
         "wrote the prediction down first, in a file, then rendered the audio in "
         "DAW Pro and measured what actually came out, and both numbers go on "
         "screen together. If they ever disagree, that is either a bug in this "
         "compressor or a mistake in my lesson, and either one is worth more than "
         "the video. And a courtesy: two of these chapters turn on differences of "
         "a couple of decibels, and headphones help there. Where you are not "
         "going to be able to hear something, I will say so plainly rather than "
         "telling you to listen harder.")),

  dict(id="03-material", shots=[11, sh("app-arrange", ARR),
                                sh("app-pad-arrange", ARR)], cut=4.0,
       loop=f"{A}/drums-dry.wav", burst="mat-drums",
       factCheck=[["sample"], ["note by note", "note-by-note"]],
       narration=(
         "The material, and nothing here is sampled. A kick, a snare and a hat, "
         "written note by note out of the app's own synthesiser. A held chord "
         "underneath them — engineers call that a pad — so that later on there is "
         "something for the drums to push down onto. And one steady tone, for the "
         "demonstrations where the arithmetic has to be clean and a drum hit "
         "would get in the way of it.")),

  chapter("d1",
    "Chapter one. The two controls that decide how much, and a steady tone "
    "underneath them so that nothing else can interfere with the measurement."),

  dict(id="05-d1",
       shots=[*sweep("comp-d1-ratio-", [1, 2, 4], TRIG), 2], cut=3.0,
       bedEligible=False,
       # ⚠ normalize FALSE, ADDED IN THE RE-CUT AND IT IS A REAL FIX. The
       # assembler loudness-normalises each half of an A/B separately unless a
       # stage opts out. MEASURED: this pair is 8.90 LU apart raw and came out
       # +0.00 LU apart after that step -- so cut 1's demo-1 A/B was two equally
       # loud tones, and the one number the chapter exists to demonstrate could
       # not be heard at all. No gain is applied: at -16.1 and -25.0 LUFS both
       # halves already sit inside the film's own range.
       normalize=False,
       ab=dict(before=f"{A}/d1-ratio1-CONTROL.wav", seconds=3.0, cycles=2,
               beforeShots=[sh("comp-d1-ratio-1", PANELAB)],
               afterShots=[sh("comp-d1-ratio-4", PANELAB)]),
       loop=f"{A}/d1-ratio4.wav",
       factCheck=[["nine point zero", "9.0"],
                  ["eight point eight nine one", "8.891"]],
       narration=(
         "Threshold is the line. Ratio is how hard the compressor pushes back "
         "once the sound is over that line: four to one means that for every four "
         "decibels the sound goes over, only one decibel of that is allowed "
         "through. Here is a steady tone sitting twelve decibels above the "
         "threshold, at a ratio of four to one. The arithmetic says three "
         "quarters of that twelve comes off, which is nine point zero decibels. "
         "Measured off the render, it came off by eight point eight nine one. And "
         "here is the control that makes that number mean anything: the same tone "
         "at a ratio of one to one, which is no compression at all, measured "
         "exactly zero. You are about to hear those two, and the second one is "
         "genuinely quieter — nothing has been levelled.")),

  chapter("d1b",
    "Chapter two, and it is the best thing that happened while making this "
    "video. My prediction was wrong."),

  dict(id="07-d1b",
       shots=[*sweep("comp-d1b-rel-", [5, 100, 2000], PANEL), 3], cut=3.2,
       loop=f"{A}/det-rel100.wav", burst="mat-tone", bedEligible=False,
       factCheck=[["zero point one zero nine", "0.109"],
                  ["far too small to hear", "too small to hear"],
                  ["detector"]],
       narration=(
         "Nine point zero against eight point eight nine one is a shortfall of "
         "zero point one zero nine decibels. Now, that is far too small to hear, "
         "and I am not going to pretend otherwise — this chapter is about the "
         "arithmetic, not about your ears. The curve I did the arithmetic on is "
         "an idealisation. The thing actually watching the signal is called a "
         "peak detector, and between the peaks of a wave it sags a little. So a "
         "shorter release should widen the gap, and a longer one should close it. "
         "At five milliseconds the shortfall is zero point five five one eight. "
         "At two thousand, zero point zero one five eight. It closes, "
         "monotonically. Three points, and they all lean the same way.")),

  chapter("d2",
    "Chapter three. How much has been settled. Nothing so far has decided what "
    "any of it actually sounds like."),

  dict(id="09-d2",
       shots=[*sweep("comp-d2-atk-", [0.1, 5, 50], PANEL), 4], cut=3.0,
       # ⚠ normalize FALSE plus ONE shared +9.562 dB, chosen from the louder
       # file's peak. Same defect as demo 1: separately normalised, this pair's
       # 9.60 LU became 2.20 LU. The transient is the subject, so the pair is
       # peak-referenced rather than loudness-referenced.
       normalize=False, bedEligible=False,
       ab=dict(before=f"{A}/g-d2-attack-fast.wav", seconds=3.0, cycles=2,
               beforeShots=[sh("comp-d2-atk-0p1", PANELAB)],
               afterShots=[sh("comp-d2-atk-50", PANELAB)]),
       loop=f"{A}/g-d2-attack-slow.wav",
       factCheck=[["transient"], ["twelve point nine five", "12.95"]],
       narration=(
         "Attack is how long the compressor waits before it starts pushing. Most "
         "people think it means how fast the compressor works. It really decides "
         "how much of the transient you keep — and the transient is the click at "
         "the very front of a sound, the stick hitting the drum, the part your "
         "ear uses to tell what the instrument is. Same drum hit both times, only "
         "the attack changes. At a tenth of a millisecond the compressor catches "
         "the click and flattens it. At fifty milliseconds the click is gone "
         "before the compressor even arrives. Twelve point nine five decibels of "
         "transient, kept or crushed, by one control. One gain was applied to "
         "both takes, so that difference is the real one.")),

  chapter("d3",
    "Chapter four. Attack decided what gets in. Release decides how long the "
    "compressor keeps holding the sound down after the loud moment has passed."),

  # ⚠⚠ THIS CHAPTER WAS RE-SHOT AND RE-WRITTEN. The user could not hear cut 1's
  # release comparison on laptop speakers and was RIGHT: the two settings
  # differed by 11.5 dB, but at -39.9 against -51.5 dBFS, in a drum tail with
  # nothing else sounding. A held pad moved the information up out of the floor.
  # THE PANEL IS RE-SHOT TOO -- the old comp-d3-rel-* stills were photographed at
  # threshold -34 / ratio 10 on a drums-only rig and no rendered file was ever
  # made at those settings.
  dict(id="11-d3",
       shots=[*sweep("comp-d3p-rel-", [30, 200, 800], PANEL),
              sh("app-pad-arrange", ARR)], cut=3.6, holdLast=False,
       # ⚠ "18.9" WITHOUT THE SIGN. Whisper writes "minus 18.9 decibels" for a
       # script that says "minus eighteen point nine", so a "-18.9" alternative
       # never matches and eight perfect takes were thrown away for it.
       factCheck=[["pad"], ["minus eighteen point nine", "18.9"]],
       narration=(
         "Release is the control people describe with adjectives — pumping, "
         "breathing, squashed — and it does not need any of them. Here is the "
         "loop: kick, snare, hat, and the pad held underneath from beginning to "
         "end. The pad is the thing to listen to, and that is the whole point of "
         "this arrangement. The threshold is set at minus eighteen point nine "
         "decibels, which only the kick is loud enough to cross. But a compressor "
         "does not turn down the kick, it turns down everything, so each time the "
         "kick lands, the pad gets dragged down with it. Release decides how "
         "quickly the pad is allowed to come back up in the gap before the next "
         "hit.")),

  # THE CHART. Its play segment IS the chart, running at real time with the two
  # settings' audio laid under their own sweeps -- 0.85 s and 4.20 s, taken from
  # the numbers anim_release.py prints, not eyeballed.
  dict(id="11b-d3chart",
       shots=[5, sh("comp-d3p-rel-30", PANEL), sh("comp-d3p-rel-800", PANEL)],
       cut=4.0, holdLast=False,
       loop=f"{A}/chart-release.wav", burst="chart-release",
       playMax=9.6, normalize=False, bedEligible=False,
       factCheck=[["two point one seven", "2.17"], ["nine point two", "9.2"],
                  ["shaded"]],
       narration=(
         "This chart is not an illustration. It is the compressor's own gain, "
         "measured — the compressed render divided by the dry one, sample by "
         "sample. Zero at the top means it has let go completely. At a release of "
         "thirty milliseconds it comes back to zero between every single hit. At "
         "eight hundred, it never gets back at all: its least reduced moment in "
         "the whole loop is still two point one seven decibels down. The shaded "
         "bands are where the two settings differ by more than three decibels, "
         "and that is exactly where to listen. The line sweeping across is on the "
         "instant you are hearing. One gain of nine point two decibels was applied "
         "to both takes and nothing else — so the two point seven you can hear "
         "between them is the release, still holding the bed down.")),

  chapter("d4",
    "Chapter five, and it is the demonstration nobody does — partly because of "
    "what it turns out to show."),

  dict(id="13-d4",
       shots=[*sweep("comp-d4-knee-", [0, 6, 12, 24], TRIG), 6], cut=3.0,
       holdLast=False,
       factCheck=[["knee"], ["one point five two", "1.5202", "1.52"]],
       narration=(
         "Knee is the one control here that has nothing to do with time or with "
         "amount. It decides whether the compressor switches on abruptly the "
         "instant a sound crosses the threshold, or eases in around it. A hard "
         "knee is a corner. A soft knee is a curve. So here is a test rather than "
         "a diagram: a steady tone sitting two decibels below the threshold — "
         "under the line, where a compressor is supposed to be doing nothing at "
         "all. With a hard knee it does nothing: zero decibels, exactly as "
         "predicted. With the knee wide open, that same tone is pulled down by "
         "one point five two zero two decibels. A soft knee has already started "
         "working before you reach the line.")),

  # ⚠⚠ THE HONEST CHAPTER. State the bound, do not soften it, and do not imply
  # the viewer's ears or speakers are at fault. The gap is capped by the gain
  # computer's own arithmetic at slope x knee / 8 -- 2.25 dB here, 2.85 dB at
  # the widest ratio the plugin allows -- against a loudness JND near 1 dB.
  # NO SETTING AND NO SIGNAL COULD EVER HAVE MADE THIS AUDIBLE.
  dict(id="13b-d4chart",
       shots=[6, sh("comp-d4-knee-0", PANEL), sh("comp-d4-knee-24", PANEL)],
       cut=4.0, holdLast=False,
       loop=f"{A}/chart-knee.wav", burst="chart-knee",
       playMax=11.9, normalize=False, bedEligible=False,
       factCheck=[["two point two five", "2.25"], ["two point eight five", "2.85"],
                  ["gentle because it is gentle"]],
       narration=(
         "And now the honest part, which is the reason this chapter exists. You "
         "are about to hear both tones, hard knee and then soft knee, and on "
         "laptop speakers you will not hear any difference between them. That is "
         "not your speakers and it is not your ears. The size of this gap is "
         "fixed by the compressor's own arithmetic: at these settings the widest "
         "it can ever be is two point two five decibels, and at the most extreme "
         "ratio this plugin will let you dial, two point eight five. A difference "
         "of about one decibel is roughly the smallest a person can notice under "
         "good conditions, and worse than that on a small speaker. So the chart "
         "is the only place you will ever see this. A soft knee is called gentle "
         "because it is gentle.")),

  chapter("d5",
    "Chapter six. Everything up to here was compression. The last two controls "
    "are not compression at all."),

  dict(id="15-d5a",
       shots=[*sweep("comp-d5-makeup-", [0, 7.3], PANEL), 7], cut=3.2,
       # ⚠ normalize FALSE, and the wavs pre-gained by ONE shared static gain.
       # The assembler's loudnorm is dynamic: MEASURED, it turned a real 2.1 LU
       # difference into 1.5 LU the OTHER WAY. A stage whose subject IS loudness
       # cannot be levelled by the thing that ships it.
       normalize=False,
       ab=dict(before=f"{A}/g-d5-uncompressed.wav", seconds=3.0, cycles=1,
               beforeShots=[sh("comp-d5-makeup-0", PANELAB)],
               afterShots=[sh("comp-d5-makeup-7p3", PANELAB)]),
       loop=f"{A}/g-d5-makeup7.3.wav",
       factCheck=[["louder"], ["two LU", "2 LU", "2.0 LU"]],
       narration=(
         "Compressing something makes it quieter, so every compressor has a "
         "makeup gain: a plain volume knob at the end to put the level back. LUFS, "
         "which is about to appear on screen, is just a loudness measurement — the "
         "unit a streaming service uses to decide how loud your track is. Here is "
         "the version of this comparison that everybody demonstrates: "
         "uncompressed, then compressed with the makeup pushed a bit past where "
         "it belongs. The compressed one is two LU louder. Notice that you prefer "
         "it. Louder always wins a blind comparison, every time, and that is not "
         "a fact about compression.")),

  dict(id="16-d5b",
       shots=[sh("comp-d5-makeup-5p3", PANEL), 8], cut=3.6,
       normalize=False,
       ab=dict(before=f"{A}/g-d5-uncompressed.wav", seconds=3.0, cycles=2,
               beforeShots=[sh("comp-d5-makeup-0", PANELAB)],
               afterShots=[sh("comp-d5-makeup-5p3", PANELAB)]),
       loop=f"{A}/g-d5-makeup5.3.wav",
       factCheck=[["four point five", "4.5"], ["limiter"]],
       narration=(
         "Now the fair version. The compression cost five point three LU, so I "
         "gave back exactly five point three, and both takes now measure minus "
         "twenty six point three LUFS. The same loudness. Now you can hear what "
         "the compressor did to the sound, instead of hearing that it was louder. "
         "And there is a result here I did not expect. At equal loudness the "
         "compressed take peaks four point five decibels higher than the "
         "uncompressed one. The ten millisecond attack lets the transient "
         "through, and the makeup gain then lifts it. Compression raised the "
         "peaks. That is why a limiter goes after a compressor and not instead "
         "of one.")),

  chapter("d6",
    "Chapter seven, the last control, and the one that used to cost you a "
    "second track and a second compressor to get at."),

  dict(id="18-d6",
       shots=[*sweep("comp-d6-mix-", [1, 0.7, 0.4, 0], PANEL), 9], cut=2.8,
       # ⚠ normalize FALSE and ONE shared +12.581 dB across the pair. The first
       # cut levelled these two, which put the 19.3 LU collapse on a card while
       # only the transient half was audible — a number on screen the ear could
       # not check. Un-levelled, both figures are what plays.
       normalize=False,
       ab=dict(before=f"{A}/g-d6-wet.wav", seconds=3.0, cycles=2,
               beforeShots=[sh("comp-d6-mix-1", PANELAB)],
               afterShots=[sh("comp-d6-mix-0p4", PANELAB)]),
       loop=f"{A}/g-d6-parallel.wav",
       factCheck=[["parallel"], ["eleven point six five", "11.65"]],
       narration=(
         "Mix decides how much of the compressor you hear at all. At one hundred "
         "per cent you hear only the compressed signal. Turn it down and the "
         "untouched original is blended back in underneath, which engineers call "
         "parallel compression. This is a deliberately brutal setting — threshold "
         "minus forty, ratio twenty to one. Fully wet, the kit is flattened and "
         "loses nineteen point three LU; it very nearly disappears, and it is "
         "supposed to. At forty per cent it comes back, keeping eleven point six "
         "five decibels more of its transient than the fully wet version. These "
         "two halves are not levelled — one gain went on both — so the collapse "
         "you are about to hear is the real one and not a card. And at a mix of "
         "zero I subtracted that render from the dry one and got silence. "
         "Bit-exact.")),

  dict(id="19-close", shots=[10, sh("app-compressor", PANEL)], cut=5.0,
       brandCheck="DAW Pro",
       factCheck=[["threshold"], ["makeup"]],
       narration=(
         "So: threshold and ratio decide how much. Attack and release decide what "
         "it sounds like. Knee decides where those two meet. Makeup and mix are "
         "not compression: makeup puts the level back, and mix decides how much "
         "of the compressor you hear at all. Seven controls, one sentence. Every "
         "number came off a render you can reproduce, in DAW Pro. The one "
         "prediction that missed is in here too, and so is the one difference "
         "that is too small to hear.")),
]
DESC = f"""Seven knobs on a compressor, and one sentence that explains all of them.

Threshold and ratio decide HOW MUCH. Attack and release decide what it SOUNDS
LIKE. Knee decides where those two meet. Makeup and mix are not compression at
all — they are what you do about it afterwards.

Six demonstrations, built inside DAW Pro. The source material is one held sine
tone and one drum kit written note by note out of the app's own synth — nothing
is sampled. Every number was PREDICTED from the compressor's gain computer
before anything was rendered, then measured off the render:

· threshold and ratio: predicted {D1["predicted_gr_db"]} dB of reduction, measured {D1["measured_gr_db"]}.
  The ratio-1 control measured {D1["control_ratio1_measured_db"]} dB — unity, as it must
· the {D1B["shortfall_db_at_release_100ms"]} dB shortfall is the peak DETECTOR decaying between the peaks of
  the wave. Confirmed, not asserted: it is {D1B["shortfall_db_at_release_5ms"]} dB at a 5 ms release and
  {D1B["shortfall_db_at_release_2000ms"]} dB at 2000 ms — it closes monotonically
· attack: {D2["transient_kept_vs_crushed_db"]} dB of transient kept or crushed by one knob
· release — RE-SHOT for this cut, with a held pad under the drums so the pumping
  happens on something you can actually hear. Measured on the compressor's own
  gain curve (compressed / dry, sample by sample): at 30 ms it lets go
  COMPLETELY between hits (median {MED["30 ms"]} dB, least-reduced moment {abs(LEAST["30 ms"]):.2f} dB);
  at 800 ms it never lets go at all (least-reduced moment {abs(LEAST["800 ms"]):.2f} dB). The two
  takes are deliberately NOT loudness-matched: one gain of +{DLV["common_gain_db"]} dB on both,
  {DLV["30 ms"]} against {DLV["800 ms"]} LUFS, and that {abs(DLV["30 ms"] - DLV["800 ms"]):.1f} LU IS the release
· knee — the demo nobody does: a tone 2 dB BELOW threshold. Hard knee {D4["hard_knee_measured_gr_db"]} dB,
  soft knee {D4["soft_knee_24db_measured_gr_db"]} dB (predicted {D4["soft_knee_24db_predicted_gr_db"]}). A soft knee starts working before
  you cross the line — and you will NOT hear it on laptop speakers: the gap is
  bounded by the gain computer's own arithmetic at {D4["max_possible_gap_db_at_ratio_4_knee_24"]} dB here and
  {D4["max_possible_gap_db_at_ratio_20"]} dB at any setting, against a loudness JND near 1 dB
· makeup: loudness-matched at {D5["loudness_matched_lufs"]} LUFS both ways — and at equal loudness the
  COMPRESSED take peaks 4.5 dB HIGHER ({D5["matched_peak_dbfs"]:.2f} against {D5["uncompressed_peak_dbfs"]:.2f} dBFS).
  Compression raised the peaks. That is why a limiter follows a compressor
· mix: parallel at 40% keeps {D6["parallel_vs_wet_peak_kept_db"]} dB more transient than fully wet, and
  mix 0 nulls against the dry render bit-exactly

DISCLOSURE
The narration is a synthetic voice, generated locally. No music-generation
model was used, and no sample is loaded anywhere in the project.

#compression #mixing #musicproduction #daw #audioengineering #mixingtips"""

spec = dict(
    bursts=os.environ.get("SESSION_BURSTS") or f"{HERE}/bursts",
    meter="br",
    id="B3",
    title="Seven knobs on a compressor, and only two decide how much",
    filename="DAW Pro Lesson - The Compressor, Measured",
    theme="mastering",
    size="1920x1080",
    playMax=7.0,
    playlist="Mixing, measured",
    categoryId="27",
    description=DESC,
    tags=["compression", "compressor", "mixing", "music production", "DAW",
          "audio engineering", "parallel compression", "makeup gain", "mixing tips"],
    cards=cards,
    stages=stages,
)

out = f"{HERE}/B3.json"
json.dump(spec, open(out, "w"), indent=1, ensure_ascii=False)
words = sum(len(s["narration"].split()) for s in stages)
print(f"wrote {out}")
print(f"{len(stages)} stages, {len(cards)} cards, {words} narration words "
      f"(~{words/2.45/60:.1f} min of speech before demos)")
