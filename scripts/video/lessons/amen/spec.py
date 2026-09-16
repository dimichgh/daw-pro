#!/usr/bin/env python3
"""The Amen rebuild's spec for shortsmith.py.

Code rather than hand-typed JSON, for the same reason every other lesson in this
tree is: every number on a CARD is injected from MEASUREMENTS.json, so it cannot
drift from the file it was measured into, because it is never typed twice.

⚠ THE NARRATION IS THE RISKY HALF. Numbers must be SPELLED OUT in the script
(the speech model reads digits unreliably) and the content gate compares a
TRANSCRIPT against the script -- so the spoken forms ARE typed by hand. check()
below asserts every spoken figure against the measured one at build time and
refuses to emit a spec whose words and measurements have drifted apart.

⚠ EVERY NUMERIC factCheck CARRIES ITS DIGIT SPELLING, because Whisper writes
numbers back as digits and a gate listing only the word form rejects a verbatim
take. Measured on two earlier films; it costs a full take round each time.

⛔ THE 1969 RECORDING IS NEVER TOUCHED. "Amen, Brother" is a sound recording in
copyright in the US into the 2060s. Everything heard in this film is 53 MIDI
notes written by hand and played by a General MIDI drum kit.

⚠ Paths are absolute: assemble.py resolves a relative shot against its --shots
root, which is the OUT dir, not this one.
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
S, A = f"{HERE}/shots", f"{HERE}/audio"

C = M["material"]
G = M["ghost_vs_accent"]
H = M["humanize"]
D = M["diff_rel_db"]
LU = M["lufs_delta"]
S16 = M["sixteenth_ms"]
CH = M["_chart"]


def check(spoken, measured, tol, what):
    if abs(spoken - measured) > tol:
        sys.exit(f"SPEC REFUSES TO BUILD — {what}: the narration says {spoken} "
                 f"but MEASUREMENTS.json says {measured:.4f}")


check(53, C["total"], 0, "the note count")
check(7, C["kick"], 0, "the kick count")
check(14, C["snare"], 0, "the snare count")
check(32, C["cymbals"], 0, "the cymbal count")
check(110.29, S16, 0.01, "one sixteenth at 136 BPM")
check(88.24, M["sixteenth_ms_at_170"], 0.01, "one sixteenth at 170 BPM")
check(136, M["bpm"], 0, "the tempo")
check(-13.70, G["predicted_gap_db"], 0.01, "the predicted ghost/accent gap")
check(-13.72, G["measured_gap_db"], 0.02, "the measured ghost/accent gap")
check(0.02, M["velocity_law_snare_worst_err_db"], 0.005, "the snare's agreement with the law")
check(4.67, M["velocity_law_snare_layer_err_db"], 0.01, "the sample-layer error")
check(8.60, H["project_max_abs_ms"], 0.01, "the largest humanize shift")
check(4.65, H["project_mean_abs_ms"], 0.01, "the average humanize shift")
check(106, H["notes"], 0, "the humanized note count")
check(7.8, H["max_as_pct_of_sixteenth"], 0.05, "the largest shift as a % of a sixteenth")
check(0.50, H["agree_max_ms"], 0.01, "project-vs-audio agreement")
check(6, M["listen_window_count"], 0, "the listen-window count")
check(6, C["ghostDemo"], 0, "ghosts in the render the chart is made from")
check(5, C["snareGhost"], 0, "ghosts in the full four-bar pattern")
check(22.4, M["listen_max_diff_db"], 0.1, "the peak short-time difference")
check(28.0, M["drag"]["measured_ms"], 0.05, "the drag, measured back out")
check(-20.5, D["ghosts"], 0.05, "how much the ghosts changed")
check(2.9, D["humanize"], 0.05, "how much the humanize changed")
check(0.0, LU["humanize"], 0.05, "what the loudness meter says about the humanize")

# ⚠ MEASURED: a round 10.0 s cut chopped the 136 BPM half at -3.9 dB of its own
#   peak -- mid-hit -- while the 170 half cut at -30.6 dB. 4*(240/136) = 7.0588 s
#   is exactly 4 bars at 136 AND exactly 5 bars at 170, so both halves end on a
#   downbeat (-21.2 / -32.9 dB of peak at the cut).
AB_BARS_S = 4 * 240 / 136

sp = str.upper
# The drum grid's lane rows, cropped out of the full app frame: at full frame the
# named lanes are ~14 px tall and unreadable once the film scales them down.
# ⚠ THE CROP'S ASPECT RATIO IS THE WHOLE GAME, and the first cut got it wrong.
# One crop 3.75:1 wide was used for every clip; assemble.py letterboxes to fit,
# so a one-bar clip photographed as a thin strip of picture floating in a mostly
# black 16:9 frame -- correct content, unreadably small. Measured off the frame
# at t=428 s in the first build. The crop is now sized to the clip: the lane
# names always, plus exactly as many bars as the clip has.
_Y, _H, _X0 = 0.443, 0.465, 0.008
LANE_BAR = 0.300                          # one bar is 30 % of the frame width
def grid(name, bars=1):
    return {"path": f"{S}/grid-{name}.png",
            "zoom": [_X0, _Y, min(0.075 + bars * LANE_BAR, 0.992) - _X0, _H]}
ARRANGE, ROLL = f"{S}/arrange.png", f"{S}/roll-snare.png"
CH_VEL, CH_HUM, CH_AUD = (f"{S}/chart-velocity.png", f"{S}/chart-humanize.png",
                          f"{S}/chart-audibility.png")
GH_STILL, SH_STILL = f"{S}/ghostchart-mid.png", f"{S}/shiftchart-mid.png"

# ------------------------------------------------------------------- cards
cards = [
  dict(type="statement", size=70, y=250,                                        # 0
       lines=["THE MOST SAMPLED", "SIX SECONDS IN MUSIC.", "WE ARE NOT GOING TO SAMPLE IT."],
       sub=["Every sound in this video is a note typed in by hand.",
            "The 1969 recording is never touched, and that limit is the lesson."]),
  dict(type="list", title=sp("four words, in plain english"), step=88,           # 1
       items=[["a break", "the moment a band stops and the drums play alone"],
              ["a breakbeat", "that passage, looped, as the floor of a new record", "hot"],
              ["a ghost note", "a deliberately quiet hit, between the loud ones"],
              ["quantise", "to snap every note onto an exact grid position"]]),
  dict(type="list", title=sp("the record"), step=84,                             # 2
       items=[["\"Amen, Brother\"", "The Winstons, 1969 — a B-side"],
              ["the drummer", "Gregory Coleman"],
              ["the break", "about seven seconds, four bars, around one minute twenty six"],
              ["the tempo", "commonly given as one hundred and thirty six to one hundred "
                            "and forty beats per minute"],
              ["what happened next", "it became the backbone of jungle and drum and bass",
               "hot"]]),
  dict(type="list", title=sp("why we are programming it, not sampling it"), step=94,  # 3
       items=[["the recording", "a 1969 US sound recording — in copyright into the 2060s",
               "hot"],
              ["who was paid", "neither Coleman nor bandleader Richard Spencer, ever"],
              ["2015", "a fan-run fundraiser gave Spencer about eighteen thousand pounds — "
                       "a gift, not a settlement"],
              ["so", "we type the notes in. Nothing here is lifted from the record."]]),
  dict(type="bignumber", label=sp("one sixteenth note at 136 bpm"),              # 4
       value=f"{S16:.1f}", unit=sp("milliseconds"), size=180,
       notes=["the grid the whole pattern is written on",
              f'a whole beat is {M["beat_ms"]:.0f} ms; a bar is {4*M["beat_ms"]/1000:.2f} s',
              "remember this number — everything later is measured against it"]),
  dict(type="list", title=sp("what is actually in the four bars"), step=96,      # 5
       items=[["kick", f'{C["kick"]} hits'],
              ["snare", f'{C["snareAccent"]} accents and {C["snareGhost"]} ghost notes'],
              ["ride cymbal", f'{C["ride"]} — straight eighths, all the way through'],
              ["crash", f'{C["crash"]}, in bar four'],
              ["total", f'{C["total"]} notes, every one typed in by hand', "hot"]]),
  dict(type="bignumber", label=sp("a ghost note, against an accent"),            # 6
       value=f'{G["measured_gap_db"]:.2f}', unit=sp("db quieter"), size=170,
       notes=[f'predicted from the velocity law BEFORE rendering: {G["predicted_gap_db"]:.2f} dB',
              f'velocity {G["ghost_velocity"]} against velocity {G["accent_velocity"]}',
              f'the two agree to {abs(G["measured_gap_db"]-G["predicted_gap_db"]):.2f} of a decibel']),
  dict(type="statement", size=92, y=430, rule=False,                             # 7
       lines=["BAR THREE"], sub=["the snare arrives one sixteenth late, and the loop "
                                 "stops repeating itself"]),
  dict(type="statement", size=92, y=430, rule=False,                             # 8
       lines=["BAR FOUR"], sub=["no kick on the downbeat at all, then a crash between "
                                "beats three and four"]),
  dict(type="bignumber", label=sp("largest distance from the grid"),             # 9
       value=f'{H["project_max_abs_ms"]:.2f}', unit=sp("milliseconds"), size=170,
       notes=[f'average {H["project_mean_abs_ms"]:.2f} ms, across {H["notes"]} hits',
              f'that is {H["max_as_pct_of_sixteenth"]:.1f} % and '
              f'{H["mean_as_pct_of_sixteenth"]:.1f} % of one sixteenth note',
              f'read off the project, then confirmed in the rendered audio to '
              f'{H["agree_max_ms"]:.2f} ms']),
  dict(type="statement", size=58, y=300,                                         # 10
       lines=["A FEW MILLISECONDS IS", "AT THE EDGE OF WHAT ANYONE HEARS."],
       sub=["On laptop speakers, in isolation, you will probably not hear it.",
            "That is not your ears and it is not your speakers — it is the size of it.",
            "So the film also plays a version dragged far enough to be unmissable,",
            "and puts the real number on the same chart, at the same scale."]),
  dict(type="list", title=sp("the controls"), step=94,                           # 11
       items=[["the velocity law", f'predicted {G["predicted_gap_db"]:.2f} dB, measured '
                                   f'{G["measured_gap_db"]:.2f} dB', "hot"],
              ["the timing", f'read off the project, then found in the audio to '
                             f'{H["agree_max_ms"]:.2f} ms'],
              ["the listen windows", f'{M["listen_window_count"]} derived windows; the ghost '
                                     f'demo has exactly {C["ghostDemo"]} ghost notes'],
              ["the drag", f'asked for {M["drag"]["asked_ms"]:.0f} ms, cross-correlated back '
                           f'out at {M["drag"]["measured_ms"]:.1f} ms']]),
  dict(type="list", title=sp("what to take away"), step=96,                      # 12
       items=[["velocity is not a volume knob", "it is the difference between a groove and "
                                                "a drum machine", "hot"],
              ["one bar that breaks the pattern", "is worth more than three that do not"],
              ["off the grid is not sloppy", "it is the part a grid cannot store"],
              ["and if you sample", "know whose recording it is", "hot"]]),
  dict(type="closing", size=56, y=560,                                           # 13
       lines=["Built, programmed and measured in DAW Pro.",
              "Fifty three notes, nothing sampled.",
              "The build scripts, the measurements and the charts are reproducible."],
       kicker="Gregory Coleman, 1944–2006."),
  dict(type="bignumber", label=sp("what a loudness meter saw"),                  # 14
       value=f'{LU["humanize"]:+.1f}', unit=sp("lu"), size=180,
       notes=["…for a version in which every one of the 106 hits moved",
              f'the signal itself changed by {D["humanize"]:+.1f} dB',
              "a meter measures level. None of this lesson is about level."]),
]

# ----------------------------------------------------------------- stages
stages = [
  dict(id="00-open", shots=[0, ARRANGE], cut=4.4, brandCheck="DAW Pro",
       factCheck=[["nineteen sixty nine", "1969"]],
       narration=(
         "If you have listened to any dance music made in the last thirty years, you "
         "have heard this drum pattern, probably hundreds of times, and you may never "
         "have known it had a name. It is called the Amen break. It is about seven "
         "seconds of drumming, recorded in nineteen sixty nine, and it is very likely "
         "the most sampled piece of music that exists. This lesson is about what is "
         "actually inside it: which drum lands where, why one bar of it changed pop "
         "music, and what makes a drum part feel like a person playing rather than a "
         "machine ticking. And we are going to build the whole thing from nothing, in "
         "DAW Pro, by typing notes in one at a time. We will not sample the record, "
         "and the reason we will not is one of the things this lesson is about. "
         "Everything here was predicted first and then measured off the audio, and both "
         "numbers go on the screen together.")),

  dict(id="01-vocabulary", shots=[1], cut=5.6,
       factCheck=[["ghost note", "ghost notes"], ["quantise", "quantize"]],
       narration=(
         "Four words first, because I am going to use them constantly and none of them "
         "are obvious. A break is a moment in a song where the band stops and the drums "
         "keep going on their own. It is a very old idea in soul and funk — you take "
         "everything away for a few seconds so that when the band comes back it hits "
         "harder. A breakbeat is what happens when somebody takes that few seconds of "
         "drums, loops it round and round, and builds an entirely new record on top of "
         "it. A ghost note is a deliberately quiet hit, played in between the loud ones, "
         "so soft that you feel it more than you hear it. And to quantise means to snap "
         "every note onto an exact grid position, perfectly in time. Hold on to that "
         "last one, because by the end of this lesson we are going to deliberately undo "
         "it.")),

  dict(id="02-history", shots=[2], cut=5.6,
       factCheck=[["nineteen sixty nine", "1969"], ["Winstons"], ["Coleman"]],
       narration=(
         "So, the record. In nineteen sixty nine, a soul group from Washington called "
         # ⚠ "the A side" is BOTH jargon and an ASR trap: Whisper wrote "the alpha
         #   aside" for it here, which leaves no way to tell a speech fault from a
         #   transcription fault. Said plainly instead.
         "The Winstons released a single. The song they were promoting was called "
         "Color Him Father, and it did well. On the other side of that record was a "
         "faster instrumental called Amen, "
         "Brother, and about a minute and a half into it the band drops out and the "
         "drummer, Gregory Coleman, plays alone for four bars. That is roughly seven "
         "seconds long. The tempo is usually given as somewhere between one hundred and "
         "thirty six and one hundred and forty beats per minute, and it is worth saying "
         "why that is a range rather than a number: it is a human being playing, not a "
         "click track, so the tempo genuinely moves. Twenty years later, producers "
         "started looping those four bars. Hip hop first, then British hardcore, then "
         "jungle and drum and bass, which were built on this break almost the way rock "
         "music was built on the twelve bar blues.")),

  dict(id="03-copyright", shots=[3], cut=6.0,
       factCheck=[["sixties", "2060s"], ["eighteen thousand", "18,000", "18000"]],
       narration=(
         "Now here is why we are typing this in rather than sampling it, and I want to "
         "be plain about it rather than putting it in the small print. That nineteen "
         "sixty nine recording is still in copyright. A sound recording from that year "
         "is protected in the United States into the twenty sixties. It is not old "
         "music that has become free to use; it is somebody's record, and it has an "
         "owner. And the history around it is genuinely uncomfortable. Neither Gregory "
         "Coleman nor the band's leader, Richard Spencer, was ever paid anything for any "
         "of the thousands of records built on those four bars. Spencer only found out "
         "how widely it had been used in the nineteen nineties, by which point it was "
         "far too late to do anything legally. Coleman died in two thousand and six. In "
         "two thousand and fifteen a fan-run fundraiser in Britain raised around "
         "eighteen thousand pounds and gave it to Spencer — which was a gift from "
         "strangers, not a settlement, and not anything the law made happen. So this "
         "lesson does the thing that is both legally clean and, honestly, more useful "
         "to you: we work out what is in the pattern, and we build our own.")),

  dict(id="04-grid", shots=[4, grid("bars12", 2)], cut=5.4, holdLast=True,
       factCheck=[["sixteenth", "16th"],
                  ["one hundred and thirty six", "136"],
                  ["one hundred and ten", "110"]],
       narration=(
         "Before the first note, the grid. Almost all drum programming is written on "
         "sixteenth notes: you divide each beat into four, which gives you sixteen "
         "possible positions in a bar, and every hit goes on one of them. We are going "
         "to build at one hundred and thirty six beats per minute, the lower end of the "
         "range people give for the original. At that tempo one sixteenth note lasts "
         "one hundred and ten milliseconds. Please keep that number, because it is the "
         "ruler for everything that comes later — when I tell you a drummer landed a "
         "few milliseconds off the grid, the thing that makes that meaningful is how "
         "long one step actually is. On screen now is DAW Pro's drum grid. Each row is "
         "one drum, named down the left, and each column is one of those sixteenth "
         "note positions.")),

  dict(id="05-skeleton", shots=[grid("plain", 2), 5], cut=5.0,
       loop=f"{A}/ab-s3-skeleton.wav", burst="b-skeleton", playMax=9.0,
       normalize=False,
       factCheck=[["two and four", "2 and 4"], ["eighths", "eighth notes"]],
       narration=(
         "Start with the skeleton, which is the part that is not surprising at all. The "
         "ride cymbal plays straight eighth notes right through, one on every half "
         "beat, so it is a constant pulse you can count along to. The snare drum plays "
         "the backbeat: beats two and four of every bar, which is the clap in almost "
         "every pop record ever made. And the kick drum plays on the downbeat and then "
         "once more late in the bar. That is it so far, and here is what it sounds "
         "like. Listen to how mechanical it is. Nothing is wrong with it. It is also "
         "not the Amen break, and everything that makes it the Amen break is what we "
         "add from here.")),

  dict(id="06-velocity", shots=[CH_VEL], cut=6.4,
       factCheck=[["velocity"], ["one hundred and twenty seven", "127"],
                  ["thirteen point seven", "13.7"]],
       narration=(
         "The next ingredient is loudness, note by note, and in a sequencer that is "
         "called velocity. Every MIDI note carries a number from one to one hundred and "
         "twenty seven that says how hard the drum was hit. A novice mistake — and it "
         "was mine for years — is to leave every note at the same velocity, which is "
         "exactly what makes a programmed drum part sound like a machine. But velocity "
         "is not decibels, and the difference matters. This chart is what the sound "
         "bank actually does. The dashed line is a prediction, written down before "
         "anything was rendered: a General MIDI instrument scales the loudness of a "
         "note with the square of the velocity, which in decibels is forty times the "
         "logarithm of velocity divided by one hundred and twenty seven. The coloured "
         "lines are the measurements, one for each drum. Where I am going to put the "
         "ghost notes, the prediction says thirteen point seven decibels below the "
         "accents, and the render measured thirteen point seven as well. But look at "
         "the shaded band in the middle. Around the middle of the range the snare jumps "
         "several decibels off the curve, because the instrument stops using one "
         "recording of the drum and starts using a louder one. Real sampled kits do "
         "that, and I only know it because I measured it rather than assuming.")),

  dict(id="07-ghosts", shots=[grid("ghosts", 2), 6], cut=5.2, holdLast=True,
       loop=f"{A}/ab-s4-ghosts.wav", playMax=9.0, normalize=False,
       ab=dict(before=f"{A}/ab-s3-skeleton.wav", beforeShots=[grid("plain", 2)],
               afterShots=[grid("ghosts", 2)], cycles=2, seconds=8.4),
       factCheck=[["ghost notes"], ["thirteen point seven", "13.7"],
                  ["not loudness matched"]],
       narration=(
         "So here are the ghost notes. Between the loud backbeats, the drummer's stick "
         "is still moving, and it touches the snare very quietly on the way past. Those "
         "quiet touches are what turn a beat into a groove. I have put them in at "
         "velocity fifty against the accents at one hundred and ten, which the chart "
         "says will be thirteen point seven decibels quieter, and that is what it "
         "measured. Now listen to the same four bars twice: first without them, then "
         "with them. These two are not loudness matched, deliberately, because the "
         "level difference is part of what you are supposed to hear. Same tempo, same "
         "drums, same accents. The only change is a few very quiet snare hits.")),

  dict(id="08-marker", shots=[GH_STILL], cut=6.0,
       loop=f"{A}/bed-ghosts.wav", burst="ghostchart", playMax=22.0,
       normalize=False, bedEligible=False,
       factCheck=[["shaded"], ["six", "6"], ["twenty two", "22"]],
       narration=(
         "If you found that hard to pick out, that is fair, and here is where to look. "
         "This chart is the measured level of the kit across those four bars, and there "
         "are two lines on it: the version without ghost notes, and the version with "
         "them. The shaded bars are not chosen by eye. They are every moment where the "
         "two versions differ by more than six decibels, worked out from the "
         "measurements themselves — and there are six of them, which is exactly the "
         "number of ghost notes in this four bar excerpt. That match is the check "
         "that the shading "
         "is really marking what it claims to. A playhead now crosses the chart at real "
         "speed while you hear each version in turn. When the playhead is inside a "
         "shaded bar, that is the moment to listen: inside those bars the ghosted "
         "version is up to twenty two decibels louder, and everywhere else the two files "
         "are identical.")),

  dict(id="09-bar3", shots=[7, grid("bar3str"), grid("bar3")], cut=5.0, holdLast=True,
       loop=f"{A}/ab-s6-full4.wav", playMax=9.0, normalize=False,
       ab=dict(before=f"{A}/ab-s5-bar3straight.wav", beforeShots=[grid("bar3str")],
               afterShots=[grid("bar3")], cycles=2, seconds=8.4),
       factCheck=[["bar three", "bar 3"], ["one sixteenth", "1 sixteenth", "one 16th"],
                  ["last snare"]],
       narration=(
         "Now the part that makes this four bars rather than one bar played four times. "
         "In bar three, the snare that you are expecting on beat four does not arrive on "
         "beat four. It arrives one sixteenth note later — one hundred and ten "
         "milliseconds late — and everything else in the bar stays exactly where it was. "
         "That is one note moved by one step. Listen to it against the version where "
         "that snare is left on the beat, and notice what it does to you: the pattern "
         "stops being predictable, and you start waiting for the next thing instead of "
         "settling into it. In the grid on screen, look at the last snare in the bar: "
         "it now sits between two ride cymbals instead of directly underneath "
         "one.")),

  dict(id="10-bar4", shots=[8, grid("bar4")], cut=5.4, holdLast=True,
       loop=f"{A}/ab-s6-full4.wav", burst="b-bar3", playMax=9.0, normalize=False,
       factCheck=[["bar four", "bar 4"], ["crash"], ["downbeat"], ["slot"]],
       narration=(
         "And then bar four, which is the bar that producers actually chopped up and "
         "built records out of. Two things happen in it. The first is a hole: there is "
         "no kick drum on the downbeat at all. The strongest beat in the bar, the one "
         "your body is counting on, is simply empty, and your ear fills it in. The "
         "second is a crash cymbal landing between beats three and four rather than on "
         "a beat, which throws the whole thing forward into the repeat. Look at the "
         "grid: the bass drum row is empty at the left-hand edge, and the crash has "
         "taken over the slot where a ride cymbal would otherwise have been. Here is "
         "the complete four bars, "
         "with bar three and bar four doing their work.")),

  dict(id="11-full", shots=[grid("all", 4), 5, ROLL], cut=5.0,
       loop=f"{A}/ab-q-quant.wav", burst="b-loop", playMax=13.0, normalize=False,
       factCheck=[["fifty three", "53"], ["nothing sampled", "nothing is sampled"]],
       narration=(
         "That is the whole pattern, and it is fifty three notes: seven kick drum hits, "
         "fourteen snares of which five are ghosts, thirty one ride cymbals and one "
         "crash. Nothing sampled, nothing generated, nothing downloaded. Every one of "
         "those fifty three is a note that was typed into this project, and you can see "
         "them all in the grid on screen. And I want to be honest about what this is and "
         "is not. This is the skeleton that producers program — it is not a note perfect "
         "transcription of what Gregory Coleman played, and nobody's grid version is, "
         "because he was not playing on a grid. Which is exactly where we go next.")),

  # ⚠ SHOT ORDER FOUND BY ARITHMETIC, NOT BY EYE. With holdLast and two stills
  # the timer is each = total/2, so shot[1] owns the SECOND half -- which is
  # where "this chart is every one of those 106 hits" is spoken. The first cut
  # had the chart at index 0 and the words describing it landed over card 9.
  dict(id="12-humanize", shots=[9, CH_HUM], cut=6.2, holdLast=True,
       brandCheck="DAW Pro",
       factCheck=[["eight point six", "8.6"], ["four point six", "4.6"],
                  ["one hundred and six", "106"], ["halfway"],
                  ["has a feel"]],
       narration=(
         "Here is the thing a grid cannot store. A real drummer does not hit exactly on "
         "the beat. Every hit lands slightly early or slightly late, and the pattern of "
         "those small errors is a large part of what we mean when we say a player has a "
         "feel. So let us do it deliberately, and measure it. DAW Pro has a humanise "
         "command that nudges every note by a small random amount, from a seed, so the "
         "same numbers come back every time you run it. I ran it across the whole loop "
         "and then read the result back out of the project, hit by hit. This chart is "
         "every one of those one hundred and six hits and how far off the grid it "
         "landed. The largest is eight point six milliseconds. The average is four "
         "point six. And now that number I asked you to keep is worth something: one "
         "sixteenth note is one hundred and ten milliseconds, so the very worst hit in "
         "this take is under eight percent of one step out of place. The red line near "
         "the top of the chart is the halfway point to the next grid position — past "
         "that line a hit would be closer to the wrong step than to its own. Nothing "
         "here comes anywhere near it.")),

  dict(id="13-shift", shots=[SH_STILL, 10], cut=6.0,
       loop=f"{A}/bed-shift.wav", burst="shiftchart", playMax=19.5,
       normalize=False, bedEligible=False,
       factCheck=[["twenty eight", "28"], ["magnifying glass"],
                  ["laptop speakers"]],
       narration=(
         "And now the honest part, because a few milliseconds is right at the edge of "
         "what anybody can hear, and on laptop speakers, listening to one version on its "
         "own, you very probably will not hear it. That is not your ears and it is not "
         "your speakers. It is the size of the thing. So this chart shows both scales at "
         "once. First the real one: every hit of the humanised take, plotted by how far "
         "off the grid it is, with the playhead crossing at real speed while you hear "
         "it. Then the same pattern again with the snare deliberately dragged twenty "
         "eight milliseconds late — more than three times the largest real shift, and "
         "far enough that you cannot miss it. That second one is not a better version. "
         "It is a magnifying glass. Listen to how heavy and behind the beat the snare "
         "feels when it is dragged, and then remember that the real thing is the small "
         "cluster of dots near the middle line, doing a much gentler version of the same "
         "job.")),

  dict(id="14-audibility", shots=[CH_AUD, 14], cut=6.2, holdLast=True,
       factCheck=[["loudness meter"], ["nothing", "none"],
                  ["twenty point five", "20.5"]],
       narration=(
         "Which brings me to a chart I think is the most useful thing in this video. "
         "Every one of the four changes we have made is on it. The coloured bar is how "
         "much of the audio signal actually changed, measured by subtracting one version "
         "from the other. The grey bar next to it is what an ordinary loudness meter "
         "says about the same pair. And the grey bars are all essentially zero. Adding "
         "the ghost notes changed the signal by minus twenty point five decibels and "
         "moved the loudness by nothing. Moving every hit by a few milliseconds changed "
         "the signal by nearly three decibels — more than the ghost notes did — and "
         "moved the loudness by nothing at all. This is worth sitting with, because "
         "loudness is what most people reach for when they check their work. A meter "
         "measures level. Groove is not level. If you are judging a drum part by looking "
         "at a number, you are looking at the one thing that cannot see any of this.")),

  dict(id="15-tempo", shots=[grid("all", 4), 12], cut=5.6,
       loop=f"{A}/ab-j-170.wav", playMax=11.0, normalize=False,
       ab=dict(before=f"{A}/ab-q-quant.wav", beforeShots=[grid("all", 4)],
               afterShots=[grid("all", 4)], cycles=1, seconds=AB_BARS_S),
       factCheck=[["one hundred and seventy", "170"], ["jungle"],
                  ["eighty eight", "88"]],
       narration=(
         "One last thing, because it explains why this particular break took over dance "
         "music. Jungle and drum and bass run at roughly one hundred and seventy beats "
         "per minute. Here is our pattern at one hundred and thirty six, and then the "
         "identical notes at one hundred and seventy, where one sixteenth note shrinks "
         "from one hundred and ten milliseconds to eighty eight. Listen to how much "
         "busier the same pattern becomes. But there is an important difference between "
         "what you just heard and what those producers did, and it is worth "
         "understanding. We changed the tempo of a sequence of notes, so the drums "
         "sound the same and only arrive faster. They sped up a tape, which raises the "
         "pitch of everything on it as well — so their break also became smaller, "
         "brighter and tighter as it got faster. That side effect is a real part of why "
         "the sped-up Amen break sounds the way it does, and it is something you only "
         "get from a recording, not from notes.")),

  dict(id="16-controls", shots=[11], cut=6.0,
       factCheck=[["control", "controls"], ["cross", "correlat"]],
       narration=(
         "Four controls, because a measurement without a control is just a claim. The "
         "velocity prediction was written down before anything was rendered, and the "
         "render agreed with it to two hundredths of a decibel. The timing shifts were "
         "read off the project and then found again in the finished audio, agreeing to "
         "half a millisecond. The shaded listen windows were derived from the "
         "measurements rather than drawn by eye, and the number of windows came out "
         "equal to the number of ghost notes in that excerpt, which is what it had to "
         "be if the method "
         "works. And the dragged snare was asked for at twenty eight milliseconds and "
         "measured back out of the audio, by cross correlation, at twenty eight "
         "milliseconds.")),

  dict(id="17-close", shots=[12, 13], cut=5.4, brandCheck="DAW Pro",
       factCheck=[["fifty three", "53"]],
       narration=(
         "So, four things to take with you. Velocity is not a volume control; it is the "
         "difference between a groove and a drum machine, and ghost notes are where most "
         "of that lives. One bar that breaks the pattern is worth more than three that "
         "keep it. Being off the grid is not sloppiness — it is the part of a "
         "performance that a grid cannot store, and you can put it back on purpose. And "
         "if you do reach for somebody's recording rather than programming your own, "
         "know whose it is, because the story of this particular six seconds is a man "
         "who played the most influential four bars in modern music and never received a "
         "penny for it. Everything in this video was programmed and measured in DAW Pro. "
         "Fifty three notes, nothing sampled. Thanks for watching.")),
]

spec = dict(
    id="L9v2", theme="remix", size="1920x1080",
    # ⚠ DELIBERATELY NOT the shipped film's name. --finalize is not run for this
    # rebuild, but if it ever is it must not overwrite the published file.
    filename="DAW Pro Lesson 9 - The Amen Break (rebuild)",
    title="The Amen break, programmed by hand — 53 notes, nothing sampled",
    playlist="Music, measured", categoryId="27",
    cut=5.4, playMax=9.0, introSeconds=4, outroSeconds=3, meter="br",
    bursts=f"{HERE}/bursts",
    cards=cards, stages=stages,
    tags=["amen break", "drum programming", "breakbeat", "jungle", "drum and bass",
          "music production", "midi", "ghost notes", "groove", "sampling"],
    description=(
        "The Amen break is probably the most sampled piece of music that exists. This "
        "takes it apart and rebuilds it from nothing — 53 MIDI notes typed in by hand — "
        "and measures every claim it makes.\n\n"
        "⛔ THE 1969 RECORDING IS NEVER TOUCHED\n"
        "\"Amen, Brother\" (The Winstons, 1969) is a sound recording still in copyright "
        "in the US into the 2060s. Neither drummer Gregory Coleman nor bandleader "
        "Richard Spencer was ever paid for its use; a 2015 fan-run fundraiser gave "
        "Spencer about £18,000 as a gift, not a settlement. So this video programs the "
        "pattern instead. That is the legally clean route and it is also the one that "
        "teaches you something.\n\n"
        "WHAT IS IN THE FOUR BARS\n"
        f'· {C["kick"]} kick hits\n'
        f'· {C["snareAccent"]} snare accents and {C["snareGhost"]} ghost notes\n'
        f'· {C["ride"]} ride cymbals, straight eighths\n'
        f'· {C["crash"]} crash, in bar four\n'
        f'· {C["total"]} notes total, at {M["bpm"]:.0f} BPM, where one sixteenth = {S16:.2f} ms\n\n'
        "PREDICTED, THEN MEASURED\n"
        "A General MIDI bank scales note amplitude with (velocity/127)^2, i.e. "
        "40*log10(v/127) dB. Ghost notes at velocity "
        f'{G["ghost_velocity"]} against accents at {G["accent_velocity"]} were predicted at '
        f'{G["predicted_gap_db"]:.2f} dB and measured at {G["measured_gap_db"]:.2f} dB. Away from '
        f'one sample-layer switch the snare tracks that law to '
        f'{M["velocity_law_snare_worst_err_db"]:.2f} dB; inside the switch it is '
        f'{M["velocity_law_snare_layer_err_db"]:.2f} dB off, which is the bank changing to a '
        "different recording of the drum.\n\n"
        "HUMANISING, MEASURED\n"
        f'Across {H["notes"]} hits the largest distance from the grid is '
        f'{H["project_max_abs_ms"]:.2f} ms and the average is {H["project_mean_abs_ms"]:.2f} ms — '
        f'{H["max_as_pct_of_sixteenth"]:.1f} % and {H["mean_as_pct_of_sixteenth"]:.1f} % of one '
        f'sixteenth note. Read off the project, then confirmed in the rendered audio to '
        f'{H["agree_max_ms"]:.2f} ms.\n\n'
        "WHAT A LOUDNESS METER SEES\n"
        f'Adding the ghost notes changed the signal by {D["ghosts"]:+.1f} dB and the integrated '
        f'loudness by {LU["ghosts"]:+.1f} LU. Humanising changed the signal by '
        f'{D["humanize"]:+.1f} dB and the loudness by {LU["humanize"]:+.1f} LU. A meter measures '
        "level; none of this lesson is about level.\n\n"
        "AUDIBILITY, SAID PLAINLY\n"
        "A few milliseconds is at the edge of what anyone hears, and on laptop speakers "
        "you probably will not hear the humanised version on its own. The film says so, "
        "shows the measurement, and plays an exaggerated version at 28 ms next to it at "
        "the same scale rather than pretending.\n\n"
        "SOURCES\n"
        "Facts on the recording, the pattern and the royalties come from Wikipedia's "
        "\"Amen break\" and Ethan Hein's \"Building the Amen Break\" (2023), whose caveat "
        "that a 16th-grid transcription cannot capture the original is stated on screen.\n\n"
        "DISCLOSURE\n"
        "The narration is a synthetic voice, generated locally. No music-generation model "
        "was used; every note was written by hand.\n\n"
        "#amenbreak #drumandbass #jungle #breakbeat #musicproduction #midi"),
)

if __name__ == "__main__":
    json.dump(spec, open(f"{HERE}/L9v2.json", "w"), ensure_ascii=False, indent=1)
    words = sum(len(s["narration"].split()) for s in stages)
    print(f"{HERE}/L9v2.json  {len(cards)} cards, {len(stages)} stages, {words} words")
