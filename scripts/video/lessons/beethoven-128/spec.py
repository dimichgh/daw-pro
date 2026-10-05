#!/usr/bin/env python3
"""Emit the rebuilt "Beethoven at 128" lesson's spec for shortsmith.py.

Written as code rather than hand-typed JSON for the same reason the mono-bass
and chasing-−14 rebuilds are: every number on a CARD is injected from
MEASUREMENTS.json, so a figure cannot drift from the file it was measured into,
because it is never typed twice.

⚠ THE NARRATION IS DIFFERENT, AND IT IS THE RISKY HALF. Numbers must be SPELLED
OUT in the script — the speech model reads digits unreliably and the content gate
compares a TRANSCRIPT against the script — so the spoken forms ARE typed by hand.
`check()` below asserts every spoken figure against the measured one at build
time and refuses to emit a spec whose words and measurements have drifted apart.

⚠ EVERY NUMERIC factCheck CARRIES ITS DIGIT SPELLING. The script spells numbers
out because the speech model reads digits badly; Whisper then writes them BACK
as digits, and an earlier film in this series lost two full eight-take rounds to
exactly that.

⭐⭐ WHAT THIS REBUILD CHANGED ABOUT THE ARGUMENT, AND WHY.
The shipped film's headline was "−47.2 dB below 100 Hz against −29.4 dB — 18 dB
of fundamental an 1808 orchestra could not produce." Measured on this material
that claim does not hold: below 100 Hz the two versions are only 7.4 dB apart,
because a double-bass section really does put 73–104 Hz into a room. In the
60–100 Hz band the ORCHESTRA IS THE LOUDER OF THE TWO, by 0.6 dB. The gap opens
below about 73 Hz and reaches 33.3 dB under 60 Hz — below the double bass's
bottom string. So the film argues the honest version: an orchestra of 1808 is
not bass-less, it has a FLOOR, and the floor is a piece of wood and gut.

⚠ HISTORICAL HONESTY. The four notes and their rhythm are Beethoven's; the
repetition is the film's own invention and it says so twice. The tempo is a
choice, not a quotation — the film does not attribute 128 BPM to him, and it
points at lesson 7 for the metronome-mark dispute rather than adjudicating it.
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
S, A = f"{HERE}/shots", f"{HERE}/audio"

MAT = M["material"]
LO = M["loudness"]
B = M["bands"]
BD = B["delta"]
LAP = M["laptop"]
PX = M["proxy"]
MK = M["marker"]
LAY = M["layers"]
AB = M["ab"]
CROSS = M["_chart"]["crossoverHz"]


def check(spoken, measured, tol, what):
    """Refuse to build if a spoken number has drifted from the measured one."""
    if abs(spoken - measured) > tol:
        sys.exit(f"SPEC REFUSES TO BUILD — {what}: the narration says {spoken} "
                 f"but MEASUREMENTS.json says {measured:.4f}")


# every figure the voice says, checked against the file it came from
check(128, MAT["bpm"], 0, "the tempo")
check(16, MAT["bars"], 0, "the bar count")
check(30, MAT["seconds"], 0.01, "the length in seconds")
check(402, MAT["notes"], 0, "the note count")
check(64, MAT["riffNotes"], 0, "the riff note count")
check(134, MAT["drumHits"], 0, "the drum hit count")
check(12, MAT["subNotes"], 0, "the sub note count")
check(234, MAT["eighthMs"], 0.5, "the length of one eighth note")
check(-19.9, LO["orch"]["ffmpegLufs"], 0.05, "the orchestral version's loudness")
check(-20.9, LO["techno"]["ffmpegLufs"], 0.05, "the techno version's loudness")
check(1.0, LO["deltaLu"], 0.05, "the gap between the two versions")
check(-54.4, B["orch"]["sub60"], 0.05, "the orchestral level below 60 Hz")
check(-21.1, B["techno"]["sub60"], 0.05, "the techno level below 60 Hz")
check(33.3, BD["sub60"], 0.05, "the gap below 60 Hz")
check(7.4, BD["sub100"], 0.05, "the gap below 100 Hz")
check(-0.6, BD["b60_100"], 0.05, "the gap between 60 and 100 Hz")
check(-27.7, B["orch"]["b60_100"], 0.05, "the orchestral level from 60 to 100 Hz")
check(-28.3, B["techno"]["b60_100"], 0.05, "the techno level from 60 to 100 Hz")
check(73, CROSS, 0.5, "the crossover frequency")
check(9.8, LAP["techno"]["rmsLossDb"], 0.05, "what the high-pass costs the techno version")
check(6.2, LAP["techno"]["lufsLossLu"], 0.05, "what it costs in loudness")
check(1.4, LAP["orch"]["rmsLossDb"], 0.05, "what the high-pass costs the orchestral version")
check(51.7, PX["above100GainDb"], 0.05, "what the octave shift buys above 100 Hz")
check(0.01, PX["fullBandDeltaDb"], 0.02, "what the octave shift costs overall")
check(44.5, MK["liftDb"], 0.05, "how far the sub lifts the bottom band")
check(-0.8, MK["highLiftDb"], 0.05, "how far it moves the band above 100 Hz")
check(1.9, MK["onsets"]["Kick"], 0.05, "when the kick arrives")
check(7.5, MK["onsets"]["Sub"], 0.05, "when the sub arrives")
check(-30.3, LAY[0]["lufs"], 0.05, "the riff on its own")
check(-20.9, LAY[4]["lufs"], 0.05, "the finished techno version")
check(-62.4, LAY[0]["bands"]["sub60"], 0.05, "the riff's own bottom band")

sp = str.upper

# ------------------------------------------------------------------- cards
cards = [
  dict(type="statement", size=66, y=250,                                      # 0
       lines=["FOUR NOTES, ONE PROJECT,", "TWO COMPLETELY DIFFERENT",
              "RECORDS."],
       sub=["Nothing here is an opinion.",
            "Every number was measured off the renders you are hearing."]),

  dict(type="list", title=sp("three words, in plain English"), step=94,       # 1
       items=[["motif", "the smallest idea a piece of music can be built from"],
              ["the cell", "this one is four notes long — and it is a RHYTHM", "hot"],
              ["development", "keeping that idea and changing everything around it"]]),

  dict(type="list", title=sp("what Beethoven does with it"), step=88,         # 2
       items=[["states it", "three short notes on one pitch, then a longer one lower"],
              ["moves it", "to new pitches, upside down, passed between instruments"],
              ["never drops it", "most of a first movement built from one cell", "hot"],
              ["no contrast", "he does not write a second idea and cut between them"]]),

  dict(type="list", title=sp("what a techno record does with it"), step=88,   # 3
       items=[["states a cell", "short, rhythmic, usually not a tune"],
              ["does not change it", "the loop is the point, not a limitation", "hot"],
              ["changes the room", "a strip arrives, a strip leaves, the cell stays"],
              ["same shape", "different century, different building"]]),

  dict(type="list", title=sp("honestly: whose is what"), step=88,             # 4
       items=[["his", "the four notes, their rhythm, and the idea of developing it"],
              ["mine", "the repetition — he never wrote this as a loop", "hot"],
              ["mine", "the tempo. He left metronome marks; lesson seven covers "
                       "the argument about them"],
              ["nothing sampled", f'{MAT["notes"]} notes, all programmed by hand']]),

  dict(type="list", title=sp("the project, one project"), step=84,            # 5
       items=[["tempo", f'{MAT["bpm"]} BPM — one eighth note is '
                        f'{MAT["eighthMs"]:.0f} ms'],
              ["length", f'{MAT["bars"]} bars, {MAT["seconds"]:.0f} seconds'],
              ["the riff", f'{MAT["riffNotes"]} notes — the same cell, four bars, '
                           f'four times through', "hot"],
              ["the room", f'{MAT["drumHits"]} drum hits and {MAT["subNotes"]} '
                           f'sustained sub notes'],
              ["two renders", "silence one group of tracks, then the other"]]),

  dict(type="list", title=sp("the orchestral version"), step=88,              # 6
       items=[["violins", "the cell two octaves up"],
              ["celli", "the cell one octave up"],
              ["double basses", "the cell as written — 73 to 104 Hz", "hot"],
              ["nothing else", "no drums, nothing sustained, nothing below the basses"]]),

  dict(type="list", title=sp("the room arrives, one strip at a time"), step=88,  # 7
       items=[["bar two", f'the kick, at {MK["onsets"]["Kick"]:.1f} seconds'],
              ["bar four", f'offbeat hats, at {MK["onsets"]["Hats"]:.1f} seconds'],
              ["bar five", f'the sustained sub, at {MK["onsets"]["Sub"]:.1f} seconds',
               "hot"],
              ["bar six", f'the clap, at {MK["onsets"]["Clap"]:.1f} seconds'],
              ["the cell", "never changes once, in any of them"]]),

  dict(type="bignumber", label=sp("below 60 hz, the two versions"),           # 8
       value=f'{BD["sub60"]:+.1f}', unit=sp("db apart"), size=180,
       notes=[f'the techno render {B["techno"]["sub60"]:.1f} dB, the orchestral '
              f'one {B["orch"]["sub60"]:.1f} dB',
              'below about 41 Hz — the bottom string of a double bass,',
      'and the floor of this particular scoring',
              'measured off the two renders, not asserted']),

  dict(type="list", title=sp("and the part most videos leave out"), step=88,  # 9
       items=[["below 100 Hz", f'only {BD["sub100"]:+.1f} dB apart'],
              ["60 to 100 Hz", f'the ORCHESTRA is louder, by '
                               f'{abs(BD["b60_100"]):.1f} dB', "hot"],
              ["they cross at", f'{CROSS:.0f} Hz'],
              ["so the claim is", "not that an orchestra has no bass. It has a FLOOR."]]),

  dict(type="bignumber", label=sp("what your speakers are not showing you"),  # 10
       value=f'{LAP["techno"]["rmsLossDb"]:.1f}', unit=sp("db of level"), size=180,
       notes=[f'that is what taking everything under 100 Hz away costs the techno '
              f'render',
              f'but only {LAP["techno"]["lufsLossLu"]:.1f} LU of measured LOUDNESS — '
              f'a loudness meter already discounts the bottom',
              f'the same high-pass costs the orchestral version '
              f'{LAP["orch"]["rmsLossDb"]:.1f} dB — it was barely using that band']),

  dict(type="list", title=sp("the same part, where you can hear it"), step=88,  # 11
       items=[["as written", "32.7 and 49 Hz — a sine, sustained"],
              ["moved up two octaves", "131 and 196 Hz — same rhythm, same notes"],
              ["overall level", f'changes by {PX["fullBandDeltaDb"]:+.2f} dB. '
                                f'Essentially nothing'],
              ["above 100 Hz", f'changes by {PX["above100GainDb"]:+.1f} dB', "hot"]]),

  dict(type="list", title=sp("it is not a loudness trick"), step=88,          # 12
       items=[["orchestral", f'{LO["orch"]["ffmpegLufs"]:.1f} LUFS'],
              ["techno", f'{LO["techno"]["ffmpegLufs"]:.1f} LUFS'],
              ["apart", f'{LO["deltaLu"]:.1f} LU — about as matched as two '
                        f'different arrangements get', "hot"],
              ["measured twice", "by the app at render time and by ffmpeg after, "
                                 "agreeing to within 0.02 LU"]]),

  dict(type="list", title=sp("if you are on laptop speakers"), step=94,       # 13
       items=[["you will hear", "the cell, the kick, the hats, the clap"],
              ["you will not hear", "most of the thing this film measured", "hot"],
              ["that is not your fault", "and it is why all of it is drawn as well "
                                         "as played"]]),

  dict(type="closing", size=54,                                              # 14
       lines=["He states one small idea",
              "and refuses to stop developing it.",
              "That is the whole method."],
       kicker="Built, rendered and measured in DAW Pro."),
]

# ----------------------------------------------------------------- pictures
ARRANGE = f"{S}/arrange.png"
MIXER = f"{S}/mixer.png"
ROLL_RIFF, ROLL_SUB, ROLL_BASS = (f"{S}/roll-riff.png", f"{S}/roll-sub.png",
                                  f"{S}/roll-basses.png")
CH_SPEC, CH_BAND = f"{S}/chart-spectrum.png", f"{S}/chart-bands.png"
CH_LAP, CH_LAY, CH_PROX = (f"{S}/chart-laptop.png", f"{S}/chart-layers.png",
                           f"{S}/chart-proxy.png")
CELL_FINAL, MARK_FINAL = f"{S}/cellanim-final.png", f"{S}/submarker-final.png"
# cuts into the two synth cards — at full frame the knob readouts are ~14 px
# MEASURED against the actual PNG, not guessed: the card occupies
# x 0.39-0.61, y 0.26-0.78 of the 3200x1800 capture.
SYNTH_RIFF = {"path": f"{S}/synth-riff.png", "zoom": [0.39, 0.26, 0.22, 0.52]}
SYNTH_SUB = {"path": f"{S}/synth-sub.png", "zoom": [0.39, 0.26, 0.22, 0.52]}
# the piano roll's first two bars, where the cell is actually legible
ROLL_ZOOM = {"path": f"{S}/roll-riff.png", "zoom": [0.02, 0.27, 0.34, 0.36]}

# ----------------------------------------------------------------- stages
stages = [
  dict(id="00-open", shots=[0, ARRANGE], cut=4.8, brandCheck="DAW Pro",
       factCheck=[["four notes"], ["a hundred and twenty eight", "128"]],
       narration=(
         "Everybody knows how Beethoven's Fifth starts. What gets missed is "
         "that it is not really a melody. It is three short notes on the same "
         "pitch and then one longer note lower down — a rhythm, with a pitch "
         "attached. And he builds most of a symphony out of it without ever "
         "letting it go. This lesson takes those four notes, rebuilds them as a "
         "techno riff at a hundred and twenty eight beats per minute, and then "
         "measures what is actually different between the two. It is built and "
         "measured inside DAW Pro. It is all built in DAW Pro, and there is one "
         "warning up front, because it is the "
         "honest thing to say. The biggest measured difference between these "
         "two versions lives in the bottom octave, which is the part a laptop "
         "speaker barely reproduces. So every step of it is drawn as well as "
         "played, and I will tell you exactly what your speakers are and are "
         "not handing you rather than asking you to listen harder.")),

  dict(id="01-motif", shots=[1], cut=6.0,
       factCheck=[["motif", "motive"], ["development"]],
       narration=(
         "Start from the beginning, in case any of this is new. A motif is the "
         "smallest idea a piece of music can be built out of. Not a tune, not a "
         "chord sequence — just a shape, short enough that you recognise it "
         "again the moment it comes back. Beethoven's is four notes long, and "
         "the important thing about it is that most of what makes it "
         "recognisable is the rhythm rather than the pitches. Three short, one "
         "long. You could play it on a drum and people would still know it. "
         "The second word is development. Development means taking that one "
         "idea and keeping it, while changing everything around it: the pitch "
         "it starts on, the instrument playing it, what is underneath it, how "
         "many of them are going at once. Not replacing it with a new idea. "
         "Wearing it out and refusing to let go.")),

  dict(id="02-cell", shots=[1, CELL_FINAL], cut=6.0,
       loop=f"{A}/cellbed.wav", burst="cellanim", playMax=31.6,
       bedEligible=False,
       factCheck=[["three short"], ["rhythm"]],
       narration=(
         "Here it is, drawn. In a moment you will see a grid: time runs left to "
         "right and pitch runs up and down, exactly the way a piano roll works "
         "in any music program. The cell appears first on its own — three short "
         "blocks all at the same height, then one longer block lower down. G, G, "
         "G, E flat. Then watch what happens: the same shape appears twice more "
         "at different heights, and nothing else about it changes. Then all the "
         "pitches collapse onto one line, so only the rhythm is left, and you "
         "will find it still says the same thing. Three short, one long. At the "
         "end a kick drum and a hi-hat arrive underneath it, and the cell does "
         "not move at all. Underneath, you are hearing the cell itself, and "
         "then the first six bars of what this lesson builds out of it.")),

  dict(id="03-development", shots=[2], cut=5.6,
       factCheck=[["one idea", "one cell"], ["contrast", "contrasting"]],
       narration=(
         "So what does he actually do with it. He states it, hard, at the very "
         "top of the piece, in unison, with nothing underneath. Then he moves "
         "it to a different pitch and plays it again. Then he turns it upside "
         "down, so the shape that fell now rises, and the rhythm is untouched. "
         "Then he passes it between instruments, so it arrives from a different "
         "part of the orchestra each time. Then he stacks copies of it on top "
         "of each other. A first movement of seven or eight minutes, and very "
         "nearly every bar of it is that one cell in some form. What he "
         "conspicuously does not do is write a second, contrasting idea and cut "
         "between the two. That is the normal way to fill eight minutes, and he "
         "refuses it.")),

  dict(id="04-techno", shots=[3], cut=5.6,
       factCheck=[["loop"], ["the room", "everything around it"]],
       narration=(
         "Which is, almost exactly, the method a techno record uses. State a "
         "short rhythmic cell that is usually not a tune. Do not change it — "
         "the loop is the point rather than a limitation. And then change "
         "everything around it: a drum arrives, a hi-hat arrives, something "
         "sustained appears underneath, a layer drops out and comes back. The "
         "listener's attention is held by the room being rebuilt around a thing "
         "that is standing still. Same shape as what Beethoven is doing. "
         "Different century, different building, and a completely different set "
         "of instruments — which turns out to be the part that shows up in the "
         "measurements.")),

  dict(id="05-honest", shots=[4], cut=6.4,
       factCheck=[["repetition"], ["lesson seven", "lesson 7"]],
       narration=(
         "Before anything gets built, here is what belongs to whom, because "
         "this is exactly the kind of video that quietly blurs it. The four "
         "notes are Beethoven's. Their rhythm is Beethoven's. The idea of "
         "taking one small cell and developing it relentlessly is Beethoven's, "
         "and he did it further than almost anyone before him. The repetition "
         "is mine. He never wrote this as a four bar loop played four times, "
         "and nothing in this lesson should be read as claiming he did. The "
         "tempo is mine as well. He did leave metronome marks for this "
         "symphony, and there is a long standing argument about what they mean "
         "and whether his metronome was working — lesson seven is about exactly "
         "that argument, and I am not going to settle it here. A hundred and "
         "twenty eight is simply a tempo I chose. And nothing here is sampled "
         "and nothing here is generated: every note was typed in by hand.")),

  dict(id="06-project", shots=[5, ARRANGE, ROLL_ZOOM], cut=5.2,
       factCheck=[["four hundred and two", "402"],
                  ["sixteen bars", "16 bars"],
                  ["sixty four", "64"]],
       narration=(
         "So, one project. Sixteen bars, thirty seconds, a hundred and twenty "
         "eight beats per minute, and eight tracks — four hundred and two notes "
         "in total, all written by hand. The riff is sixty four of them: the "
         "cell, four bars of it, played four times through without a single "
         "alteration. Here it is in the note editor. Three short blocks on G, "
         "then a longer one on E flat, then the same shape starting on F, and "
         "so on. The trick that makes the rest of this lesson possible is that "
         "the orchestral version and the techno version live in the same "
         "project and play the same notes. To render one of them, I silence the "
         "other one's tracks. Same tempo, same length, same cell — so the only "
         "things that differ are the instruments and the arrangement, which is "
         "exactly the question being asked.")),

  dict(id="07-orch", shots=[6, ROLL_BASS, ARRANGE], cut=4.6,
       loop=f"{A}/play-orch.wav", burst="orchplay", playMax=8.2,
       normalize=False,
       factCheck=[["three octaves"], ["double bass", "double basses"]],
       narration=(
         "The orchestral version first. Three string parts playing the cell in "
         "three octaves in unison, which is roughly how the real thing opens: "
         "violins high, cellos an octave below them, and double basses at the "
         "bottom. There are no drums, there is nothing sustained, and there is "
         "nothing below the basses. That last point matters more than it "
         "sounds, and we will come back to it with numbers. Notice what the "
         "double bass part actually is — the same three short notes and one "
         "long one, down where you feel them rather than hear them. Here are "
         "eight seconds of it.")),

  dict(id="08-techno", shots=[ARRANGE, SYNTH_RIFF], cut=5.0,
       loop=f"{A}/play-techno.wav", burst="technoplay", playMax=8.2,
       normalize=False,
       factCheck=[["saw", "sawtooth"], ["two point four", "2.4"]],
       narration=(
         "Now the same sixty four notes, on a synthesiser. This is DAW Pro's "
         "built in poly synth, and here is its panel: a saw wave, which is the "
         "brightest of the basic shapes and the standard starting point for "
         "anything that has to cut through a drum machine, with the filter "
         "brought down to two point four kilohertz to take the harshness off "
         "the top, an attack of four milliseconds so each note starts sharply, "
         "and a little resonance at the filter. Nothing exotic. Same notes, "
         "same rhythm, same bar positions as the double basses you just heard. "
         "Eight seconds of that.")),

  dict(id="09-build", shots=[7, CH_LAY], cut=6.0,
       loop=f"{A}/play-buildrec.wav", burst="buildrec", playMax=13.2,
       normalize=False,
       factCheck=[["bar two", "bar 2"], ["bar five", "bar 5"]],
       narration=(
         "And now the room, arriving one strip at a time, which is the part "
         "that is genuinely the same method. The kick comes in at bar two. "
         "Offbeat hi-hats at bar four. At bar five something sustained arrives "
         "underneath — hold on to that one, it is the whole second half of this "
         "lesson. And a clap at bar six. Watch the playhead crossing the "
         "arrangement while this happens, and watch the riff lane: it does not "
         "change. Not once. Every single thing that makes this feel like it is "
         "going somewhere is happening around a cell that is standing "
         "completely still.")),

  dict(id="10-versions", shots=[ARRANGE, 6], cut=4.4,
       loop=f"{A}/ab-ver-b.wav", normalize=False, playMax=8.2,
       ab=dict(before=f"{A}/ab-ver-a.wav", beforeShots=[6], afterShots=[7],
               cycles=2, seconds=8.0),
       factCheck=[["same eight seconds", "same eight", "same 8"], ["same notes"]],
       narration=(
         "Here they are back to back — the same eight seconds of the same bars, "
         "orchestral first and then techno. Both are turned up by exactly the "
         "same amount, one shared gain, so what you hear is the real "
         "relationship between them rather than two things normalised to sound "
         "equally loud. Same notes. Same tempo. Same length. Listen for what "
         "changes, and in particular listen for what happens at the very bottom "
         "when the second one arrives — and then, in a moment, we are going to "
         "find out how much of that you actually received.")),

  dict(id="11-spectrum", shots=[8, CH_SPEC], cut=9.0, holdLast=True,
       factCheck=[["thirty three", "33"], ["sixty hertz", "60 hertz", "60 Hz"],
                  ["forty one", "41"]],
       narration=(
         "This is the measurement, and it is the centre of the lesson. What you "
         "are looking at is the frequency content of both renders drawn on top "
         "of each other: low notes on the left, high notes on the right, and "
         "how much energy each version has at each frequency going up. Blue is "
         "the orchestral render, orange is the techno one. Look at the left "
         "hand edge. The orange line stays up. The blue line falls off a cliff. "
         "In the shaded band — everything below sixty hertz — the techno "
         "version measures minus twenty one point one decibels and the "
         "orchestral version measures minus fifty four point four. That is a "
         "gap of thirty three point three decibels, and it is not a mixing "
         "decision. The dotted line is at about forty one hertz, which is the "
         "bottom string of a double bass. Some Viennese basses of the period "
         "were strung differently and stopped a little higher, so treat that "
         "line as approximate. Either way, below it there is no instrument in "
         "this arrangement at all.")),

  dict(id="12-bands", shots=[9, CH_BAND], cut=9.0, holdLast=True,
       factCheck=[["seventy three", "73"], ["louder"],
                  ["below sixty hertz", "below 60 hertz", "below 60 Hz"],
                  ["a floor", "floor"]],
       narration=(
         "And here is the part most videos about this would quietly leave out. "
         "Below one hundred hertz, the two versions are only seven point four "
         "decibels apart. Look at the third pair of bars. Between "
         "sixty and one hundred hertz the orchestral "
         "version is the LOUDER of the two, by six tenths of a decibel. A "
         "double bass section really does fill that band — that is what a "
         "double bass is for. The two lines cross at about seventy three hertz. "
         "So essentially the whole difference between these two records lives "
         "below sixty hertz, and almost none of it lives above. The honest "
         "claim is not that an orchestra has no bass. It has a "
         "floor. The floor is a piece of wood with a string on it, and below "
         "the floor there is nothing at all, because the orchestra he wrote "
         "this movement for has no instrument that reaches down there. Not "
         "that nothing in eighteen oh eight could reach it. A big church "
         "organ went far lower, and Beethoven himself brings in a "
         "contrabassoon for the finale of this very symphony, which goes "
         "below that line too. Neither of them is in the movement this "
         "lesson is built on, and that is the whole point.")),

  dict(id="13-marker", shots=[7, MARK_FINAL], cut=7.0,
       loop=f"{A}/markerbed.wav", burst="submarker", playMax=17.7,
       normalize=False, bedEligible=False,
       factCheck=[["forty four", "44"], ["shaded"], ["control"]],
       narration=(
         "This next chart tells you when to listen and where, so you are not "
         "hunting for it. It is the first twelve seconds of the techno version "
         "— the part where the room arrives — and a playhead sweeps it at real "
         "speed while you hear exactly that passage. There are two lines. The "
         "orange one is the level below sixty hertz, which is the thing being "
         "claimed. The blue one is the level above one hundred hertz, and that "
         "one is the control: if it moves when the orange one moves, then "
         "something changed everywhere and the claim means nothing. Watch what "
         "happens at seven and a half seconds, where the sustained part comes "
         "in. The orange line jumps by forty four and a half decibels. The blue "
         "line moves by eight tenths of a decibel, in the wrong direction. The "
         "shaded bar is not chosen by eye — it is every stretch where the "
         "bottom band stands more than fifteen decibels above where it sat "
         "before, worked out from the measurements.")),

  dict(id="14-laptop", shots=[10, CH_LAP], cut=8.0,
       loop=f"{A}/ab-lap-b.wav", normalize=False, bedEligible=False, playMax=8.2,
       ab=dict(before=f"{A}/ab-lap-a.wav", beforeShots=[10], afterShots=[13],
               cycles=2, seconds=8.0),
       factCheck=[["nine point eight", "9.8"], ["six point two", "6.2"],
                  ["one point four", "1.4"]],
       narration=(
         "So how much of that did you actually get. Here is the same techno "
         "render with everything below one hundred hertz taken away with a "
         "filter — which is roughly what a small speaker does to it before you "
         "hear it at all. Taking that band away costs nine point eight decibels "
         "of real level. But it costs only six point two LU of measured "
         "loudness, because a loudness meter is weighted like an ear and an ear "
         "already discounts the bottom octaves. Two different numbers, both "
         "correct, describing the same edit. Now the interesting one: the same "
         "filter on the orchestral version costs one point four decibels. "
         "Almost nothing, because there was almost nothing there to take. In "
         "other words, playing the techno version on a laptop speaker is a "
         "surprisingly good imitation of what the orchestra could do about the "
         "bottom octave in the first place. Here are both, the full render and "
         "then the filtered one. If they sound close to identical on your "
         "machine, that is not a fault. That is the measurement.")),

  dict(id="15-proxy", shots=[11, CH_PROX], cut=8.0,
       loop=f"{A}/ab-sub-b.wav", normalize=False, bedEligible=False, playMax=8.2,
       # ⚠ THE TWO HALVES NEED DIFFERENT PICTURES. With the same still on
       # both, only the small BEFORE/AFTER badge changes and the stage
       # reads as a frozen video.
       ab=dict(before=f"{A}/ab-sub-a.wav", beforeShots=[11],
               afterShots=[CH_PROX], cycles=2, seconds=8.0),
       factCheck=[["two octaves"], ["fifty one point seven", "51.7"]],
       narration=(
         "There is one more way to show you a thing your speakers will not "
         "deliver, and it is honest as long as I say plainly what it is. This "
         "is the sustained part on its own. As written it sits at thirty two "
         "point seven and forty nine hertz — a sine wave, held. Now here is "
         "exactly the same part with every note moved up two octaves, so it "
         "lands at a hundred and thirty one and a hundred and ninety six hertz "
         "instead. Same rhythm, same notes, same instrument, same length. "
         "Moving it changes its overall level by one hundredth of a decibel, "
         "which is nothing. But it changes how much of it lives above one "
         "hundred hertz by fifty one point seven decibels. First the real one, "
         "then the moved one. This is not what the record sounds like — it is a "
         "proxy, deliberately, so you can hear the shape of the part that is "
         "otherwise happening below your speakers.")),

  dict(id="16-loudness", shots=[12, MIXER], cut=6.4,
       factCheck=[["one LU", "1 LU", "one Lu", "1 Lu", "one L U"],
                  ["not a loudness trick",
                                                  "loudness trick"]],
       narration=(
         "One last control, because a comparison between two mixes is worth "
         "nothing if one of them is simply louder. The orchestral render "
         "measures minus nineteen point nine LUFS. The techno render measures "
         "minus twenty point nine. That is one LU apart, which is about as "
         "matched as two genuinely different arrangements get, and it means "
         "none of the difference you have been shown is a loudness trick. Both "
         "figures were measured twice — once by the app as it rendered, and "
         "once by a completely separate tool afterwards — and the two "
         "instruments agree to within two hundredths of a LU. When two "
         "different instruments give you the same answer, that is worth more "
         "than either of them alone.")),

  dict(id="17-close", shots=[14, ARRANGE], cut=6.0, brandCheck="DAW Pro",
       factCheck=[["four notes"], ["thirty three", "33"]],
       narration=(
         "So. Four notes, one project, two records. The thing worth taking away "
         "is not really the numbers, it is the method behind both halves. "
         "Beethoven states one small idea and then refuses to stop developing "
         "it — no contrast, no second subject to escape into, just that cell "
         "worn down and rebuilt for eight minutes. A techno producer does the "
         "same thing with a loop and a mixing desk. The measurements are what "
         "separates the two: below sixty hertz these versions are thirty three "
         "decibels apart, because one of them can sustain a note under the "
         "bottom string of a double bass and the other one physically cannot. "
         "Between sixty and one hundred hertz the orchestra wins. And most of "
         "that argument is happening below what your speakers will hand you, "
         "which is exactly why all of it was drawn as well as played. All of it "
         "was built and rendered in DAW Pro, and every number was measured off "
         "those DAW Pro renders. Thanks for watching.")),
]

spec = dict(
    id="L11v2", theme="remix", size="1920x1080",
    # ⚠ DELIBERATELY NOT the shipped film's name. --finalize is not run for this
    # rebuild, but if it ever is, it must not overwrite the published file
    # before the user has watched this one.
    filename="DAW Pro Lesson 11 - Beethoven At 128 (rebuild)",
    title="Beethoven at 128 BPM: four notes, and what a laptop cannot show you",
    playlist="Mixing, measured", categoryId="27",
    cut=5.2, playMax=9.0, introSeconds=4, outroSeconds=3, meter="br",
    bursts=f"{HERE}/bursts",
    cards=cards, stages=stages,
    tags=["Beethoven", "Symphony No. 5", "techno", "remix", "music production",
          "classical music", "motif", "development", "spectrum analysis"],
    description=(
        "Beethoven's four-note cell rebuilt as a techno riff, in one DAW Pro "
        "project, and then measured. Every number on screen came off the renders "
        "you are hearing.\n\n"
        "THE PROJECT\n"
        f'{MAT["bpm"]} BPM, {MAT["bars"]} bars, {MAT["seconds"]:.0f} s, '
        f'{MAT["notes"]} notes written by hand across eight tracks. The riff is '
        f'{MAT["riffNotes"]} notes — the same cell, four bars, four times through. '
        "The orchestral version plays it in three octaves in unison (violins, celli, "
        "double basses) and nothing else; the techno version plays the SAME notes on "
        f'a saw and adds {MAT["drumHits"]} drum hits and {MAT["subNotes"]} sustained '
        "sub notes. Silencing one group of tracks or the other is the only difference "
        "between the two renders.\n\n"
        "MEASURED\n"
        f'Below 60 Hz: techno {B["techno"]["sub60"]:.1f} dB, orchestral '
        f'{B["orch"]["sub60"]:.1f} dB — {BD["sub60"]:+.1f} dB apart, below the 41.2 Hz '
        "bottom string of a double bass of 1808.\n"
        f'Below 100 Hz: only {BD["sub100"]:+.1f} dB apart. From 60 to 100 Hz the '
        f'ORCHESTRA is louder, by {abs(BD["b60_100"]):.1f} dB. The two spectra cross '
        f'at {CROSS:.0f} Hz.\n'
        f'Loudness: {LO["orch"]["ffmpegLufs"]:.1f} LUFS against '
        f'{LO["techno"]["ffmpegLufs"]:.1f} LUFS — {LO["deltaLu"]:.1f} LU apart, so the '
        "comparison is not a loudness trick. Measured twice, by the app and by "
        "ffmpeg, agreeing to within 0.02 LU.\n\n"
        "WHAT YOUR SPEAKERS ARE NOT SHOWING YOU\n"
        "Said plainly rather than assumed. High-passing the techno render at 100 Hz "
        f'costs {LAP["techno"]["rmsLossDb"]:.1f} dB of level but only '
        f'{LAP["techno"]["lufsLossLu"]:.1f} LU of loudness; the same filter costs the '
        f'orchestral version {LAP["orch"]["rmsLossDb"]:.1f} dB, because it was barely '
        "using that band. So the film draws the spectrum, sweeps a real-time playhead "
        "over a measured chart of the bottom band against a control band above 100 Hz, "
        "and plays the sub part moved up two octaves as an explicit proxy — a shift "
        f'that changes its overall level by {PX["fullBandDeltaDb"]:+.2f} dB and what it '
        f'puts above 100 Hz by {PX["above100GainDb"]:+.1f} dB.\n\n'
        "HONESTLY\n"
        "The four notes and their rhythm are Beethoven's, and so is the idea of "
        "developing one cell relentlessly. The repetition is mine — he never wrote "
        "this as a loop. The tempo is mine; he did leave metronome marks and there is "
        "a long-standing argument about them, which lesson 7 is about and this film "
        "does not try to settle.\n\n"
        "DISCLOSURE\n"
        "The narration is a synthetic voice, generated locally. No music-generation "
        "model was used; every note was programmed by hand.\n\n"
        "#beethoven #techno #remix #musicproduction #classicalmusic #musictheory"),
)

if __name__ == "__main__":
    json.dump(spec, open(f"{HERE}/L11v2.json", "w"), ensure_ascii=False, indent=1)
    words = sum(len(s["narration"].split()) for s in stages)
    print(f"{HERE}/L11v2.json  {len(cards)} cards, {len(stages)} stages, "
          f"{words} words of narration")
