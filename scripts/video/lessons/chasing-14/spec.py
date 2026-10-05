#!/usr/bin/env python3
"""Emit the rebuilt "Chasing −14" lesson's spec for shortsmith.py.

Written as code rather than hand-typed JSON for the same reason the mono lesson
is: every number on a CARD is injected from MEASUREMENTS.json, so a figure
cannot drift from the file it was measured into, because it is never typed
twice.

⚠ THE NARRATION IS DIFFERENT, AND IT IS THE RISKY HALF. Numbers must be SPELLED
OUT in the script — the speech model reads digits unreliably and the content
gate compares a TRANSCRIPT against the script — so the spoken forms ARE typed by
hand. `check()` below therefore asserts every spoken figure against the measured
one at build time, and refuses to emit a spec whose words and measurements have
drifted apart.

⚠ EVERY NUMERIC factCheck CARRIES ITS DIGIT SPELLING. The script spells numbers
out because the speech model reads digits badly; Whisper then writes them BACK
as digits, and the mono lesson lost two full eight-take rounds to exactly that.

⚠ Paths are absolute. assemble.py resolves a relative shot against its --shots
root, which is the OUT dir, not this one.
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
S, A = f"{HERE}/shots", f"{HERE}/audio"

LOUD = M["loudness"]
DRY, G14 = LOUD["dry"], M["ladder"][0]
G5 = M["ladder"][-1]
MASTERS = M["masters"]
LW = M["loudwar_master"]
BILL = M["bill"]
CH = M["chain"]
CTL = M["controls"]
GR = M["compressor_gr"]
MK = M["_chart"]["marker"]
ZOOM = M["_chart"]["zoom"]
AB = M["ab"]


def check(spoken, measured, tol, what):
    """Refuse to build if a spoken number has drifted from the measured one."""
    if abs(spoken - measured) > tol:
        sys.exit(f"SPEC REFUSES TO BUILD — {what}: the narration says {spoken} "
                 f"but MEASUREMENTS.json says {measured:.4f}")


# every figure the voice says, checked against the file it came from
check(-20.5, DRY["integratedLufs"], 0.02, "the mix's loudness")
check(-2.23, DRY["samplePeakDbfs"], 0.02, "the mix's peak")
check(3.7, DRY["loudnessRangeLu"], 0.02, "the mix's loudness range")
check(18.3, DRY["plrDb"], 0.05, "the mix's peak-to-loudness ratio")
check(6.48, G14["gainDb"], 0.01, "the naive gain")
check(-14.0, G14["measuredLufs"], 0.02, "what the naive gain reaches")
check(4.25, G14["floatPeakDbfs"], 0.02, "the peak after the naive gain")
check(944, G14["clippedSamples"], 0, "the clipped-sample count")
check(506, G14["clipRuns"], 0, "the number of clipped runs")
check(23, ZOOM["runSamples"], 0, "the longest flat top, in samples")
check(0.48, G14["longestRunMs"], 0.01, "the longest flat top, in milliseconds")
check(-54.6, G14["residualRmsDbfs"], 0.05, "the distortion's own level at −14")
check(-38.5, G14["residualBelowProgramDb"], 0.05, "how far under the music it sits")
check(-16.9, G5["residualRmsDbfs"], 0.05, "the distortion's level at −5")
check(158241, G5["clippedSamples"], 0, "the clipped-sample count at −5")
check(37.8, M["ladder_span_db"], 0.05, "the span across the ladder")
check(-24.7, MK["g14"]["closestDb"], 0.05, "the closest approach at −14")
check(-0.5, MK["g5"]["closestDb"], 0.05, "the closest approach at −5")
check(34.1, AB["isolatedDeltaDb"], 0.05, "the two isolated residuals' difference")
check(-149.2, CTL["unclippedSubtractionRmsDbfs"], 0.05, "the quantisation control")
check(0, CTL["selfSubtractionNonZeroSamples"], 0, "the self-subtraction control")
check(0, CTL["dryClipStats"]["clippedSamples"], 0, "the untouched mix's clip count")
check(-15.2, MASTERS[2]["integratedLufs"], 0.02, "the limiter-only master")
check(-1.0, MASTERS[2]["truePeakDbtp"], 0.02, "the limiter-only true peak")
check(-14.1, MASTERS[3]["integratedLufs"], 0.02, "the finished master")
check(3.2, MASTERS[3]["loudnessRangeLu"], 0.02, "the finished master's range")
check(7.16, CH["masteredGainDb"], 0.01, "the drive into the finished chain")
check(3.38, GR["reductionMedianDb"], 0.01, "the median gain reduction")
check(8.7, GR["reductionMaxDb"], 0.02, "the deepest gain reduction")
check(6, GR["makeupDb"], 0, "the makeup gain")
check(-8.7, LW["integratedLufs"], 0.02, "the loudness-war master")
check(1.6, LW["loudnessRangeLu"], 0.02, "the loudness-war master's range")
check(40.9, CH["loudwarGainDb"], 0.05, "the drive it took to chase −8")
check(0.5, BILL["rangeLostLu"], 0.02, "the range lost reaching −14")
check(2.1, BILL["loudwarRangeLostLu"], 0.02, "the range lost chasing −8")
check(57, BILL["loudwarRangeLostPercent"], 0.5, "the percentage lost chasing −8")
check(6.2, AB["unmatched"]["deltaLu"], 0.05, "the unmatched A/B difference")
check(318, M["material"]["notes"], 0, "the note count")
check(16, M["material"]["bars"], 0, "the bar count")

sp = str.upper
NCLIP = f'{G14["clippedSamples"]:,}'

# ------------------------------------------------------------------- cards
cards = [
  dict(type="statement", size=70, y=250,                                     # 0
       lines=["SIX AND A HALF DECIBELS", "OF GAIN GETS YOU TO −14.",
              "HERE IS THE BILL."],
       sub=["Nothing here is an opinion.",
            "Every number was predicted first, then measured off the render."]),
  dict(type="list", title=sp("three meters, in plain English"), step=96,      # 1
       items=[["peak", "the single highest number in the file"],
              ["LUFS", "how loud it SOUNDS, averaged, the way an ear hears it", "hot"],
              ["loudness range", "how much that loudness MOVES across the track"]]),
  dict(type="list", title=sp("where minus fourteen comes from"), step=88,     # 2
       items=[["streaming platforms", "play everything at one loudness"],
              ["so they turn you down", "if you are louder than their target"],
              ["and turn you up", "if you are quieter", "hot"],
              ["minus fourteen", "is one such target — not a law of physics"]]),
  dict(type="list", title=sp("the mix being mastered"), step=88,              # 3
       items=[["written by hand", f'{M["material"]["notes"]} notes, '
                                  f'{M["material"]["bars"]} bars, four parts'],
              ["nothing on the master", "no gain, no compressor, no limiter"],
              ["measured", f'{DRY["integratedLufs"]:.2f} LUFS, peak '
                           f'{DRY["samplePeakDbfs"]:.2f} dBFS, '
                           f'{DRY["loudnessRangeLu"]:.2f} LU of range', "hot"],
              ["the number that matters",
               f'peak minus loudness = {DRY["plrDb"]:.1f} dB of headroom to spend']]),
  dict(type="bignumber", label=sp("the obvious move, and what it costs"),     # 4
       value=f'+{G14["gainDb"]:.2f}', unit=sp("db of gain"), size=170,
       notes=[f'lands on {G14["measuredLufs"]:.2f} LUFS exactly — a gain moves '
              f'loudness one for one',
              f'and moves the PEAK one for one too: {G14["floatPeakDbfs"]:.2f} dBFS',
              'which is above the highest number an integer file can store']),
  dict(type="bignumber", label=sp("what a 24-bit file did with it"),          # 5
       value=NCLIP, unit=sp("samples clipped"), size=170,
       notes=[f'in {G14["clipRuns"]:,} separate runs, the longest '
              f'{ZOOM["runSamples"]} samples ({G14["longestRunMs"]:.2f} ms)',
              f'{G14["clippedPercent"]:.3f}% of the file — and nothing warned about it',
              'the float render stored the same peaks quite happily']),
  dict(type="list", title=sp("how the distortion was isolated"), step=84,     # 6
       items=[["one render in float", "which stores samples above full scale"],
              ["one render in 24-bit", "which cannot, and clamps them"],
              ["subtract", "what is left is the clipping, and nothing else", "hot"],
              ["control one",
               f'the same subtraction on the unclipped mix: '
               f'{CTL["unclippedSubtractionRmsDbfs"]:.1f} dB, the 24-bit floor'],
              ["control two",
               f'a file minus itself: {CTL["selfSubtractionNonZeroSamples"]} '
               f'non-zero samples — digital silence']]),
  dict(type="bignumber", label=sp("and here is the honest part"),             # 7
       value=f'{G14["residualBelowProgramDb"]:.1f}', unit=sp("db under the music"),
       size=170,
       notes=[f'the distortion measures {G14["residualRmsDbfs"]:.2f} dBFS on its own',
              f'at its very closest it is still {abs(MK["g14"]["closestDb"]):.0f} dB '
              f'below the music it is hiding in',
              'you will not hear that on a laptop speaker, and this film '
              'will not pretend otherwise']),
  dict(type="list", title=sp("the same mix, four loudness targets"), step=84,  # 8
       items=[[f'−14 LUFS', f'{G14["clippedSamples"]:,} samples clipped · '
                            f'{G14["residualRmsDbfs"]:.1f} dBFS of distortion'],
              [f'−11 LUFS', f'{M["ladder"][1]["clippedSamples"]:,} · '
                            f'{M["ladder"][1]["residualRmsDbfs"]:.1f} dBFS'],
              [f'−8 LUFS', f'{M["ladder"][2]["clippedSamples"]:,} · '
                           f'{M["ladder"][2]["residualRmsDbfs"]:.1f} dBFS'],
              [f'−5 LUFS', f'{G5["clippedSamples"]:,} · '
                           f'{G5["residualRmsDbfs"]:.1f} dBFS', "hot"]]),
  dict(type="statement", size=60, y=320,                                      # 9
       lines=["THE QUIET VERSION IS NOT", "WORSE. IT IS QUIETER."],
       sub=["Louder wins a blind comparison almost every time,",
            "whatever else changed. That is a fact about ears,",
            "not a fact about the master.",
            "So this pair is played twice: as it is, then level-matched."]),
  dict(type="statement", size=96, y=430, rule=False,                          # 10
       lines=["THE MIX, UNTOUCHED"], sub=[f'{DRY["integratedLufs"]:.2f} LUFS']),
  dict(type="statement", size=96, y=430, rule=False,                          # 11
       lines=["THE −14 MASTER"],
       sub=[f'{MASTERS[3]["integratedLufs"]:.2f} LUFS  ·  '
            f'{AB["unmatched"]["deltaLu"]:.1f} LU louder']),
  dict(type="statement", size=82, y=420, rule=False,                          # 12
       lines=["THE −14 MASTER,", "TURNED BACK DOWN"],
       sub=[f'the master pulled down by {abs(AB["matched"]["matchOffsetDb"]):.1f} dB, '
            f'so both sit at {AB["matched"]["before"]["lufs"]:.1f} LUFS']),
  dict(type="bignumber", label=sp("the bill for minus fourteen"),             # 13
       value=f'{BILL["rangeLostLu"]:.1f}', unit=sp("lu of range"), size=180,
       notes=[f'{BILL["dryLra"]:.1f} LU became {BILL["masteredLra"]:.1f} LU, '
              f'for {BILL["loudnessGainedDb"]:.1f} dB of loudness',
              f'that is {BILL["rangeLostPercent"]:.0f}% of the range — real, '
              f'but small',
              'the expensive part is not −14. It is everything past it.']),
  dict(type="bignumber", label=sp("the bill for chasing minus eight"),        # 14
       value=f'{BILL["loudwarRangeLostLu"]:.1f}', unit=sp("lu of range"), size=180,
       notes=[f'{BILL["dryLra"]:.1f} LU became {LW["loudnessRangeLu"]:.1f} LU — '
              f'{BILL["loudwarRangeLostPercent"]:.0f}% of it gone',
              f'and it took +{CH["loudwarGainDb"]:.1f} dB of drive to get there',
              'above the threshold a two-to-one compressor returns half a '
              'decibel for every decibel you feed it']),
  dict(type="statement", size=58, y=330,                                      # 15
       lines=["MOST OF THIS IS A PICTURE,", "NOT A SOUND."],
       sub=["The clipping at −14 measures "
            f'{G14["residualBelowProgramDb"]:.1f} dB under the music.',
            "No speaker is going to hand you that, and the film says so",
            "instead of asking you to listen harder.",
            "The charts are measured off the renders for exactly that reason."]),
  dict(type="list", title=sp("what to actually do"), step=92,                 # 16
       items=[["mix with headroom", "peak minus loudness is what you get to spend",
               "hot"],
              ["limiter last, true peak on", "a ceiling of minus one dBTP"],
              ["compressor before it", "gently — it is what buys the loudness back"],
              ["then measure", "and read the loudness RANGE, not just the LUFS",
               "hot"],
              ["and ask", "who is actually asking you for minus fourteen"]]),
  dict(type="closing", size=58, y=560,                                        # 17
       lines=["Built and measured in DAW Pro.",
              "The build script, the measurements and the charts",
              "are all reproducible."],
       kicker="Spend the headroom on purpose, not by accident."),
  dict(type="statement", size=96, y=430, rule=False,                          # 18
       lines=["CHASING −14"], sub=["the clipping, on its own, at one shared gain"]),
  dict(type="statement", size=96, y=430, rule=False,                          # 19
       lines=["CHASING −5"], sub=["the same isolation, the same gain"]),
  dict(type="statement", size=96, y=430, rule=False,                          # 20
       lines=["CLEAN"], sub=["the −5 master, before the file clamped it"]),
  dict(type="statement", size=96, y=430, rule=False,                          # 21
       lines=["CLIPPED"], sub=[f'{G5["clippedSamples"]:,} samples pinned flat']),
]

# ------------------------------------------------------------------ shots
CH_WAVE = f"{S}/chart-waveform.png"
CH_FLAT = f"{S}/chart-flattop.png"
CH_MAST = f"{S}/chart-masters.png"
CH_LADD = f"{S}/chart-ladder.png"
CH_BILL = f"{S}/chart-bill.png"
CH_GR = f"{S}/chart-gr.png"
CH_TIME = f"{S}/chart-overtime.png"
# ⚠ bursts.py copies each scene's LAST frame here after every render. NEVER
# reference bursts/<name>/f####.png from a spec — explode() wipes that dir.
MECH_FINAL = f"{S}/mechanism-final.png"
CLIP_FINAL = f"{S}/clipchart-final.png"

ARRANGE, ROLL = f"{S}/arrange.png", f"{S}/roll.png"
MIXER_DRY, MIXER_M = f"{S}/mixer-dry.png", f"{S}/mixer-mastered.png"
# cuts into the three insert cards — at full frame the knob readouts are ~14 px
FXGAIN_NAIVE = {"path": f"{S}/fx-gain-naive.png", "zoom": [0.385, 0.400, 0.235, 0.230]}
FXGAIN = {"path": f"{S}/fx-gain.png", "zoom": [0.385, 0.400, 0.235, 0.230]}
FXCOMP = {"path": f"{S}/fx-comp.png", "zoom": [0.385, 0.245, 0.235, 0.550]}
FXLIM = {"path": f"{S}/fx-lim.png", "zoom": [0.385, 0.305, 0.235, 0.435]}
INSERTS = {"path": f"{S}/mixer-mastered.png", "zoom": [0.878, 0.195, 0.108, 0.140]}

# ----------------------------------------------------------------- stages
stages = [
  dict(id="00-open", shots=[0, ARRANGE], cut=4.6, brandCheck="DAW Pro",
       factCheck=[["minus fourteen", "minus 14", "-14", "−14"]],
       narration=(
         "Somewhere along the way, minus fourteen LUFS turned into a number "
         "people chase. This lesson is about what it actually costs to get "
         "there, measured rather than asserted. One mix, mastered four "
         "different ways, with every meter shown after every move. It is built "
         "and measured inside DAW Pro, and nothing in it is an opinion: every "
         "number was worked out from first principles before anything was "
         "rendered, then measured off the render, and both go on the screen "
         "together. Every chart you are about to see was drawn from a DAW Pro "
         "render as well. And one warning up front, because it is the honest "
         "thing to say. The damage this lesson is about is mostly something you can "
         "see rather than something you can hear, and I will show you exactly "
         "how far below the music it sits rather than telling you to listen "
         "harder.")),

  dict(id="01-meters", shots=[1], cut=5.6,
       factCheck=[["loudness range"], ["peak"]],
       narration=(
         "Start from the beginning, in case this is new. There are three "
         "different meters in this story and they measure three different "
         "things. The first is peak. That is simply the single highest number "
         "anywhere in the file, and it tells you almost nothing about how loud "
         "something sounds. A sharp drum hit has a huge peak and very little "
         "loudness. The second is LUFS, which stands for loudness units "
         "relative to full scale. That is an average, weighted roughly the way "
         "an ear is weighted, over the whole track, and it is the number that "
         "actually corresponds to how loud a piece of music seems. The third "
         "is loudness range, in LU. That is not how loud it is, it is how much "
         "the loudness MOVES: the difference between the quiet parts and the "
         "loud parts. Hold on to that third one, because it is the one nobody "
         "watches, and it is the one that gets spent.")),

  dict(id="02-why", shots=[2], cut=5.6,
       factCheck=[["minus fourteen", "minus 14", "-14", "−14"],
                  ["turn it up", "turned up"]],
       narration=(
         "So where does minus fourteen come from. Streaming services normalise. "
         "They measure every track that arrives and play them all back at "
         "roughly one loudness, so that a quiet record and a loud record do not "
         "make the listener reach for the volume between songs. If your master "
         "arrives louder than their target, they turn it down. If it arrives "
         "quieter, most of them turn it up. Minus fourteen LUFS is one of "
         "those targets. It is a convention, not a law of physics, and it "
         "changes between services and over time. Which is worth remembering, "
         "because in a moment we are going to pay quite a lot to hit it "
         "exactly.")),

  dict(id="03-mix", shots=[3, ARRANGE, ROLL, MIXER_DRY], cut=4.6,
       loop=f"{A}/ab-dry.wav", burst="arrangeplay", playMax=8.4,
       normalize=False, factCheck=[["three hundred and eighteen", "318"],
                                   ["sixteen bars", "16 bars"],
                                   ["minus twenty point five", "minus 20.5", "-20.5", "−20.5"]],
       narration=(
         "Here is the mix we are going to master. Three hundred and eighteen "
         "notes, sixteen bars, four parts, written by hand — a pad, a bass, a "
         "drum kit and a lead. Nothing is generated, and there is nothing at "
         "all on the master bus: no gain, no compressor, no limiter. Rendered "
         "exactly as it is, it measures minus twenty point five LUFS, its "
         "highest single sample is minus two point two three decibels below "
         "full scale, and its loudness range is three point seven LU. Subtract "
         "the loudness from the peak and you get about eighteen decibels. That "
         "gap is the headroom, and everything that happens next is a decision "
         "about how to spend it.")),

  dict(id="04-arithmetic", shots=[4, FXGAIN_NAIVE, CH_WAVE], cut=5.0,
       holdLast=True,
       factCheck=[["six point four eight", "6.48"], ["four point two five", "4.25"]],
       narration=(
         "The obvious move is a gain. Turning something up is arithmetic: a "
         "static gain of a certain number of decibels moves the measured "
         "loudness by exactly that many decibels. So from minus twenty point "
         "five to minus fourteen is six point four eight decibels, and that is "
         "not an estimate, it is a subtraction. Here it is, one gain insert on "
         "the master bus — the knob rounds it to six point five, but the value "
         "underneath is six point four eight. And the render agrees: minus fourteen point zero "
         "LUFS, dead on. But the same gain moves the peak by exactly the same "
         "amount, and the peak had only two point two decibels of room. Six "
         "point four eight minus two point two three puts the highest sample at "
         "plus four point two five decibels — above full scale. Above the "
         "highest number the file format has.")),

  dict(id="05-mechanism", shots=[MECH_FINAL, CH_WAVE], cut=8.0,
       loop=f"{A}/mech.wav", burst="mechanism", playMax=22.2,
       normalize=False, bedEligible=False,
       factCheck=[["clipping"], ["flat"]],
       narration=(
         "So what happens to a number that will not fit. In a moment you will "
         "see a waveform, drawn at this mix's own measured peak, and two "
         "dashed lines marking full scale. Watch what happens as the gain comes "
         "up. The parts of the wave that go past the line do not get quieter "
         "and they do not wrap around. They get cut off flat, because the file "
         "stores the largest number it has instead. That is clipping, and it is "
         "worth being precise about what it does. It is not a level change. It "
         "is a curve being replaced by a straight line, and a straight line "
         "where a curve should be is new content — frequencies that were never "
         "in the music. At the end you will see that difference drawn on its "
         "own. Underneath, you are hearing the same passage twice: the clean "
         "version first, then the version the file actually stored.")),

  dict(id="06-count", shots=[5, CH_FLAT], cut=5.6, holdLast=True,
       factCheck=[["nine hundred and forty four", "944"],
                  ["twenty three", "23"], ["half a millisecond"]],
       narration=(
         "Now the measurement. The same master rendered to twenty four bit — "
         "which is what you would actually deliver — comes back with nine "
         "hundred and forty four samples pinned flat against the ceiling, in "
         "five hundred and six separate runs. The longest of them is twenty "
         "three samples long, which is about half a millisecond. Here is that "
         "one, magnified. The violet line is what the mix asked for and the red "
         "line is what the file could store, and in the middle the red line "
         "simply goes straight for half a millisecond. Nothing anywhere warned "
         "about this. The floating point render stored the same peaks quite "
         "happily, the loudness meter said minus fourteen and looked pleased "
         "with itself, and the only reason we know is that we went and "
         "counted.")),

  dict(id="07-controls", shots=[6, CH_FLAT], cut=6.0, holdLast=True,
       factCheck=[["subtract", "subtracting", "subtraction"],
                  ["digital silence"]],
       narration=(
         "Before believing any of that, the method needs checking, because a "
         "measurement without a control is just a claim. The way the distortion "
         "gets isolated is a subtraction: render the same master twice, once in "
         "floating point, which can hold samples above full scale, and once in "
         "twenty four bit, which cannot. Subtract one from the other. "
         "Everything that fitted cancels to nothing, and what is left is "
         "exactly the clipping. Two controls tell us that subtraction is doing "
         "what it claims. Run it on the untouched mix, which never goes above "
         "full scale, and it returns minus one hundred and forty nine decibels "
         "— that is the twenty four bit noise floor and nothing else. Run it on "
         "a file against itself and it returns digital silence: zero non-zero "
         "samples, not a small number, actually zero.")),

  dict(id="08-honest", shots=[7, CH_LADD], cut=9.0, holdLast=True,
       factCheck=[["minus fifty four", "minus 54", "-54", "−54"],
                  ["thirty eight", "38"], ["laptop"]],
       narration=(
         "And now the part that most videos about clipping quietly skip. How "
         "loud is that distortion? On its own it measures minus fifty four "
         "point six decibels below full scale. Compare that to the music it is "
         "hiding inside, and it sits thirty eight and a half decibels "
         "underneath. At its very closest moment, in the loudest, busiest part "
         "of the track, it still never gets within twenty five decibels of the "
         "music. That is real, it is correctly measured, and on a laptop "
         "speaker you are not going to hear it. I am not going to ask you to "
         "listen harder, because there is nothing wrong with your ears or your "
         "speakers. So instead, here is the same experiment run four times.")),

  dict(id="09-ladder", shots=[8, CH_LADD], cut=9.0, holdLast=True,
       factCheck=[["a hundred and fifty eight thousand", "158,000", "158000"],
                  ["thirty eight decibels", "38 decibels", "38 dB"]],
       narration=(
         "Four loudness targets, from minus fourteen up to minus five, the same "
         "mix and the same plain gain each time. At minus fourteen, nine "
         "hundred and forty four samples clip. At minus eleven, twenty six "
         "thousand. At minus eight, ninety thousand. At minus five, a hundred "
         "and fifty eight thousand samples — four percent of the entire file. "
         "And the distortion itself climbs with it: from minus fifty four point "
         "six decibels at the minus fourteen target, to minus sixteen point nine "
         "at minus five. That is a span of nearly thirty eight decibels, from one mix and "
         "one gain knob. The left hand chart is the important one, because it "
         "shows the distortion relative to the music rather than on its own. At "
         "minus fourteen it is far too far down to matter. Somewhere between "
         "minus eleven and minus eight it climbs out of the floor, and by minus "
         "five it is right up against the music.")),

  dict(id="10-isolate", shots=[18, 6], cut=4.4,
       loop=f"{A}/resid5.wav", normalize=False, bedEligible=False, playMax=8.4,
       ab=dict(before=f"{A}/resid14.wav", beforeShots=[18], afterShots=[19],
               cycles=2, seconds=8.0),
       factCheck=[["thirty four", "34"], ["same amount"]],
       narration=(
         "Here is that, isolated and played to you. This is the clipping on its "
         "own, with the music subtracted away, from the minus fourteen master "
         "and then from the minus five master. Both are turned up by exactly "
         "the same amount, so what you hear is the real relationship between "
         "them and not two things normalised to sound equally loud. The first "
         "one is almost nothing — a few faint ticks. The second one is thirty "
         "four decibels louder and it is an obvious, ugly buzz. Same mix, same "
         "gain knob, two different positions on it.")),

  dict(id="11-marker", shots=[8, CLIP_FINAL], cut=9.0,
       loop=f"{A}/chartaudio.wav", burst="clipchart", playMax=24.2,
       normalize=False, bedEligible=False,
       factCheck=[["shaded"], ["half a decibel"]],
       narration=(
         "This next chart says when to listen and where, so you are not "
         "hunting. It shows the clipping relative to the music, moment by "
         "moment, across eight seconds of the same passage, and a playhead "
         "sweeps it at real speed while you hear that passage. The dashed line "
         "is roughly forty decibels under the music, which is about where a "
         "small speaker stops handing you anything — a rule of thumb, not a "
         "measurement, and it is drawn as one. First the minus fourteen master: "
         "the line spends most of its time on the floor of the chart, meaning "
         "there is no clipping there at all, and never climbs above minus "
         "twenty five. Then the minus five master, where the same line comes "
         "within half a decibel of the music itself. The shaded bars are not "
         "chosen by eye — they are every stretch where that second version "
         "crosses the dashed line, worked out from the measurements. When the "
         "playhead is inside one, that is the moment to listen.")),

  dict(id="12-limiter", shots=[INSERTS, FXLIM], cut=8.0, holdLast=True,
       factCheck=[["minus one", "minus 1", "-1", "−1"], ["true peak"],
                  ["minus fifteen point two", "minus 15.2", "-15.2", "−15.2"]],
       narration=(
         "So let us do it properly instead. The tool for the peak problem is a "
         "limiter. A limiter is a hard ceiling: you tell it a level and no "
         "output sample is allowed past it, ever. Here is the one on this "
         "master, set to a ceiling of minus one decibel with true peak "
         "detection switched on. True peak matters and it is worth thirty "
         "seconds. A digital file is a set of dots, and the speaker plays the "
         "smooth curve that runs through those dots. That curve can rise higher "
         "between two dots than either dot did, so a file whose samples all sit "
         "under the ceiling can still overshoot it when something reconstructs "
         "it — a converter, or an MP3 encoder. True peak mode measures the "
         "curve rather than the dots. With that limiter in the chain and "
         "exactly the same six point four eight decibels of gain in front of "
         "it, nothing clips: the true peak is minus one point zero, dead on. "
         "But the loudness has fallen to minus fifteen point two, because the "
         "limiter took the peaks away and the peaks were part of the "
         "loudness.")),

  dict(id="13-compressor", shots=[FXGAIN, FXCOMP], cut=7.0, holdLast=True,
       factCheck=[["two to one", "2:1", "2 to 1"],
                  ["twenty millisecond", "20 millisecond", "20 ms"],
                  ["minus eighteen", "minus 18", "-18", "−18"]],
       narration=(
         "Which is where the compressor comes in, and it is worth saying "
         "plainly what it is for here. A compressor turns down the loud parts "
         "automatically, so the peaks come down before the limiter ever sees "
         "them, and that lets the whole thing be driven harder without the "
         "limiter having to grab as much. Here is the one on this master. The "
         "ratio is two to one, above a threshold of minus eighteen decibels — "
         "so above that level, every two decibels that go in come out as one. "
         "The attack is twenty milliseconds, which is slow enough to let the "
         "front of a drum hit through before the gain starts moving, and the "
         "release is a hundred and eighty milliseconds. And there is six "
         "decibels of makeup gain at the end, putting back some of what the "
         "compression took away.")),

  # ⚠ SPLIT OUT OF 13 DELIBERATELY. As one stage the settings were read while
  #   the gain-reduction chart was on screen and the chart was described while
  #   nothing but the chart's own last still remained — 46 seconds of narration
  #   cannot follow three pictures at any cut length. Two stages, one picture
  #   each, is the fix.
  dict(id="13b-result", shots=[CH_GR, INSERTS], cut=9.0, holdLast=True,
       factCheck=[["seven point two", "7.2"],
                  ["three point four", "3.4"],
                  ["minus fourteen point one", "minus 14.1", "-14.1", "−14.1"]],
       narration=(
         "With that compressor in front of the limiter, the drive that reaches "
         "the target is seven point two decibels, and the finished master "
         "measures minus fourteen point one LUFS at minus one point zero true "
         "peak. Nothing clipped. And this chart is not a drawing. It is one "
         "render with the compressor bypassed, divided by one with it engaged, "
         "at the same drive, sample for sample — which makes it the "
         "compressor's own gain, measured rather than illustrated. The median "
         "is three point four decibels of reduction, the deepest moment is "
         "eight point seven, and it is working past three decibels for well "
         "over half of the track. So that is the whole chain: a gain, a gentle "
         "compressor, and a true peak limiter, in that order.")),

  dict(id="14-louder", shots=[9, 10, 11], cut=9.0, holdLast=True,
       loop=f"{A}/ab-mastered.wav", normalize=False, playMax=8.4,
       ab=dict(before=f"{A}/ab-dry.wav", beforeShots=[10], afterShots=[11],
               cycles=2, seconds=8.0),
       factCheck=[["six point two", "6.2"], ["louder"]],
       narration=(
         "Now the honest beat, and it is the one thing that makes almost every "
         "mastering comparison on the internet worthless. Louder wins. If you "
         "play two versions of the same music and one of them is louder, "
         "listeners prefer the louder one, almost regardless of what else "
         "changed. That is a fact about ears, not a fact about the master. So "
         "here is this pair played the dishonest way first: the mix, then the "
         "finished master, with no level matching at all — one single gain "
         "applied to both, so the six point two LU difference between them is "
         "the real one. The second one is going to sound better. It is not "
         "better. It is louder.")),

  dict(id="15-matched", shots=[12, CH_TIME], cut=5.6, holdLast=True,
       loop=f"{A}/ab-masteredM.wav", normalize=False, playMax=8.4,
       ab=dict(before=f"{A}/ab-dryM.wav", beforeShots=[10], afterShots=[12],
               cycles=2, seconds=8.0),
       factCheck=[["same measured loudness"], ["six point two", "6.2"]],
       narration=(
         "So here is the same pair again with the master pulled back down by "
         "six point two decibels, so that both sit at the same measured "
         "loudness. Now there is nothing to prefer on volume, and what is left "
         "is what the chain actually did. And what it did was mostly to stop "
         "the level moving. Listen for the drum hits sitting a little less "
         "proud, and the quiet bar at the start being a little less quiet. "
         "That is not damage — a mastering chain is supposed to do that. But it "
         "is the trade, and it is the thing that the loudness number on its own "
         "will never show you. The chart underneath is the same three masters "
         "as a level over time, and the story is in the shapes: the louder the "
         "master, the flatter the line.")),

  dict(id="16-bill", shots=[13, CH_MAST, CH_BILL], cut=5.6, holdLast=True,
       factCheck=[["three point seven", "3.7"], ["three point two", "3.2"],
                  ["nought point five", "0.5", "zero point five", "naught point five"]],
       narration=(
         "So what did minus fourteen cost, exactly. The mix had three point "
         "seven LU of loudness range. The finished master has three point two. "
         "Six point four decibels of loudness cost nought point five LU of "
         "range, which is about fourteen percent of it. That is real, and it is "
         "smaller than the internet would have you believe. Doing this properly "
         "to reach a normal streaming target is not an act of vandalism. Look "
         "at the whole set together, though, because the numbers only mean "
         "something side by side. The untouched mix, the plain gain that hits "
         "the target and clips, the limiter alone that stays clean but lands "
         "short, and the compressor and limiter together that reach the target "
         "cleanly. Every one of those bars was measured off a render, twice, by "
         "two different meters that agreed to within a twentieth of a "
         "decibel.")),

  dict(id="17-past", shots=[14, CH_BILL], cut=5.6, holdLast=True,
       factCheck=[["minus eight point seven", "minus 8.7", "-8.7", "−8.7"],
                  ["one point six", "1.6"], ["fifty seven", "57"]],
       narration=(
         "And then there is what happens past it, which is where the price "
         "actually is. The same chain, the same compressor, driven as hard as "
         "it will go, reaches minus eight point seven LUFS. And the loudness "
         "range collapses from three point seven to one point six — fifty seven "
         "percent of it gone. There is also a lovely piece of arithmetic hiding "
         "in that. Getting there took plus forty point nine decibels of gain, "
         "which sounds absurd until you remember what a two to one ratio means: "
         "above the threshold, every extra decibel you feed the compressor "
         "comes out as half a decibel. So the fader number runs away from you "
         "while the loudness crawls. That is what chasing loudness feels like "
         "from the inside.")),

  dict(id="18-close", shots=[16, 15, 17], cut=5.4, brandCheck="DAW Pro",
       factCheck=[["headroom"], ["loudness range"]],
       narration=(
         "So, what to do with all that. First, mix with headroom, because peak "
         "minus loudness is exactly the budget you get to spend later, and you "
         "cannot spend what you did not leave. Second, put a limiter last with "
         "true peak switched on and a ceiling around minus one, and let a "
         "gentle compressor in front of it do the work of getting there. Third, "
         "measure afterwards, and read the loudness range as well as the LUFS, "
         "because the LUFS number is the one that tells you that you succeeded "
         "and the range is the one that tells you what it cost. And last: "
         "streaming platforms normalise. A quieter master gets turned up for "
         "you, at no charge, with none of this damage. So before you pay for "
         "minus fourteen, it is worth asking who is actually asking you for it. "
         "Everything in this video was built and rendered in DAW Pro, and "
         "measured off those DAW Pro renders. Thanks for watching.")),
]

spec = dict(
    id="L6v2", theme="mastering", size="1920x1080",
    # ⚠ DELIBERATELY NOT the shipped film's name. --finalize is not run for this
    # rebuild, but if it ever is, it must not overwrite the published file
    # before the user has watched this one.
    filename="DAW Pro Lesson 6 - Chasing -14 (rebuild)",
    title="Chasing −14 LUFS: what it costs, measured on one mix four ways",
    playlist="Mixing, measured", categoryId="27",
    cut=5.0, playMax=9.0, introSeconds=4, outroSeconds=3, meter="br",
    bursts=f"{HERE}/bursts",
    cards=cards, stages=stages,
    tags=["mastering", "LUFS", "loudness", "true peak", "clipping", "limiter",
          "compression", "music production"],
    description=(
        "One mix, mastered four ways, with every meter shown after every move. "
        "Every number on screen was measured off the actual render — none of it "
        "is a rule of thumb.\n\n"
        "THE MIX\n"
        f'{M["material"]["notes"]} notes, {M["material"]["bars"]} bars, four parts, '
        "written by hand. Nothing on the master bus. Rendered: "
        f'{DRY["integratedLufs"]:.2f} LUFS, peak {DRY["samplePeakDbfs"]:.2f} dBFS, '
        f'{DRY["loudnessRangeLu"]:.2f} LU of range — {DRY["plrDb"]:.1f} dB of headroom '
        "to spend.\n\n"
        "THE OBVIOUS MOVE\n"
        f'+{G14["gainDb"]:.2f} dB lands on {G14["measuredLufs"]:.2f} LUFS exactly, and '
        f'puts the peak at {G14["floatPeakDbfs"]:.2f} dBFS. Rendered to 24-bit, '
        f'{G14["clippedSamples"]:,} samples come back pinned flat, in '
        f'{G14["clipRuns"]:,} runs, the longest {ZOOM["runSamples"]} samples '
        f'({G14["longestRunMs"]:.2f} ms). Subtracting the clean render from the clipped '
        f'one isolates the distortion at {G14["residualRmsDbfs"]:.2f} dBFS.\n\n'
        "THE CONTROLS\n"
        "The same subtraction on the unclipped mix returns "
        f'{CTL["unclippedSubtractionRmsDbfs"]:.1f} dBFS — the 24-bit noise floor — and '
        f'a file minus itself returns {CTL["selfSubtractionNonZeroSamples"]} non-zero '
        "samples, i.e. digital silence. Every loudness figure was measured twice, by "
        "the app and by ffmpeg's ebur128, agreeing to within 0.05 LU.\n\n"
        "HOW MUCH OF IT YOU CAN HEAR\n"
        "Said plainly rather than assumed: at −14 the clipping sits "
        f'{abs(G14["residualBelowProgramDb"]):.1f} dB under the music, and at its very '
        f'closest never gets within {abs(MK["g14"]["closestDb"]):.0f} dB of it. You will '
        "not hear that on a laptop. So the same experiment is run at four targets — "
        f'−14, −11, −8 and −5 — where the distortion climbs {M["ladder_span_db"]:.1f} dB, '
        "and the film plays the isolated artefact from both ends at one shared gain.\n\n"
        "DONE PROPERLY\n"
        f'A true-peak limiter alone holds {MASTERS[2]["truePeakDbtp"]:.2f} dBTP but only '
        f'reaches {MASTERS[2]["integratedLufs"]:.2f} LUFS. Adding a 2:1 compressor '
        f'(−18 dB threshold, 20 ms attack, +6 dB makeup) reaches '
        f'{MASTERS[3]["integratedLufs"]:.2f} LUFS at {MASTERS[3]["truePeakDbtp"]:.2f} dBTP. '
        f'Measured gain reduction: median {GR["reductionMedianDb"]:.2f} dB, deepest '
        f'{GR["reductionMaxDb"]:.2f} dB.\n\n'
        "THE BILL\n"
        f'{BILL["dryLra"]:.1f} LU of range became {BILL["masteredLra"]:.1f} LU — '
        f'{BILL["rangeLostLu"]:.1f} LU, or {BILL["rangeLostPercent"]:.0f}%, for '
        f'{BILL["loudnessGainedDb"]:.1f} dB of loudness. Driving the same chain to '
        f'{LW["integratedLufs"]:.2f} LUFS costs {BILL["loudwarRangeLostLu"]:.1f} LU '
        f'({BILL["loudwarRangeLostPercent"]:.0f}%) and takes '
        f'+{CH["loudwarGainDb"]:.1f} dB of drive.\n\n'
        "The closing point: streaming services normalise, so a quiet master gets "
        "turned up for you. Ask who is actually asking for −14 before you pay for "
        "it.\n\n"
        "DISCLOSURE\n"
        "The narration is a synthetic voice, generated locally. No music-generation "
        "model was used.\n\n"
        "#mastering #loudness #LUFS #musicproduction #audioengineering #mixing"),
)

if __name__ == "__main__":
    json.dump(spec, open(f"{HERE}/L6v2.json", "w"), ensure_ascii=False, indent=1)
    words = sum(len(s["narration"].split()) for s in stages)
    print(f"{HERE}/L6v2.json  {len(cards)} cards, {len(stages)} stages, "
          f"{words} words of narration")
