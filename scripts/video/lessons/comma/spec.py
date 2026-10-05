#!/usr/bin/env python3
"""Emit the rebuilt "The Comma" lesson's spec for shortsmith.py.

Written as code rather than hand-typed JSON for the same reason the three
finished rebuilds are: every number on a CARD is injected from
MEASUREMENTS.json, so a figure cannot drift from the file it was measured into,
because it is never typed twice.

⚠ THE NARRATION IS THE RISKY HALF. Numbers must be SPELLED OUT in the script —
the speech model reads digits unreliably and the content gate compares a
TRANSCRIPT against the script — so the spoken forms ARE typed by hand.
`check()` below asserts every spoken figure against the measured one at build
time and refuses to emit a spec whose words and measurements have drifted apart.
Every numeric factCheck carries its digit spelling, because Whisper writes the
digits back even when the script spells them out.

⭐ WHAT THIS FILM MEASURES, AND WHY THAT IS UNUSUAL FOR A TUNING VIDEO.
The Pythagorean comma is normally quoted. Here it is DERIVED
(1200*log2((3/2)^12 / 2^7)), then RENDERED — every tone is a sampler zone whose
`tuneCents` the app varispeeds — and then measured back off the render. The
app put all twenty-one tones within 0.0000 cents of the arithmetic, so the
film's headline figure is confirmed by its own material rather than cited.

⭐ AND THE BEATING IS MEASURED, NOT ASSERTED. Three beat rates are predicted
from the partials that collide and then measured off the renders with an
analytic-envelope estimator; three more configurations CANNOT beat and are
carried as controls, which is what makes the first three numbers mean anything.

⚠ THIS FILM HAS NO AUDIBILITY FAULT and does not invent one. The comma is a
pitch difference in the middle of the spectrum and a laptop reproduces it
perfectly well. What IS said plainly is the one thing the measurements show
about audibility: the tempered third's beating lives inside a single harmonic
and is about a hundred times shallower in the whole sound than the comma's,
which is why it reads as roughness rather than as a wobble.
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
S, A = f"{HERE}/shots", f"{HERE}/audio"

MAT = M["material"]
TUN = M["tuning"]
B = M["beats"]
W = M["walk"]
LO = M["loudness"]
EX = M["excerpts"]
DEPTH_RATIO = B["comma"]["full"]["depth"] / B["thirdET"]["full"]["depth"]
MAXERR = max(abs(v["errCents"]) for v in TUN.values())


def check(spoken, measured, tol, what):
    """Refuse to build if a spoken number has drifted from the measured one."""
    if abs(spoken - measured) > tol:
        sys.exit(f"SPEC REFUSES TO BUILD — {what}: the narration says {spoken} "
                 f"but MEASUREMENTS.json says {measured:.6f}")


check(23.46, MAT["comma"], 0.005, "the comma in cents")
check(701.955, MAT["fifthPure"], 0.001, "the pure fifth in cents")
check(1.955, MAT["etNarrowing"], 0.001, "the equal-temperament narrowing")
check(386.314, MAT["thirdPure"], 0.001, "the pure major third in cents")
check(440.0, TUN["a440"]["measuredHz"], 0.001, "the reference A")
check(446.003, TUN["commaHigh"]["measuredHz"], 0.001, "the comma-sharp A")
check(660.0, TUN["fifthPure"]["measuredHz"], 0.001, "the pure fifth in hertz")
check(659.255, TUN["fifthET"]["measuredHz"], 0.001, "the tempered fifth in hertz")
check(550.0, TUN["thirdPure"]["measuredHz"], 0.001, "the pure third in hertz")
check(554.365, TUN["thirdET"]["measuredHz"], 0.001, "the tempered third in hertz")
check(0.0, MAXERR, 0.0001, "how close the renders are to the arithmetic")
check(0.0, W["maxErrCents"], 0.0001, "the walk's largest frequency error")
check(0.0, W["et"]["maxErrCents"], 0.0001, "the tempered walk's largest error")
check(440.0, W["et"]["finalHz"], 0.001, "where the tempered walk ends up")
check(6.003, B["comma"]["full"]["rateHz"], 0.002, "the comma's beat rate")
check(6.003, B["comma"]["predictedHz"], 0.002, "the comma's predicted beat rate")
check(0.0, B["unison"]["full"]["depth"], 0.001, "the in-tune control's depth")
check(0.937, B["comma"]["full"]["depth"], 0.002, "how deep the comma's pulsing is")
check(1.490, B["fifthET"]["band"]["rateHz"], 0.002, "the tempered fifth's beat rate")
check(1.490, B["fifthET"]["predictedHz"], 0.002, "its predicted beat rate")
check(0.0, B["fifthPure"]["band"]["depth"], 0.001, "the pure fifth control")
check(17.461, B["thirdET"]["band"]["rateHz"], 0.002, "the tempered third's beat rate")
check(17.461, B["thirdET"]["predictedHz"], 0.002, "its predicted beat rate")
check(0.0093, B["thirdET"]["full"]["depth"], 0.0005, "its depth in the whole sound")
check(101, DEPTH_RATIO, 1.0, "how much deeper the comma's pulsing is")
check(1320, MAT["partial"]["fifth"], 0.5, "where the fifth's harmonics collide")
check(2200, MAT["partial"]["third"], 0.5, "where the third's harmonics collide")

sp = str.upper
RATIO_N, RATIO_D = MAT["ratioNum"], MAT["ratioDen"]

# ------------------------------------------------------------------- cards
cards = [
  dict(type="statement", size=62, y=250,                                       # 0
       lines=["TWELVE PERFECT FIFTHS",
              "SHOULD EQUAL SEVEN OCTAVES.",
              "THEY DO NOT."],
       sub=["And the gap is why every piano you have ever heard",
            "is deliberately, slightly out of tune."]),

  dict(type="list", title=sp("five words, in plain English"), step=84,         # 1
       items=[["interval", "the distance between two pitches"],
              ["octave", "the same note higher — double the frequency"],
              ["fifth", "the next simplest step: three halves the frequency", "hot"],
              ["cent", "one hundredth of a semitone; twelve hundred to an octave"],
              ["beating", "two close pitches pulsing against each other"]]),

  dict(type="list", title=sp("why those two ratios and not others"), step=88,  # 2
       items=[["a tone is a stack", "one pitch plus quiet copies at 2x, 3x, 4x…"],
              ["the octave, 2 to 1", "every one of its parts already exists below"],
              ["the fifth, 3 to 2", "the next-best match, and the strongest after "
                                    "the octave", "hot"],
              ["'in tune' means", "the parts land on each other instead of near "
                                  "each other"]]),

  dict(type="bignumber", label=sp("a pure fifth, in cents"),                   # 3
       value=f'{MAT["fifthPure"]:.3f}', unit=sp("cents"), size=150,
       notes=["twelve hundred cents make an octave, so a semitone is one hundred",
              "a pure fifth is very slightly WIDER than seven semitones",
              "just under two cents wider — hold on to that number"]),

  dict(type="list", title=sp("the arithmetic, once"), step=90,                 # 4
       items=[["twelve fifths", f'three halves, twelve times over'],
              ["seven octaves", "two, seven times over"],
              ["the ratio between them", f'{RATIO_N} over {RATIO_D}', "hot"],
              ["in cents", f'{MAT["comma"]:.2f} — the Pythagorean comma']]),

  dict(type="list", title=sp("how these tones were made"), step=88,            # 5
       items=[["two source files", "a sine and a saw, both at exactly "
                                  "440 point 000 hertz"],
              ["loaded into the sampler", "as a zone, with a TUNE control in cents",
               "hot"],
              ["the app retunes them", "every pitch in this film is one of those "
                                      "two, moved"],
              ["largest error",
               f'{MAXERR:.4f} cents across all twenty-one measurements']]),

  dict(type="bignumber", label=sp("two a's, twenty three cents apart"),        # 6
       value=f'{B["comma"]["full"]["rateHz"]:.3f}', unit=sp("pulses a second"),
       size=170,
       notes=[f'predicted {B["comma"]["predictedHz"]:.3f}, measured '
              f'{B["comma"]["full"]["rateHz"]:.3f}',
              f'depth {B["comma"]["full"]["depth"]:.4f} — it swings almost to '
              f'silence',
              f'the control, two A\'s in tune, measures '
              f'{B["unison"]["full"]["depth"]:.4f}']),

  dict(type="list", title=sp("equal temperament, in one line"), step=90,       # 7
       items=[["the problem", f'twelve pure fifths overshoot by '
                              f'{MAT["comma"]:.2f} cents'],
              ["the fix", f'make every fifth {MAT["etNarrowing"]:.3f} cents '
                          f'narrower', "hot"],
              ["so a fifth becomes", "exactly seven hundred cents"],
              ["and the circle", f'closes: the twelfth one lands on '
                                 f'{W["et"]["finalHz"]:.3f} hertz']]),

  dict(type="list", title=sp("what the fix costs you"), step=88,               # 8
       items=[["the fifth", f'{B["fifthET"]["band"]["rateHz"]:.3f} pulses a second '
                            f'where a pure one has none'],
              ["the major third", f'{B["thirdET"]["band"]["rateHz"]:.3f} pulses a '
                                  f'second — much worse', "hot"],
              ["why the third suffers", "it was already fourteen cents off before "
                                        "anyone tempered anything"],
              ["what you actually hear", "not a wobble. A slight roughness."]]),

  dict(type="bignumber", label=sp("how much deeper the comma pulses"),         # 9
       value=f'{DEPTH_RATIO:.0f}x', unit=sp("in the whole sound"), size=170,
       notes=[f'the comma modulates the whole tone by '
              f'{B["comma"]["full"]["depth"]:.4f}',
              f'the tempered third modulates it by '
              f'{B["thirdET"]["full"]["depth"]:.4f}',
              'because the third\'s beating lives inside one harmonic, '
              'not in the fundamentals']),

  dict(type="list", title=sp("so why is a piano out of tune"), step=88,        # 10
       items=[["on purpose", "no piano is tuned in pure intervals"],
              ["every fifth", f'is narrowed by about {MAT["etNarrowing"]:.1f} cents'],
              ["every major third", "is left about fourteen cents wide", "hot"],
              ["what you gain", "every key sounds the same, and you can change key"],
              ["what you pay", "a faint roughness in every third, everywhere"]]),

  dict(type="closing", size=52,                                                # 11
       lines=["The circle of fifths is not a circle.",
              "Everything about how we tune",
              "is what to do about that."],
       kicker="Built, rendered and measured in DAW Pro."),
]

# ----------------------------------------------------------------- pictures
ARRANGE, MIXER = f"{S}/arrange.png", f"{S}/mixer.png"
ROLL_WALK, ROLL_BEAT = f"{S}/roll-walk.png", f"{S}/roll-beat.png"
CH_LADDER, CH_BEATS = f"{S}/chart-ladder.png", f"{S}/chart-beats.png"
CH_DEPTH, CH_ENV = f"{S}/chart-depth.png", f"{S}/chart-envelopes.png"
SPIRAL_END, CLOSES_END = f"{S}/spiral-final.png", f"{S}/closes-final.png"
BEAT_END, MARK_END = f"{S}/beatmech-final.png", f"{S}/fifthmark-final.png"
# A cut into the SAMPLER card: at full frame the TUNE readout is ~16 px tall and
# unreadable. MEASURED against the PNG rather than guessed, and deliberately
# 16:9 (1345x756 of the 3200x1800 capture) so the crop fills the film's frame
# instead of being pillarboxed — a taller crop of just the card was tried first
# and looked at.
SAMPLER_5 = {"path": f"{S}/sampler-fifth.png", "zoom": [0.29, 0.20, 0.42, 0.42]}
SAMPLER_3 = {"path": f"{S}/sampler-third.png", "zoom": [0.29, 0.20, 0.42, 0.42]}
SAMPLER_3ET = {"path": f"{S}/sampler-thirdet.png", "zoom": [0.29, 0.20, 0.42, 0.42]}
# the walk's first bars, where the zig-zag of fifths is actually legible
ROLL_ZOOM = {"path": f"{S}/roll-walk.png", "zoom": [0.01, 0.26, 0.44, 0.24]}

# ----------------------------------------------------------------- stages
stages = [
  dict(id="00-open", shots=[0, ARRANGE], cut=4.8, brandCheck="DAW Pro",
       factCheck=[["twelve", "12"], ["seven octaves", "7 octaves"]],
       narration=(
         "Here is a fact that sounds like a mistake. If you take the interval "
         "musicians call a perfect fifth, the purest-sounding step there is "
         "after the octave, and you stack twelve of them one on top of another, "
         "you should land exactly seven octaves above where you started. The "
         "arithmetic of Western music says you do. You do not. You land a "
         "little bit sharp — by a gap that has a name, the Pythagorean comma, "
         "and consequences that reach every instrument with fixed pitches on "
         "it. This lesson does three things with that gap. It draws it, so you "
         "can see twelve fifths walk round a circle and fail to come home. It "
         "generates it as sound and measures it, so the number is confirmed by "
         "its own material rather than quoted at you. And then it shows you "
         "what musicians decided to do about it, which is the reason every "
         "piano you have ever heard is deliberately, very slightly, out of "
         "tune. All of it is built, rendered and measured in DAW Pro. Nothing "
         "here is generated by a music model, and nothing here is a number I "
         "read somewhere.")),

  dict(id="01-terms", shots=[1], cut=6.2,
       factCheck=[["interval"], ["twelve hundred", "1200", "1,200"]],
       narration=(
         "Five words first, in plain English, because the rest of this depends "
         "on them and none of them are hard. An interval is just the distance "
         "between two pitches. An octave is the interval you get when you "
         "double a frequency — the same note, higher, and it sounds so much "
         "like the same note that we give it the same letter. A fifth is the "
         "next simplest step after that: multiply the frequency by three "
         "halves. On a piano it is seven white-and-black keys up, A to E. A "
         "cent is a unit for measuring how far apart two pitches are. There "
         "are one hundred cents in a semitone and twelve hundred cents in an "
         "octave, and a trained ear starts to notice a difference at somewhere "
         "around five of them. And beating is what you hear when two pitches "
         "are very close but not the same: the sound pulses, getting louder "
         "and quieter, over and over. That pulsing is going to be this "
         "lesson's measuring instrument, so we will come back to it properly.")),

  dict(id="02-ratio", shots=[2], cut=6.0,
       loop=f"{A}/ab-fifth-pure.wav", playMax=8.0, bedEligible=False,
       factCheck=[["three to two", "3 to 2", "3:2"], ["harmonics", "harmonic"]],
       narration=(
         "Why those two ratios in particular, and not any of the others. When "
         "almost anything real makes a note — a string, a reed, a voice — it "
         "does not produce one frequency. It produces a whole stack of them: "
         "the pitch you name, and then quieter copies at exactly two times, "
         "three times, four times that frequency, and on up. Those copies are "
         "called harmonics, and they are why a violin and a trumpet playing "
         "the same note sound completely different. Now put two notes "
         "together. If the second note's frequency is exactly double the "
         "first, every single harmonic it has already exists in the first "
         "note's stack. Nothing new, nothing clashing. That is the octave, and "
         "it is why it sounds like the same note. Three to two is the next "
         "best thing: not a perfect containment, but the two stacks line up "
         "over and over, one landing on the other. That is a fifth, and what "
         "you are about to hear is a pure one — four hundred and forty hertz "
         "against six hundred and sixty, rendered by the app. Listen to how "
         "still it is. Nothing moves.")),

  dict(id="03-cents", shots=[3], cut=6.4,
       factCheck=[["seven hundred and one", "701"], ["two cents", "2 cents"]],
       narration=(
         "To compare intervals we need a ruler, and the ruler is the cent. "
         "Twelve hundred cents to an octave, one hundred to a semitone. It is "
         "a logarithmic ruler, which just means that the same number of cents "
         "is the same musical distance whether you are up at the top of the "
         "keyboard or down at the bottom, even though the number of hertz "
         "involved is wildly different. Measured that way, a pure fifth — that "
         "three to two ratio — is seven hundred and one point nine five five "
         "cents. Look at that number for a second. Seven semitones would be "
         "exactly seven hundred. So a pure fifth is not seven semitones. It is "
         "seven semitones plus a bit under two cents. That bit under two cents "
         "is almost nothing on its own. It is far too small to hear as a "
         "mistuned note. But it is the entire subject of this lesson, because "
         "we are about to do it twelve times in a row.")),

  dict(id="04-spiral", shots=[3, SPIRAL_END], cut=6.0,
       loop=f"{A}/spiralbed.wav", burst="spiral", playMax=38.0,
       bedEligible=False,
       factCheck=[["twelve", "12"], ["does not come home", "not come home", "come home"]],
       narration=(
         "So let us do it, and watch. In a moment you will see a circle. The "
         "whole way round it is one octave — twelve hundred cents, with a mark "
         "every hundred, one per semitone. We start on A, at the top. Then we "
         "take one pure fifth, which moves us seven marks round and very "
         "slightly past. Then another, and another, twelve of them, and each "
         "time the line spirals out one ring so you can see where it has been. "
         "The letters are the notes each fifth lands on: A, E, B, F sharp, and "
         "round through all twelve of them. Underneath, you will hear every "
         "one of those thirteen pitches, in order, rendered by the app. Listen "
         "for the last note especially. It is supposed to be the A we started "
         "on, seven octaves later, folded back down. And when the line gets "
         "there, it does not come home. It lands just past the mark it started "
         "on. And when that gap appears on screen, you will hear the two "
         "pitches it sits between played together — the A we set off from, and "
         "the A twelve pure fifths landed on. Hold on to what that sounds "
         "like, because measuring it is what the rest of this lesson does.")),

  dict(id="05-arith", shots=[4, ROLL_WALK, CH_LADDER], cut=7.0, holdLast=True,
       factCheck=[["twenty three point four six", "23.46"],
                  ["Pythagorean", "Pythagorean comma"]],
       narration=(
         "Here is the same thing as arithmetic, and it is short. Stacking "
         "fifths means multiplying by three halves, so twelve fifths is three "
         "halves multiplied by itself twelve times. Seven octaves is two "
         "multiplied by itself seven times. If the two were equal, the circle "
         "would close. They are not. Divide one by the other and you get five "
         "hundred and thirty one thousand, four hundred and forty one, over "
         "five hundred and twenty four thousand, two hundred and eighty eight. "
         "Not one. Close to one — about one point zero one four — but not one. "
         "Converted into cents, that overshoot is twenty three point four six "
         "cents. Slightly less than a quarter of a semitone. That is the "
         "Pythagorean comma. It is not a measurement error and it is not "
         "something that could be fixed with better instruments. It is a fact "
         "about the numbers two and three: no whole number of one will ever "
         "equal a whole number of the other. On screen is the same walk drawn "
         "as a ladder — where the arithmetic says each of the thirteen pitches "
         "should sit, and, crossed on top of it, where the app actually "
         "rendered them.")),

  # ⭐ THE APP ACTUALLY PLAYING IT. `walkplay` is a captureUI burst shot while
  # the transport ran from beat 0, and play-walk.wav is the same passage from
  # beat 0 — checked by reading the transport readout off frame 30 (TIME
  # 0:09.849 at 9.85 s of the burst's own measured rate), so the playhead on
  # screen is crossing the notes you are hearing.
  # ⚠ SAMPLER_5 MUST BE THE HELD (LAST) SHOT. The narration READS A VALUE OFF
  # THIS CONTROL — "the tune knob reads plus seven hundred and two cents" — and
  # with holdLast, assemble gives each of n=round(58.4/7.0)=8 slots 7.3 s and
  # holds only the LAST. As [5, SAMPLER_5, ROLL_ZOOM] the card was on screen
  # 7.3-14.6 s while the value is spoken at ~25.8-31.5 s: the frame at 340 s of
  # the film showed the PIANO ROLL under the words "on screen now". Held last,
  # the card covers 14.6 s to the end of the stage.
  dict(id="06-render", shots=[5, ROLL_ZOOM, SAMPLER_5], cut=7.0, holdLast=True,
       loop=f"{A}/play-walk.wav", burst="walkplay", playMax=20.5,
       bedEligible=False,
       factCheck=[["seven hundred and two", "702", "+702"],
                  ["zero", "0.0000", "0.000", "440.000"],
                  # proves the corrected two-file claim is actually SPOKEN
                  ["sawtooth", "saw tooth", "saw-tooth"]],
       narration=(
         "It is worth saying exactly how the sounds in this film were made, "
         "because the whole argument rests on them being right. There are exactly "
         "two audio files, and both were generated once, at four hundred and "
         "forty point zero zero zero hertz. One is a pure sine wave, and it "
         "makes the walk and the two A's. The other is a sawtooth — a buzzier "
         "wave, with strong harmonics — and it makes the fifths and the "
         "thirds, because the beating in those lives between harmonics, and a "
         "sine wave does not have any. Each one is loaded into the app's "
         "sampler as a zone, and a zone has a tune control, measured in cents. "
         "On screen now is the zone that makes a pure fifth: the file is the "
         "sawtooth, and the tune knob reads plus seven hundred and two cents. "
         "Every single pitch you hear in this lesson is one of those two files "
         "with a different number in that box. Nothing is a preset, nothing is "
         "a recording of an instrument. Then "
         "every render was measured back, by finding the peak of its frequency "
         "spectrum. Across all twenty one measurements — the thirteen in the walk "
         "you "
         "just heard, and the eight in the comparisons still to come — the "
         "largest disagreement between what the arithmetic asked for and what "
         "came out of the app is zero, to four decimal places, in cents. So "
         "when this lesson tells you two tones are a given distance apart, "
         "that is not a setting. It is a measurement.")),

  dict(id="07-beating", shots=[6, BEAT_END], cut=6.4,
       loop=f"{A}/beatbed.wav", burst="beatmech", playMax=24.5,
       bedEligible=False, normalize=False,
       factCheck=[["six times a second", "6 times a second", "six times", "6 times"],
                  ["cancel", "cancels", "cancelling"]],
       narration=(
         "Now the measuring instrument, because from here on this lesson stops "
         "asserting things and starts counting them. When two tones are close "
         "in pitch but not identical, their waves drift through each other. "
         "Sometimes a peak of one lines up with a peak of the other and they "
         "add up to something twice as loud. A moment later that same peak has "
         "slid onto a trough, and they cancel. That cycle — loud, quiet, loud, "
         "quiet — is called beating, and here is the useful part: the number "
         "of pulses per second is exactly the difference between the two "
         "frequencies in hertz. Two tones six hertz apart pulse six times a "
         "second. You can count them with a stopwatch. In a moment you will "
         "see the two waves drawn, and the sum of them underneath, with a bar "
         "showing how loud that sum is at each instant. The first half is two "
         "A's at exactly the same pitch, and nothing moves at all. Then one of "
         "them goes sharp by the comma, and everything moves.")),

  dict(id="08-measure", shots=[6, CH_ENV], cut=6.6, holdLast=True,
       normalize=False, bedEligible=False,
       # ⚠⚠ `loop` IS THE **AFTER** HALF. assemble.py takes BEFORE from
       # ab["before"] and AFTER from the stage's own `loop`. The first build of
       # this film set both to ab-unison.wav, so the A/B alternated one file
       # against ITSELF — the comma was never played, the badges changed and
       # nothing else did, and the A/B separation gate passed it at +0.00 -> 
       # +0.00 because the halves genuinely did not differ. Caught by reading
       # `L4v2.mp4.timeline.json`, not by any gate.
       loop=f"{A}/ab-comma.wav", playMax=12.5,
       # BEFORE gets a NEUTRAL still: card 6 states the AFTER's beat rate, so
       # showing it over the in-tune half describes the wrong half. ROLL_BEAT is
       # the two notes actually sounding.
       ab=dict(before=f"{A}/ab-unison.wav", beforeShots=[ROLL_BEAT],
               afterShots=[CH_ENV], cycles=2, seconds=6.0),
       factCheck=[["six point zero zero three", "6.003"],
                  ["zero", "0.0000", "0.000", "446.003"]],
       narration=(
         "So let us hold the comma up against it. Four hundred and forty hertz "
         "on its own, and four hundred and forty six point zero zero three — "
         "which is four hundred and forty raised by exactly twenty three point "
         "four six cents. The comma, turned into a pitch. Subtract one from "
         "the other and the prediction is six point zero zero three pulses a "
         "second. Measured off the render, by taking the amplitude envelope "
         "and finding its strongest rate: six point zero zero three. And it is "
         "deep — the pulsing swings the level by point nine four out of a "
         "possible one, which means it very nearly drops to silence at the "
         "bottom of every pulse. The control matters more than the "
         "measurement, though. The before half of this comparison is two tones "
         "at exactly the same pitch, same instrument, same level, in exactly "
         "the same arrangement. Its measured depth is zero to four decimal "
         "places. So when you hear the after half pulsing, the pulsing is the "
         "twenty three cents and nothing else. You are listening to the "
         "Pythagorean comma directly.")),

  dict(id="09-fix", shots=[7, CLOSES_END], cut=6.4,
       loop=f"{A}/closesbed.wav", burst="closes", playMax=28.0,
       bedEligible=False,
       factCheck=[["one point nine five five", "1.955"],
                  ["seven hundred", "700", "seven hundred cents"]],
       narration=(
         "So what do you do about a circle that does not close. For a very "
         "long time the answer was: pick your favourite keys, keep those "
         "intervals pure, and shove the entire error into one interval you "
         "promise never to play. That interval was called the wolf, because of "
         "the noise it made, and it meant some keys were beautiful and others "
         "were unusable. The answer that eventually won is much simpler and "
         "much stranger. Take the whole comma, divide it into twelve equal "
         "pieces, and make every single fifth that much narrower. One twelfth "
         "of twenty three point four six is one point nine five five cents. "
         "Take that off every fifth and a fifth becomes exactly seven hundred "
         "cents — exactly seven semitones — and twelve of them come to exactly "
         "seven octaves. That is equal temperament, and it is what the piano "
         "in every room you have ever been in is tuned to. Watch the same walk "
         "again with that one change, and listen: the thirteenth note is now "
         "four hundred and forty hertz, measured, and it is the note we "
         "started on.")),

  dict(id="10-cost-fifth", shots=[7, MARK_END], cut=6.4,
       loop=f"{A}/markerbed.wav", burst="fifthmark", playMax=16.5,
       bedEligible=False, normalize=False,
       factCheck=[["one point four nine", "1.49"],
                  ["thirteen hundred and twenty", "1320", "1,320"]],
       narration=(
         "Nothing is free, so here is the bill, and this is where the beating "
         "earns its keep. A tempered fifth is not a pure fifth any more. Four "
         "hundred and forty hertz against six hundred and fifty nine point two "
         "five five, instead of six hundred and sixty. Those two are over two "
         "hundred hertz apart, far too far apart to beat directly — but their "
         "harmonics are not. The lower note's third harmonic sits at thirteen "
         "hundred and twenty hertz, and the upper note's second harmonic sits "
         "just below it, and those two beat. Predicted rate: one point four "
         "nine pulses a second. Measured off the render, inside a filter "
         "centred on thirteen hundred and twenty hertz: one point four nine. "
         "The chart you are about to see is that filter's output over eight "
         "seconds of the real render, with a playhead moving in real time "
         "against the sound. The first pass is the pure fifth and the line is "
         "flat, because an exact three to two ratio cannot beat. The second is "
         "the tempered one, and the dips are shaded — and those windows are "
         "not chosen by eye, they are every stretch where the measured "
         "envelope falls below half its own middle value.")),

  dict(id="11-cost-third", shots=[8, CH_BEATS], cut=6.6, holdLast=True,
       normalize=False, bedEligible=False,
       loop=f"{A}/ab-third-et.wav", playMax=8.5,          # AFTER; see 08-measure
       # the two sampler cards ARE the A/B: same saw440.wav, TUNE +386 (pure)
       # against +400 (tempered). Card 8 named the AFTER's cost, so it cannot
       # sit over the BEFORE.
       ab=dict(before=f"{A}/ab-third-pure.wav", beforeShots=[SAMPLER_3],
               afterShots=[SAMPLER_3ET], cycles=2, seconds=6.0),
       factCheck=[["seventeen point four six", "17.46"],
                  ["fourteen cents", "14 cents"]],
       narration=(
         "The fifth got off lightly. The major third did not, and this is the "
         "part most explanations skip. A pure major third is a five to four "
         "ratio: four hundred and forty hertz against five hundred and fifty. "
         "In equal temperament a major third is four semitones, exactly four "
         "hundred cents — but a pure one is three hundred and eighty six point "
         "three, so the tempered third is about fourteen cents wide. That is "
         "seven times the error we put into each fifth. Four hundred and forty "
         "against five hundred and fifty four point three six five. The "
         "collision this time is between the lower note's fifth harmonic and "
         "the upper note's fourth, both near twenty two hundred hertz, and the "
         "prediction is seventeen point four six pulses a second. Measured: "
         "seventeen point four six. Here they are one after the other, pure "
         "first, then tempered. And I want to be careful about what to expect, "
         "because seventeen pulses a second is too fast to count. It does not "
         "sound like a wobble. It sounds like a slight, restless roughness — "
         "a texture rather than a movement.")),

  dict(id="12-depth", shots=[9, CH_DEPTH], cut=7.0, holdLast=True,
       factCheck=[["a hundred times", "100 times", "hundred times"],
                  ["one harmonic", "a single harmonic", "harmonic"]],
       narration=(
         "There is a reason the comma is so obvious and the tempered third is "
         "so easy to live with, and it is measurable rather than a matter of "
         "taste. When two tones are almost the same pitch, it is the "
         "fundamentals themselves that cancel, so the whole sound goes up and "
         "down. That is the comma: measured depth of point nine four, out of a "
         "maximum of one. Nearly total. But when a third is tempered, the "
         "fundamentals are far apart and perfectly steady. The only thing "
         "beating is one harmonic, several times higher up and much quieter "
         "than the note it belongs to. Inside that harmonic the beating is "
         "just as deep — point seven — but as a share of the whole sound "
         "reaching your ear it comes to nine thousandths. That is about a "
         "hundred times shallower than the comma. Same phenomenon, same "
         "arithmetic, and completely different to listen to: one of them "
         "wobbles, and the other one just has a texture. Both numbers on this "
         "chart came off the renders you have been hearing.")),

  dict(id="13-piano", shots=[10, MIXER, ARRANGE], cut=6.2,
       factCheck=[["on purpose"], ["every key", "all twelve keys", "any key"]],
       narration=(
         "Which brings us back to the piano, and to the thing that sounds like "
         "a provocation and is simply true. A piano tuner is not trying to "
         "make your intervals pure. They are deliberately making every fifth "
         "about two cents too narrow and leaving every major third about "
         "fourteen cents too wide, and they are doing it on purpose, "
         "everywhere, in every key. Not one interval on the instrument, apart "
         "from the octaves, is in pure tune. What you buy with that is "
         "enormous: every key sounds the same as every other key, a piece can "
         "change key in the middle and nothing collapses, and a keyboard "
         "instrument can play with any other instrument without being "
         "retuned. What you pay is a faint, permanent roughness in every "
         "third, which we are all so used to that a genuinely pure third can "
         "sound slightly strange the first time you hear one in isolation. If "
         "you have ever wondered why a barbershop quartet or a good string "
         "section sounds sweeter than a keyboard on a held chord — that is "
         "why. Singers and string players are not stuck with the compromise. "
         "They lean the notes into tune as they go.")),

  dict(id="14-close", shots=[11, ARRANGE], cut=6.4, brandCheck="DAW Pro",
       factCheck=[["twenty three point four six", "23.46"], ["circle"]],
       narration=(
         "So. Twelve pure fifths do not make seven octaves. They overshoot by "
         "twenty three point four six cents, which we derived from the ratio, "
         "generated as sound, and then measured back off the renders as six "
         "point zero zero three pulses a second against a prediction of six "
         "point zero zero three — with a control, two tones in tune, that "
         "correctly measured nothing at all. The circle of fifths is not a "
         "circle. It is a spiral, and it never closes, and essentially "
         "everything about how we tune instruments is an argument about what "
         "to do with that gap. The answer we settled on was to spread it "
         "evenly and accept a little roughness in every third, forever, in "
         "exchange for being able to play in any key. It is a compromise, and "
         "it is worth knowing that it is one. All of it was built, rendered "
         "and measured in DAW Pro. Thanks for watching.")),
]

spec = dict(
    id="L4v2", theme="theory", size="1920x1080",
    # ⚠ DELIBERATELY NOT the shipped film's name. --finalize is not run for this
    # rebuild, but if it ever is it must not overwrite the published file before
    # the user has watched this one.
    filename="DAW Pro Lesson 4 - The Comma (rebuild)",
    title="The comma that breaks tuning — drawn, generated, and measured",
    playlist="Mixing, measured", categoryId="27",
    cut=6.0, playMax=10.0, introSeconds=4, outroSeconds=3, meter="br",
    bursts=f"{HERE}/bursts",
    cards=cards, stages=stages,
    tags=["music theory", "tuning", "equal temperament", "Pythagorean comma",
          "acoustics", "intervals", "piano", "beat frequency"],
    description=(
        "Twelve perfect fifths should equal seven octaves. They do not — and "
        "this lesson draws the gap, generates it as sound inside DAW Pro, and "
        "then measures it back off the renders.\n\n"
        "THE COMMA\n"
        f'Derived rather than quoted: 1200*log2((3/2)^12 / 2^7) = '
        f'{RATIO_N}/{RATIO_D} = {MAT["comma"]:.4f} cents.\n\n'
        "HOW THE TONES WERE MADE\n"
        "Two source files, both generated at exactly 440.000 Hz: a sine (the walk "
        "and the two A's) and a sawtooth (the fifths and thirds, whose beating "
        "lives between harmonics a sine does not have). Each is loaded as a sampler "
        "zone and retuned by the zone's TUNE control in cents. Every pitch in the "
        f'film is one of those two files moved. Largest disagreement between the '
        f'arithmetic and the render, across all twenty-one measurements: '
        f'{MAXERR:.4f} cents.\n\n'
        "MEASURED BEAT RATES (predicted, then measured off the render)\n"
        f'440.000 + {TUN["commaHigh"]["measuredHz"]:.3f} Hz (the comma): '
        f'{B["comma"]["predictedHz"]:.3f} predicted, '
        f'{B["comma"]["full"]["rateHz"]:.3f} measured, depth '
        f'{B["comma"]["full"]["depth"]:.4f}.\n'
        f'440.000 + {TUN["fifthET"]["measuredHz"]:.3f} Hz (the tempered fifth, at '
        f'the {MAT["partial"]["fifth"]:.0f} Hz partial): '
        f'{B["fifthET"]["predictedHz"]:.3f} predicted, '
        f'{B["fifthET"]["band"]["rateHz"]:.3f} measured.\n'
        f'440.000 + {TUN["thirdET"]["measuredHz"]:.3f} Hz (the tempered third, at '
        f'the {MAT["partial"]["third"]:.0f} Hz partial): '
        f'{B["thirdET"]["predictedHz"]:.3f} predicted, '
        f'{B["thirdET"]["band"]["rateHz"]:.3f} measured.\n\n'
        "THE CONTROLS\n"
        "Three configurations that cannot beat, carried so the three numbers "
        f'above mean something: two A\'s in tune (depth '
        f'{B["unison"]["full"]["depth"]:.4f}), a pure 3:2 fifth (depth '
        f'{B["fifthPure"]["band"]["depth"]:.4f}), and a pure 5:4 third (depth '
        f'{B["thirdPure"]["band"]["depth"]:.4f}).\n\n'
        "WHY ONE WOBBLES AND THE OTHER IS ONLY ROUGH\n"
        "The comma beats between the FUNDAMENTALS, so the whole sound modulates "
        f'({B["comma"]["full"]["depth"]:.4f}). The tempered third beats inside one '
        "harmonic, so the whole sound modulates by only "
        f'{B["thirdET"]["full"]["depth"]:.4f} — about {DEPTH_RATIO:.0f}x shallower. '
        "That is measurable, and it is why one reads as a wobble and the other as "
        "a texture.\n\n"
        "THE FIX\n"
        f'Equal temperament narrows every fifth by {MAT["etNarrowing"]:.3f} cents. '
        "The same thirteen-note walk in equal temperament ends on a measured "
        f'{W["et"]["finalHz"]:.3f} Hz — exactly the A it started on.\n\n'
        "DISCLOSURE\n"
        "The narration is a synthetic voice, generated locally. No music-generation "
        "model was used; every tone was generated and retuned by hand.\n\n"
        "#musictheory #tuning #equaltemperament #pythagoreancomma #musicproduction "
        "#acoustics"),
)

if __name__ == "__main__":
    json.dump(spec, open(f"{HERE}/L4v2.json", "w"), ensure_ascii=False, indent=1)
    words = sum(len(s["narration"].split()) for s in stages)
    print(f"{HERE}/L4v2.json  {len(cards)} cards, {len(stages)} stages, "
          f"{words} words of narration")
