#!/usr/bin/env python3
"""Emit the rebuilt "Mono Your Bass" lesson's spec for shortsmith.py.

Written as code rather than hand-typed JSON for the same reason the compressor
lesson is: every number on a CARD is injected from MEASUREMENTS.json, so a
figure cannot drift from the file it was measured into, because it is never
typed twice.

⚠ THE NARRATION IS DIFFERENT, AND IT IS THE RISKY HALF. Numbers must be SPELLED
OUT in the script — the speech model reads digits unreliably and the content
gate compares a TRANSCRIPT against the script — so the spoken forms ARE typed by
hand. `check()` below therefore asserts every spoken figure against the measured
one at build time, and refuses to emit a spec whose words and measurements have
drifted apart. That check is the only thing standing between "the film says
fifteen decibels" and "the render measured fifteen decibels".

⚠ EVERY NUMERIC factCheck CARRIES ITS DIGIT SPELLING. The script spells numbers
out because the speech model reads digits badly; Whisper then writes them BACK
as digits. MEASURED here: a verbatim, perfect take of "about twelve
milliseconds" was rejected eight times because the gate only accepted the word
form. The gate is a hard requirement on the number being PRESENT — the list
loosens which spelling counts, never whether it has to be there.

⚠ Paths are absolute. assemble.py resolves a relative shot against its --shots
root, which is the OUT dir, not this one.
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
S, A = f"{HERE}/shots", f"{HERE}/audio"

FOLD = M["fold_60_110_dbfs"]
LOSS = M["fold_loss_vs_0ms_db"]
LAP = M["laptop_band"]
NOTES = {round(r["hz"], 2): r for r in M["per_note_fundamental_fold_db"]}
HARM = {r["n"]: r for r in M["e2_harmonics"]}
NULLS = M["comb_nulls_hz_6ms"]
CHART = M["_chart"]


def check(spoken, measured, tol, what):
    """Refuse to build if a spoken number has drifted from the measured one."""
    if abs(spoken - measured) > tol:
        sys.exit(f"SPEC REFUSES TO BUILD — {what}: the narration says {spoken} "
                 f"but MEASUREMENTS.json says {measured:.4f}")


# every figure the voice says, checked against the file it came from
check(-14.98, LOSS["6"], 0.02, "the 6 ms fold loss, 60-110 Hz")
check(-3.44, LOSS["15"], 0.02, "the 15 ms fold loss")
check(-3.20, LAP["hp200_full_loss_db"]["6"], 0.02, "the above-200 Hz loss")
check(83.3, NULLS[0], 0.1, "the first null")
check(250.0, NULLS[1], 0.1, "the second null")
check(416.7, NULLS[2], 0.1, "the third null")
check(-35.0, NOTES[82.41]["measured_db"], 0.15, "E2's fundamental")
check(-2.1, NOTES[130.81]["measured_db"], 0.15, "C3's fundamental")
check(-2.9, NOTES[41.2]["measured_db"], 0.15, "E1's fundamental")
check(-25.6, HARM[3]["measured_db"], 0.15, "E2's third harmonic")
check(-21.2, HARM[5]["measured_db"], 0.15, "E2's fifth harmonic")
check(0.03, HARM[2]["measured_db"], 0.05, "E2's second harmonic")
check(-31.888, M["left_channel_rms_dbfs"]["6"], 0.005, "the left-channel control")
check(6.0, M["offset_measured_ms"]["6"], 0.01, "the measured 6 ms offset")
check(15.0, M["offset_measured_ms"]["15"], 0.01, "the measured 15 ms offset")
check(47, M["material"]["notes"], 0, "the note count")
check(6.2, M["six_vs_fifteen"]["low_40_130_db"], 0.05, "6 ms vs 15 ms, low band")
check(0.3, M["six_vs_fifteen"]["hp200_db"], 0.05, "6 ms vs 15 ms, above 200 Hz")

sp = str.upper

# ------------------------------------------------------------------- cards
cards = [
  dict(type="statement", size=74, y=250,                                    # 0
       lines=["A WIDE BASS CAN LOSE", "A THIRD OF ITSELF", "ON THE WAY TO A PHONE."],
       sub=["Nothing here is an opinion.",
            "Every number was predicted first, then measured off the render."]),
  dict(type="list", title=sp("where your music gets summed to mono"), step=88,  # 1
       items=[["a phone", "one speaker, so one signal"],
              ["a Bluetooth speaker", "the same"],
              ["a club rig", "the low end is folded to mono on purpose", "hot"],
              ["a shop, a cafe", "ceiling speakers, wired together"],
              ["standing off to one side", "close enough to it"]]),
  dict(type="list", title=sp("three words, in plain English"), step=104,     # 2
       items=[["summing", "adding the left and right signals into one"],
              ["cancellation", "a peak meeting a trough, so they subtract", "hot"],
              ["comb filter", "what that does across the whole spectrum"]]),
  dict(type="list", title=sp("the experiment"), step=88,                     # 3
       items=[["one bass line", f'{M["material"]["notes"]} notes, eight bars, written by hand'],
              ["two tracks", "the identical part, hard left and hard right"],
              ["no plug-ins", "no widener, no reverb, nothing"],
              ["the only change", "the right-hand notes move a few ms late", "hot"]]),
  dict(type="bignumber", label=sp("summed to mono, 60 to 110 hertz"),        # 4
       value=f'{LOSS["6"]:.2f}', unit=sp("db gone"), size=180,
       notes=[f'no offset {FOLD["0"]:.2f} dB   ·   six milliseconds late {FOLD["6"]:.2f} dB',
              'the left channel is untouched in both — this is purely the summing',
              'and the delay was measured back out of the audio: '
              f'{M["offset_measured_ms"]["6"]:.1f} ms, exactly as asked']),
  dict(type="list", title=sp("the prediction, before any render"), step=92,  # 5
       items=[["the formula", "every frequency times the cosine of pi f tau"],
              ["at six ms, dead at", f'{NULLS[0]:g} Hz, then {NULLS[1]:g}, '
                                     f'then {NULLS[2]:g}, forever', "hot"],
              ["untouched at", f'{2*NULLS[0]:.0f} Hz, {2*NULLS[1]:.0f} Hz, '
                               f'{2*NULLS[2]:.0f} Hz'],
              ["E2 is", f'{NOTES[82.41]["hz"]:.2f} Hz — sitting on the first one', "hot"]]),
  dict(type="statement", size=96, y=430, rule=False,                        # 6
       lines=["NO OFFSET"], sub=["both tracks land at the same instant"]),
  dict(type="statement", size=96, y=430, rule=False,                        # 7
       lines=["SIX MILLISECONDS LATE"], sub=["one track only — nothing else changed"]),
  dict(type="statement", size=96, y=430, rule=False,                        # 8
       lines=["FIFTEEN MILLISECONDS LATE"], sub=["two and a half times the delay"]),
  dict(type="bignumber", label=sp("fifteen milliseconds, same band"),        # 9
       value=f'{LOSS["15"]:.2f}', unit=sp("db gone"), size=180,
       notes=[f'against {LOSS["6"]:.2f} dB at six milliseconds',
              'a bigger delay is not a worse delay — the notches simply move',
              'how much damage a delay does is a property of the delay AND the music',
              f'⚠ this pair is a BASS difference: {M["six_vs_fifteen"]["low_40_130_db"]:.1f} dB apart '
              f'below 130 Hz, {M["six_vs_fifteen"]["hp200_db"]:.2f} dB above 200 Hz']),
  dict(type="statement", size=62, y=330,                                     # 10
       lines=["MOST OF THIS LIVES BELOW", "ONE HUNDRED HERTZ."],
       sub=["Headphones or a real speaker will show you all of it.",
            "Laptop speakers will show you about three decibels of it.",
            "That is why the charts are measured and on screen —",
            "the lesson does not depend on your speakers."]),
  dict(type="list", title=sp("the controls"), step=96,                       # 11
       items=[["the left channel",
               f'{M["left_channel_rms_dbfs"]["0"]:.2f} dB in all three renders — identical'],
              ["the delay itself",
               f'measured back out by cross-correlation: '
               f'{M["offset_measured_ms"]["0"]:.0f}, {M["offset_measured_ms"]["6"]:.0f} '
               f'and {M["offset_measured_ms"]["15"]:.0f} ms', "hot"],
              ["predicted vs measured",
               "nine notes, agreeing to about a tenth of a decibel"]]),
  dict(type="list", title=sp("what to actually do"), step=96,                # 12
       items=[["below 120 Hz", "one source, centred. Not doubled, not delayed.", "hot"],
              ["widen the harmonics", "never the fundamental"],
              ["be suspicious", "of any doubling of a low part"],
              ["check", "sum to mono for ten seconds before you call it done", "hot"]]),
  dict(type="closing", size=58, y=560,                                       # 13
       lines=["Built and measured in DAW Pro.",
              "The build script, the measurements and the charts",
              "are all reproducible."],
       kicker="Widen the harmonics. Keep the fundamental single."),
]

# ------------------------------------------------------------------ shots
CHART_COMB = f"{S}/chart-comb.png"
CHART_NOTE = f"{S}/chart-pernote.png"
CHART_HARM = f"{S}/chart-harmonics.png"
CHART_OFFS = f"{S}/chart-offsets.png"
CHART_AUD = f"{S}/chart-audibility.png"
# ⚠ 08's TALK beat must show the picture the narration DESCRIBES. The stage
# plays the foldchart burst, but the words start over the still — pointing them
# at the SPECTRUM chart made the voice describe a picture that was not on
# screen. bursts.py copies the burst's LAST frame here after every render;
# never reference bursts/foldchart/f####.png directly, that dir is wiped.
FOLD_FINAL = f"{S}/foldchart-final.png"
ARRANGE, ROLL, MIXER = f"{S}/arrange.png", f"{S}/roll.png", f"{S}/mixer.png"
# a cut into the two channel strips' PAN readouts — "PAN L100" and "PAN R100"
# are the whole setup in one picture, and at full frame they are 12 px tall.
PANZOOM = {"path": MIXER, "zoom": [0.012, 0.400, 0.205, 0.092]}
# and into the master strip's MONO SAFETY meter, at rest and while playing
METER0 = {"path": f"{S}/phase0-a.png", "zoom": [0.860, 0.690, 0.125, 0.200]}
METER6 = {"path": f"{S}/phase6-a.png", "zoom": [0.860, 0.690, 0.125, 0.200]}

# ----------------------------------------------------------------- stages
stages = [
  dict(id="00-open", shots=[0, ARRANGE], cut=4.6, brandCheck="DAW Pro",
       narration=(
         "Your bass can sound enormous on headphones, and then lose a third of "
         "itself the moment somebody plays it through a phone, or a club rig, or "
         "the ceiling speakers in a shop. This lesson is about why that happens, "
         "how to measure exactly how much you are losing, and what to do about "
         "it. It is built and measured inside DAW Pro, and nothing in it is an "
         "opinion: every number was predicted from first principles before "
         "anything was rendered, then measured off the render, and both go on "
         "the screen together. One warning up front, because it is the honest "
         "thing to say. Most of what this lesson is about lives at the very "
         "bottom of the spectrum, and small speakers barely reproduce it. On a "
         "laptop you will see this much better than you will hear it, so the "
         "pictures are doing the work.")),

  dict(id="01-what-is-mono", shots=[1], cut=5.4,
       narration=(
         "Start from the beginning, in case this is new. A stereo recording is "
         "two separate signals: one for the left speaker and one for the right. "
         "Summing to mono means adding those two signals together into a single "
         "one, and playing that out of everything. It is not rare, and it is not "
         "an edge case. A phone speaker is mono. A single Bluetooth speaker is "
         "mono. Most large club systems deliberately fold the low end to mono, "
         "because a bass note spread across two distant subwoofers is a mess. A "
         "shop or a cafe with speakers in the ceiling is usually mono. And a "
         "listener standing off to one side of a pair of speakers is hearing "
         "something close to it. So mono is not a fallback you can ignore. It is "
         "a normal, common way for your music to reach somebody.")),

  dict(id="02-cancellation", shots=[2], cut=6.0,
       factCheck=[["twelve milliseconds", "12 milliseconds"]],
       narration=(
         "Here is the part that surprises people. Adding two signals together "
         "does not always make them louder. If the two are identical, they add "
         "up and you get twice the level, which is what you would expect. But if "
         "one of them is delayed, even by a very small amount, then at some "
         "frequencies the peaks of one arrive at the same moment as the troughs "
         "of the other, and instead of adding they subtract. That is called "
         "phase cancellation. And because a delay affects every frequency "
         "differently, what it does across the whole spectrum is a repeating "
         "pattern of holes, which is called a comb filter, because a graph of it "
         "looks like the teeth of a comb. This matters far more for bass than "
         "for anything else, for one simple reason. Bass notes are long, slow "
         "waves. A single cycle of a low E takes about twelve milliseconds. So a "
         "delay of a few milliseconds is already a large fraction of a whole "
         "cycle down there, while up in the treble the same delay is many whole "
         "cycles and it averages out.")),

  dict(id="03-setup", shots=[3, ARRANGE, ROLL, PANZOOM], cut=4.8,
       factCheck=[["forty seven", "47"], ["eight bars", "8 bars"]],
       narration=(
         "So here is the experiment, built in the app rather than described. One "
         "bass line: forty seven notes, eight bars, written by hand, nothing "
         "sampled and nothing generated. Two instrument tracks playing that "
         "identical part, one panned hard left and one panned hard right — you "
         "can see that on the mixer, pan left one hundred and pan right one "
         "hundred. There is no widening plug-in, no reverb, and no effect of any "
         "kind anywhere in the project. The only thing that changes between "
         "renders is that the notes on the right-hand track get moved a few "
         "milliseconds later. That is not an artificial trick, by the way. "
         "Nudging one copy of a part slightly late is exactly what a lot of "
         "stereo widening does underneath, and it is also what happens by "
         "accident whenever a doubled part is not perfectly in time.")),

  dict(id="04-mechanism", shots=[2, PANZOOM], cut=5.0,
       loop=f"{A}/mech.wav", burst="mechanism", playMax=18.2,
       normalize=False, bedEligible=False,
       factCheck=[["eighty two", "82"], ["six milliseconds", "6 milliseconds"]],
       narration=(
         "Before any measurement, look at the mechanism itself, because this is "
         "much easier to see than to hear. In a moment you will see two waves. "
         "The blue one is the left channel and the violet one is the right, and "
         "the thick green line is their sum — what a mono speaker actually "
         "plays. At first the delay is zero, the two copies sit exactly on top "
         "of each other, and the sum is bigger than either one on its own. Then "
         "the right channel slides six milliseconds late, and you should watch "
         "the green line rather than the other two. The note being drawn is an E "
         "two, at eighty two hertz, and six milliseconds is almost exactly half "
         "of one of its cycles, so every peak now meets a trough. At the very "
         "end nothing changes except the note itself: the same six milliseconds "
         "on an E one, one octave lower, and most of the sum comes straight "
         "back. Underneath you are hearing the two renders, no offset first and "
         "six milliseconds late second.")),

  dict(id="05-predict", shots=[5], cut=5.4,
       factCheck=[["eighty three", "83"], ["two hundred and fifty", "250"]],
       narration=(
         "There is a formula for this and it is short enough to say out loud. "
         "When you add a signal to a copy of itself delayed by some amount of "
         "time, every frequency gets multiplied by the cosine of pi, times the "
         "frequency, times the delay. What that means in practice is that there "
         "are particular frequencies where the multiplier is zero — where the "
         "sound is simply gone — and they repeat, evenly spaced, all the way up "
         "the spectrum. At a delay of six milliseconds, the first dead frequency "
         "is at eighty three hertz. The next is at two hundred and fifty. Then "
         "four hundred and seventeen, and so on. That first one is the problem, "
         "because an E two on a bass guitar is eighty two point four hertz. It "
         "is sitting almost exactly in the hole.")),

  dict(id="06-listen", shots=[6, METER0, METER6], cut=4.4,
       loop=f"{A}/ab6.wav", burst="meter6", normalize=False, playMax=8.2,
       ab=dict(before=f"{A}/ab0.wav", beforeBurst="meter0", cycles=2, seconds=8.0),
       factCheck=[["plus one", "plus 1", "+1"], ["not loudness matched"]],
       narration=(
         "So let us listen to it. The same eight seconds twice, both summed to "
         "mono. The first has no offset at all. The second has the right-hand "
         "track six milliseconds late. Same notes, same instrument, same "
         "performance, same gain. And that last point is deliberate: these two "
         "are not loudness matched, because the difference in level is the "
         "entire lesson. One single gain was applied to both of them, so what "
         "you hear is the real relationship. On screen while it plays is the "
         "app's own mono safety meter, on the master strip. It reads plus one "
         "point zero zero when the two channels are identical, and it swings "
         "down into the red when they start to cancel each other.")),

  dict(id="07-comb", shots=[CHART_COMB], cut=6.0,
       factCheck=[["divided by"]],
       narration=(
         "This is what the summing actually did, measured across the whole "
         "spectrum. The bright line is one render divided by the other: the six "
         "millisecond mono fold, divided by the no offset mono fold. The dashed "
         "grey line behind it is the prediction from that formula, worked out "
         "before either file existed. They lie on top of each other, which is "
         "the point of doing it this way round. Now look at the shape, because "
         "the shape is the surprise. This is not a filter that turns the bass "
         "down. It is a row of very narrow notches. In between the notches, "
         "nothing at all is lost. That is what a comb filter is, and it is why "
         "the damage depends so completely on which note you happen to be "
         "playing at the time.")),

  dict(id="08-chart", shots=[FOLD_FINAL, 4], cut=5.0,
       loop=f"{A}/chartaudio.wav", burst="foldchart", playMax=18.5,
       normalize=False, bedEligible=False,
       factCheck=[["six decibels", "6 decibels", "6 dB"], ["shaded"]],
       narration=(
         "Which brings us to the part that is genuinely hard to hear, so here it "
         "is drawn instead. This chart is the level of the bass, between forty "
         "and one hundred and thirty hertz, across seven seconds of that same "
         "passage, measured off both renders. The pale line is the version with "
         "no offset. The red line is the six millisecond version. The shaded "
         "bars are not chosen by eye — they are every window in which the two "
         "versions differ by more than six decibels, worked out from the "
         "measurements themselves. A playhead sweeps across at real speed while "
         "you hear each version in turn, so when the playhead is inside a shaded "
         "bar, that is the moment to listen. And notice what the picture says: "
         "it is not that everything got quieter. Some notes are untouched and "
         "others fall off a cliff.")),

  dict(id="09-pernote", shots=[CHART_NOTE], cut=6.0,
       factCheck=[["thirty five", "35"], ["one octave apart"]],
       narration=(
         "Here is the same thing note by note. Nine different notes, one single "
         "delay, and the fundamental of each one measured before and after the "
         "fold to mono. The dark bars are the predictions and the bright bars "
         "are the measurements, and they agree to about a tenth of a decibel "
         "across all nine of them. Now look at the two ends of the chart. C "
         "three, at a hundred and thirty one hertz, loses about two decibels, "
         "which is nothing. E two, at eighty two hertz, loses thirty five. Same "
         "track, same delay, same everything, and a thirty three decibel spread "
         "between the best case and the worst. And here is the part worth "
         "remembering. E one and E two are the same note, one octave apart. One "
         "of them is destroyed, and the other one comes through almost "
         "untouched.")),

  dict(id="10-harmonics", shots=[CHART_HARM], cut=6.0,
       factCheck=[["twenty six", "26"], ["hollow"]],
       narration=(
         "It gets more interesting if you take that one bad note apart. A bass "
         "note is not a single frequency. It is a fundamental, plus a stack of "
         "harmonics above it at two times, three times, four times that "
         "frequency, and those harmonics are most of what a small speaker "
         "actually reproduces. So here is that E two, harmonic by harmonic. The "
         "odd numbered ones land in the notches and disappear: the third "
         "harmonic loses twenty six decibels and the fifth loses twenty one. The "
         "even numbered ones land exactly between the notches and do not move at "
         "all — the second harmonic came back at three hundredths of a decibel, "
         "which is nothing. So the note does not simply get quieter. It gets "
         "hollow. Every other piece of it has been removed, and that change of "
         "character is something you can hear on a small speaker even when the "
         "level change down at the fundamental is invisible to it.")),

  dict(id="11-counter", shots=[8, 9, CHART_OFFS], cut=5.0,
       loop=f"{A}/ab15.wav", normalize=False, playMax=8.2,
       ab=dict(before=f"{A}/ab6.wav", beforeShots=[7], afterShots=[8],
               cycles=2, seconds=8.0),
       factCheck=[["three point four", "3.4"], ["two and a half", "2.5"],
                  ["three tenths", "3 tenths"],
                  # ⚠ this one is not a number check, it is a CONTENT check: a
                  # take came back saying "Since milliseconds is bad" for "If
                  # six milliseconds is bad", at a similarity score of 0.96.
                  ["six milliseconds", "6 milliseconds"]],
       narration=(
         "Now the result that catches everybody out, including me. If six "
         "milliseconds is bad, then fifteen milliseconds ought to be worse. It "
         "is not. Fifteen is two and a half times the delay, and in the same "
         "band it does less than a quarter of the damage: three point four "
         "decibels lost, against almost fifteen at six milliseconds. The reason "
         "is that the notches move. Making the delay longer does not make the "
         "notches deeper, it packs them closer together, and all that matters is "
         "where they land relative to the notes you are actually playing. So the "
         "amount of harm a delay does is not a property of the delay. It is a "
         "property of the delay and the music together. Listen to the two of "
         "them against each other now: six milliseconds first, then fifteen. "
         "And a warning about this one in particular, because it would be easy "
         "to leave it out. Almost all of the difference between these two is "
         "below one hundred hertz. Measured above two hundred hertz, where a "
         "laptop speaker actually works, they are three tenths of a decibel "
         "apart, which is nothing at all — on a small speaker they will simply "
         "sound the same. On headphones they are about six decibels apart in "
         "the bass and the difference is obvious. So if this pair sounds "
         "identical to you, that is the measurement, not your ears.")),

  dict(id="12-audibility", shots=[CHART_AUD, 10], cut=6.0,
       factCheck=[["three point two", "3.2"],
                  ["two hundred hertz", "200 hertz", "200 Hz", "200Hz"]],
       narration=(
         "Now let us be honest about how much of this you can hear right now, on "
         "whatever you happen to be listening on. In the sixty to one hundred "
         "and ten hertz band, the six millisecond version loses almost fifteen "
         "decibels, and fifteen decibels is enormous. But a laptop speaker is "
         "physically too small to move much air below about two hundred hertz. "
         "So measure only the part above two hundred hertz — roughly what a "
         "laptop actually puts into the room — and the same two files differ by "
         "three point two decibels. That is a real difference, and it is above "
         "the level people can reliably notice, but it is nothing like fifteen. "
         "So if you are on laptop speakers and those two versions sounded fairly "
         "similar, you were not imagining it, and there is nothing wrong with "
         "your ears or your speakers. Headphones or a proper monitor will show "
         "you the whole thing. The charts are here so that the lesson does not "
         "depend on which of those you have.")),

  dict(id="13-controls", shots=[11], cut=6.0,
       factCheck=[["identical"], ["cross"]],
       narration=(
         "Two controls, because a measurement without a control is just a claim. "
         "The first one is the left channel. Across all three renders it "
         "measures minus thirty one point eight nine decibels in that band, "
         "identical to the second decimal place. Neither channel was ever "
         "touched, and neither was made quieter. Everything you have seen is "
         "purely what happens when the two are added together. The second "
         "control is the delay itself. It was applied by moving notes rather "
         "than by a plug-in, so it was measured back out of the finished audio "
         "by cross correlating the left channel against the right. It came back "
         "at exactly zero, six, and fifteen milliseconds. The experiment did the "
         "thing it says it did.")),

  dict(id="14-what-to-do", shots=[12, PANZOOM, METER6], cut=5.0,
       factCheck=[["one hundred and twenty", "120"]],
       narration=(
         "So what do you actually do about all of this. Three things. First, "
         "keep everything below roughly one hundred and twenty hertz centred and "
         "single: one source, in the middle, not doubled and not delayed. If you "
         "want a bass to feel wide, widen the harmonics above that and leave the "
         "fundamental alone, because the fundamental is the part that cancels. "
         "Second, be suspicious of any doubling of a low part at all — a second "
         "take, a copied track, a short delay, a chorus, a stereo widener. "
         "Anything that makes two versions of the same low note arrive at "
         "slightly different times is doing exactly what you have just watched. "
         "And third, check, rather than trusting it. The mono safety meter sits "
         "on the master strip, and summing your mix to mono for ten seconds "
         "before you call it finished costs nothing and tells you straight "
         "away.")),

  dict(id="15-close", shots=[13], cut=5.0, brandCheck="DAW Pro",
       narration=(
         "Everything in this video was built and rendered in DAW Pro and "
         "measured off those renders, with the prediction written down first "
         "every time. The build script, the measurements and the charts are all "
         "reproducible. If you take one thing away, take this: widen the "
         "harmonics, and keep the fundamental single. Thanks for watching.")),
]

spec = dict(
    id="L8v2", theme="mastering", size="1920x1080",
    # ⚠ DELIBERATELY NOT the shipped film's name. --finalize is not run for this
    # rebuild, but if it ever is, it must not overwrite the published file
    # before the user has watched this one.
    filename="DAW Pro Lesson 8 - Mono Your Bass (rebuild)",
    title="Your bass sounds huge. Summed to mono it is fifteen decibels quieter.",
    playlist="Mixing, measured", categoryId="27",
    cut=5.0, playMax=9.0, introSeconds=4, outroSeconds=3, meter="br",
    bursts=f"{HERE}/bursts",
    cards=cards, stages=stages,
    tags=["mixing", "bass", "mono compatibility", "phase", "comb filtering",
          "music production", "mastering", "phase cancellation"],
    description=(
        "A wide bass sounds enormous on headphones and loses a chunk of itself the "
        "moment anything sums it to mono — a club rig, a phone speaker, a shop "
        "ceiling. This measures exactly how much, and shows the mechanism rather "
        "than asserting it.\n\n"
        "THE SETUP\n"
        f'One bass line, {M["material"]["notes"]} notes, eight bars, written by hand. '
        "Two instrument tracks playing the identical part, hard left and hard right. "
        "No widener and no plug-in of any kind: the only change between renders is "
        "nudging one track a few milliseconds late, which is what most widening "
        "tricks do underneath.\n\n"
        "FOLDED TO MONO, 60-110 Hz\n"
        f'· no offset: {FOLD["0"]:.2f} dB (the baseline)\n'
        f'· 6 ms offset: {FOLD["6"]:.2f} dB — {abs(LOSS["6"]):.2f} dB gone\n'
        f'· 15 ms offset: {FOLD["15"]:.2f} dB — only {abs(LOSS["15"]):.2f} dB gone\n\n'
        "PREDICTED, THEN MEASURED\n"
        "Summing a signal with a copy of itself delayed by tau multiplies every "
        "frequency by |cos(pi f tau)|. At 6 ms that is a null at "
        f'{NULLS[0]:g} Hz, {NULLS[1]:g} Hz, {NULLS[2]:g} Hz… Nine notes were '
        "predicted from that formula before anything was rendered and then measured "
        "off the render; they agree to about a tenth of a decibel. E2 at 82.41 Hz "
        f'sits on the first null and loses {abs(NOTES[82.41]["measured_db"]):.1f} dB. '
        f'E1 — the same note one octave down — loses {abs(NOTES[41.2]["measured_db"]):.1f} dB.\n\n'
        "ONE NOTE, HARMONIC BY HARMONIC\n"
        f'E2\'s odd harmonics land in the notches: the 3rd loses {abs(HARM[3]["measured_db"]):.1f} dB, '
        f'the 5th {abs(HARM[5]["measured_db"]):.1f} dB. The even ones land between them and '
        f'move by {abs(HARM[2]["measured_db"]):.2f} dB. The note does not get quieter, it gets hollow.\n\n'
        "THE CONTROLS\n"
        f'The left channel measures {M["left_channel_rms_dbfs"]["0"]:.2f} dB in all three '
        "renders, identical to the decimal. The offset itself was measured back out of "
        "the audio by cross-correlation: "
        f'{M["offset_measured_ms"]["0"]:.0f}, {M["offset_measured_ms"]["6"]:.0f} and '
        f'{M["offset_measured_ms"]["15"]:.0f} ms, exactly as asked.\n\n'
        "HOW MUCH YOU CAN HEAR\n"
        "Said plainly rather than assumed: above 200 Hz — roughly what a laptop "
        f'speaker radiates — the same two files differ by {abs(LAP["hp200_full_loss_db"]["6"]):.2f} dB, '
        "not fifteen. Headphones or a real speaker show the whole thing. The charts "
        "are measured off the renders so the lesson does not depend on your "
        "speakers.\n\n"
        "WHAT TO DO\n"
        "Keep everything below roughly 120 Hz centred and single. Widen the "
        "harmonics, never the fundamental. Sum to mono and check before calling a "
        "mix done.\n\n"
        "DISCLOSURE\n"
        "The narration is a synthetic voice, generated locally. No music-generation "
        "model was used.\n\n"
        "#mixing #bass #mono #musicproduction #audioengineering #mastering"),
)

if __name__ == "__main__":
    json.dump(spec, open(f"{HERE}/L8v2.json", "w"), ensure_ascii=False, indent=1)
    print(f"{HERE}/L8v2.json  {len(cards)} cards, {len(stages)} stages")
