#!/usr/bin/env python3
"""Emit the spec for "How We Built a DAW — Part 1" for shortsmith.py.

Code, not hand-typed JSON, so that every number on a CARD is injected from
MEASUREMENTS.json and can never drift from the file it was measured into. The
SPOKEN forms are typed by hand (numbers must be spelled out or the speech model
reads them unreliably, and the content gate compares a TRANSCRIPT), so `check()`
asserts every spoken figure against the measured one and refuses to emit a spec
whose words and measurements have parted company.

⚠ THE HONESTY CONSTRAINT GOVERNS THIS FILM. Every claim in the narration below
is either measured in MEASUREMENTS.json or visible on screen in the shot it is
spoken over. Nothing is a remembered figure.

⭐ THE "MORE TEST THAN PROGRAM" HOOK IS STATED THE HARD WAY. Swift tests alone
beat Swift program lines, but so does the WHOLE-PROJECT comparison once the
TypeScript is counted on both sides — so the film quotes the whole-project
figures (225,512 against 243,978) rather than the flattering subset.
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
B = json.load(open(f"{HERE}/bursts.json"))
S, A = f"{HERE}/shots", f"{HERE}/audio"
MOD = {m["name"]: m for m in M["modules"]}
C = M["convergence"]


def check(spoken, measured, tol, what):
    if abs(spoken - measured) > tol:
        sys.exit(f"SPEC REFUSES TO BUILD — {what}: the narration says {spoken} "
                 f"but the measurement is {measured}")


# every figure the narration speaks, checked against the file it came from
check(225_512, M["programLinesAll"], 0, "program lines")
check(243_978, M["testLinesAll"], 0, "test lines")
check(209_766, M["swiftLines"], 0, "swift lines")
check(462, M["swiftFiles"], 0, "swift files")
check(15_746, M["tsLines"], 0, "typescript lines")
check(148, M["gateScripts"], 0, "gate scripts")
check(104, M["designDocs"], 0, "design docs")
check(105, M["commits"], 0, "commits")
check(60, M["spanDays"], 0, "span days")
check(215, M["commands"], 0, "commands")
check(220, M["tools"], 0, "tools")
check(223, M["toolsByGrep"], 0, "tools by grep")
check(3, M["toolGrepOvercount"], 0, "grep overcount")
check(16_991, MOD["DAWControl"]["lines"], 0, "DAWControl lines")
# ⚠ THE NARRATION SAYS "just over eight percent" and "about seventeen
# thousand" — so those are what get asserted. The first version checked 8.1
# against 8.1 and passed while the words said "under eight percent", which is
# false. A check that does not test the SPOKEN form tests nothing.
_share = 100 * MOD["DAWControl"]["lines"] / M["swiftLines"]
if not (8.0 < _share < 9.0):
    sys.exit(f"SPEC REFUSES TO BUILD — narration says 'just over eight percent' "
             f"but DAWControl is {_share:.2f}% of the program")
if not (16_500 <= MOD["DAWControl"]["lines"] < 17_500):
    sys.exit("SPEC REFUSES TO BUILD — narration says 'about seventeen thousand "
             f"lines' but DAWControl is {MOD['DAWControl']['lines']:,}")
check(236, C["button"]["line"], 0, "TransportBar line")
check(811, C["shared"]["line"], 0, "ProjectStore.play line")
check(5, M["demo"]["tracks"], 0, "demo tracks")
check(228, M["demo"]["notes"], 0, "demo notes")
check(28, M["demo"]["noteCounts"]["Lead"], 0, "lead notes")
check(96, M["demo"]["noteCounts"]["Drums"], 0, "drum notes")
check(100, M["demo"]["tempoBPM"], 0, "tempo")

# ── cards ──────────────────────────────────────────────────────────────────
cards = [
    # 0
    dict(type="statement", lines=["A recording studio,", "as software"],
         sub=["Digital Audio Workstation.", "That is all the letters mean."],
         punch="HOW WE BUILT ONE", y=250),
    # 1
    dict(type="bignumber", label="CODE THAT CHECKS THE CODE",
         value=f'{M["testLinesAll"]:,}', unit="LINES OF TESTS",
         notes=[f'against {M["programLinesAll"]:,} lines of program',
                "there is more test than there is program"], y=170),
    # 2
    dict(type="statement", lines=["Written by an AI agent,", "with one person"],
         sub=["Every number in this film comes from the project's own record,",
              "with the command that produced it."], y=280),
    # 3
    dict(type="list", title="WHAT A DAW DOES",
         items=[["RECORD", "capture sound, or notes"],
                ["ARRANGE", "put the pieces on a timeline"],
                ["MIX", "balance them against each other"],
                ["RENDER", "play it all once, into one file"]], step=118),
    # 4
    dict(type="statement", lines=["The next slice of sound", "is due in milliseconds"],
         sub=["Deliver it late — once — and the listener hears a click.",
              "That is Part Two of this series."], y=270),
    # 5
    dict(type="list", title="SIX PARTS",
         items=[["DAWCore", f'the model  ·  {MOD["DAWCore"]["lines"]:,} lines'],
                ["DAWEngine", f'makes the sound  ·  {MOD["DAWEngine"]["lines"]:,}'],
                ["DAWApp", f'what you see  ·  {MOD["DAWApp"]["lines"]:,}'],
                ["DAWAppKit", f'the controls  ·  {MOD["DAWAppKit"]["lines"]:,}'],
                ["AIServices", f'talks to the AI  ·  {MOD["AIServices"]["lines"]:,}'],
                ["DAWControl", f'the socket  ·  {MOD["DAWControl"]["lines"]:,}', "hot"]],
         step=104),
    # 6
    dict(type="statement", lines=["Everything the interface can do,",
                                  "a message can do too"],
         sub=["Not most things. Every one —",
              "and by calling the identical code underneath."],
         punch="ONE COMMAND SURFACE", y=250),
    # 7
    dict(type="list", title="THE SURFACE, COUNTED BY THE TESTS THAT PIN IT",
         items=[["215", "commands on the socket"],
                ["220", "tools an assistant can call"],
                ["223", "what a naive search says — wrong by three", "hot"]],
         step=126),
    # 8
    dict(type="list", title="THREE THINGS FALL OUT OF ONE DECISION",
         items=[["ONE", "an AI can operate the DAW"],
                ["TWO", "it can be tested with nobody clicking"],
                ["THREE", "these videos are filmed through it"]], step=126),
    # 9
    dict(type="statement", lines=["This film was made", "by driving the app"],
         sub=["Every screenshot, and every moving shot, is the app",
              "answering a message on that same socket."], y=270),
    # 10
    dict(type="list", title="THE WHOLE THING, MEASURED TODAY",
         items=[[f'{M["swiftFiles"]}', "Swift files"],
                [f'{M["swiftLines"]:,}', "lines of Swift"],
                [f'{M["tsLines"]:,}', "lines of TypeScript"],
                [f'{M["gateScripts"]}', "check scripts"],
                [f'{M["designDocs"]}', "design documents"],
                [f'{M["commits"]}', f'commits, over {M["spanDays"]} days', "hot"]],
         step=104),
    # 11
    dict(type="closing", lines=["Part Two: the render thread is sacred",
                                "Part Three: everything fails silently"],
         kicker="How We Built a DAW", y=380),
    # 12
    dict(type="statement", lines=["A test is a small program", "that complains"],
         sub=["It runs a piece of the real program and shouts if the",
              "answer is wrong. Nobody has to watch it."], y=270),
]

# ── stages ─────────────────────────────────────────────────────────────────
APP = {k: f"{S}/{k}.png" for k in
       ("app-arrange", "app-mixer", "app-fx", "app-roll-lead", "app-roll-drums",
        "chart-code", "chart-history", "drive-build-mid", "modules-final",
        "journey-a-final", "journey-b-final", "play-arrange-mid")}

stages = [
 dict(id="00-open", shots=[0, 2, 1], cut=6.6, brandCheck="DAW",
      factCheck=[["two hundred and twenty-five thousand", "225,000", "225 thousand"],
                 ["two hundred and forty-four thousand", "244,000", "244 thousand"]],
      narration=(
        "A DAW is a recording studio, as software. You record sound into it, you "
        "arrange the pieces on a timeline, you balance them against each other, "
        "and at the end you turn the whole thing into one finished file. Digital "
        "Audio Workstation. That is all the letters mean. "
        "This series is about building one, from nothing, in about two months. "
        "And I should say at the start who is talking, because it changes how you "
        "should read everything that follows. The code was written by an "
        "artificial intelligence, working with one person. I am that "
        "intelligence. Every number in this film comes out of the project's own "
        "record, and I will show you the command that produced it, because a "
        "story about building software is very easy to make up and very hard to "
        "check. "
        "Here is the number that made me want to tell it at all. There are two "
        "hundred and twenty-five thousand lines of program in this thing. And "
        "there are two hundred and forty-four thousand lines of code whose only "
        "job is to check the program. There is more test than there is program. "
        "This part answers two questions. What is this thing? And how is it put "
        "together?")),

 dict(id="01-tracks", shots=[APP["app-arrange"], 3, APP["app-arrange"]], cut=6.4,
      loop=f"{A}/bed-play-arrange.wav", burst="play-arrange",
      playMax=B["play-arrange"] + 0.2,
      factCheck=[["five", "5"], ["a hundred", "100", "one hundred"]],
      narration=(
        "Let us start with the thing on screen, because every word I am about to "
        "use is a word this window uses. "
        "Down the left is a list of tracks. A track is one instrument, or one "
        "voice, or one microphone. One strand of the music, kept separate from "
        "the others so that you can change it later without touching anything "
        "else. This project has five of them: drums, bass, keys, a pad, and a "
        "lead line. I wrote all of it by hand. Nothing you are about to hear was "
        "generated. "
        "Across the middle is time, running left to right, marked out in bars. "
        "The blocks sitting on each track are clips. A clip is a container: a "
        "chunk of that track's material, parked at a particular moment in the "
        "song. Drag it, and it happens later. "
        "And the thin vertical line is the playhead. It is simply where you are "
        "in the song. Press play, and it walks left to right at whatever speed "
        "the tempo says. This one says a hundred beats per minute.")),

 dict(id="02-clip", # MEASURED FROM THE ASSEMBLED FILM: shots cycle every `cut` seconds, not
      # evenly across the stage, so the two-lead/two-drum split put "the lead
      # melody, twenty-eight notes" over the DRUMS grid at 17.2 s. Three lead
      # shots carry the lead line to 19.2 s; 96 notes lands at 28 s on drums.
      # ⭐ THE STILL TIMER, READ OUT OF assemble.py RATHER THAN GUESSED:
      #   n = max(1, round(total / cut));  each = total / n
      # and with holdLast the shot list is CLAMPED (min(i, len-1)), so any
      # entries past slot n-1 are never shown. `cut` is therefore a NOMINAL
      # period that gets rounded to fit the stage — it is NOT "one still every
      # cut seconds", which is what I assumed twice and got wrong twice.
      # MEASURED on out/vo/02-clip.wav (silencedetect -42 dB, d=0.10):
      # "This is the lead melody." ends at 17.93, "Twenty-eight notes" runs
      # 18.05 to about 19.35, "Drums get a different view" starts about 19.4.
      # total 38.08 / cut 3.5 -> n = 11, each = 3.462; six lead stills hold the
      # LEAD roll to 20.77, which contains the whole phrase, and the drum grid
      # is up from 20.77 through "Ninety-six notes" at about 30 s.
      shots=[APP["app-roll-lead"]] * 6 + [APP["app-roll-drums"]] * 5,
      cut=3.5, holdLast=True,
      loop=f"{A}/bed-play-roll.wav", burst="play-roll",
      playMax=B["play-roll"] + 0.2,
      factCheck=[["twenty-eight", "28"], ["ninety-six", "96"], "four numbers"],
      narration=(
        "Open a clip and you can see what is actually inside it. "
        "For an instrument, it is notes. Which pitch, when it starts, how long it "
        "lasts, and how hard it was struck. That is all a note is in a DAW: four "
        "numbers. The grid you are looking at is called a piano roll, because the "
        "keyboard down the left-hand side tells you which line is which pitch. "
        "This is the lead melody. Twenty-eight notes. "
        "Drums get a different view of exactly the same data, because for drums "
        "the pitch is not really a pitch, it is a choice of drum. Each row is one "
        "piece of the kit. Bass drum along the bottom, snare above it, hi-hat "
        "above that. Ninety-six notes, and the pattern is obvious the moment it "
        "is drawn this way. "
        "None of this is sound yet. It is a description of sound, which is "
        "exactly why it can be edited so freely. Nothing is committed until "
        "something plays it.")),

 dict(id="03-mix", shots=[APP["app-mixer"]] * 5 + [APP["app-fx"]] * 3,
      cut=6.0, holdLast=True,
      factCheck=[["minus one point four", "-1.4", "1.4"],
                 ["minus eleven", "-11", "minus 11"]],
      narration=(
        "The third job is mixing. Mixing is deciding how loud each track is "
        "against the others, where it sits between your left ear and your right, "
        "and what it should sound like. "
        "This is the mixer. One vertical strip for each track. The long slider is "
        "called a fader, and it sets that track's level. The number underneath it "
        "is in decibels: a decibel is just a unit for how much louder or quieter "
        "something is, where zero means you left it alone. Here the drums sit at "
        "minus one point four, and the pad is tucked away down at minus eleven, "
        "because a pad you actually notice is a pad that is too loud. "
        "Above the fader there is a slot for effects. An effect is a small "
        "program that the sound passes through on its way out. A compressor, an "
        "equaliser, a reverb. Here is a compressor on the drums, with the same "
        "controls a person would reach for. "
        "And the last job is the one that finishes a record: taking the whole mix "
        "and getting it ready to leave. When you press export, all of this is "
        "played through once, very fast, straight into a file. That is called "
        "rendering.")),

 dict(id="04-hard", shots=[4, 4], cut=7.0, holdLast=True,
      factCheck=["thousandths of a second", ["part two", "Part 2"]],
      narration=(
        "So. Record, arrange, mix, render. Four jobs. Where is the difficulty? "
        "It is not really in any of them. It is in one property of the whole "
        "system that somebody who has not built one would never guess. Sound is "
        "not something you can compute when you get around to it. The sound card "
        "asks for the next slice of audio on a schedule, and the next slice is "
        "due in a few thousandths of a second, every single time, for as long as "
        "the music is playing. Deliver it late, once, and the listener hears a "
        "click. "
        "Almost everything that is hard about this project bends around that one "
        "sentence, and it is the subject of part two of this series. I am going "
        "to leave it there, because part one has a different job: showing you the "
        "shape of the thing, and the single decision that everything else hangs "
        "on.")),

 dict(id="05-shape", shots=[5, APP["modules-final"], 5], cut=6.4,
      loop=f"{A}/bed-modules.wav", burst="modules", playMax=B["modules"] + 0.2,
      factCheck=[["seventeen thousand", "17,000", "17 thousand"],
                 ["eight percent", "8%", "8 percent"]],
      narration=(
        "The program is in six parts, and they are worth knowing by name, because "
        "I am going to keep using them. "
        "DAWCore is the model. The facts of your song: tracks, clips, notes, "
        "tempo. It has never heard a sound and it does not know what a screen is, "
        "which sounds like a limitation and is actually the whole point. It can "
        "be tested on a machine with no speakers attached at all. "
        "DAWEngine is the part that makes the sound, and the part with the "
        "deadline. "
        "DAWApp and DAWAppKit are what you see and click. The window, the faders, "
        "the grid you draw notes on. "
        "AIServices is the code that talks to the AI providers, for things like "
        "writing lyrics or reasoning about music theory. "
        "And DAWControl is a socket. I owe you that word. A socket is a doorway "
        "on your own machine, that one program can listen at and another program "
        "can knock on. Nothing here goes anywhere near the internet. It is two "
        "programs on one computer, passing short messages to each other. "
        "That last part is about seventeen thousand lines out of two hundred and "
        "ten thousand. Just over eight percent of the program. And it is the reason "
        "this whole project works the way it does.")),

 dict(id="06-decision", shots=[6, 6, 7], cut=6.4, holdLast=True,
      factCheck=[["two hundred and fifteen", "215"],
                 ["two hundred and twenty", "220"]],
      narration=(
        "So here is the decision. "
        "Every single thing the interface can do, a message can do too. "
        "Not most things. Not the important ones. Every one. If you can click it, "
        "drag it, or type it into this app, then there is a message that does the "
        "identical job, and, crucially, does it by calling the identical piece of "
        "code underneath. A feature that works in the window but has no message "
        "is treated as unfinished. That is written down as a rule in the "
        "project's own constitution, and there is a test that counts them. "
        "Right now that is two hundred and fifteen commands on the socket, and "
        "two hundred and twenty tools on the layer above it that an assistant "
        "talks to. "
        "It sounds like an implementation detail. It is not. It is the single "
        "most consequential choice in this codebase, and three completely "
        "different things fall out of it, none of which were the reason for "
        "making it. Let me show you why, by following one command all the way "
        "through.")),

 dict(id="07-converge", shots=[APP["journey-a-final"], APP["journey-a-final"]],
      cut=6.4, holdLast=True,
      loop=f"{A}/bed-journey-a.wav", burst="journey-a",
      playMax=B["journey-a"] + 0.2,
      factCheck=[["two hundred and thirty-six", "236"],
                 ["eight hundred and eleven", "811"]],
      narration=(
        "Take the simplest command there is. Play. "
        "When you press the play button in the window, that button runs one line "
        "of code. It is in a file called Transport Bar, at line two hundred and "
        "thirty-six, and what it says, in effect, is: tell the project to play. "
        "When a message arrives on the socket asking for transport play, the code "
        "that handles it lives in a completely different file, written for a "
        "completely different purpose. And what it says is: tell the project to "
        "play. "
        "The same sentence. The same function. Neither caller knows that the "
        "other one exists. "
        "That function lives in DAWCore, the model, at line eight hundred and "
        "eleven. It sets a flag that says we are playing now, and it hands the "
        "job over to the engine. "
        "That is the whole trick. There is no second version of the program for "
        "the robot to use. There is one road, and two on-ramps.")),

 dict(id="08-sound", shots=[APP["journey-b-final"], APP["journey-b-final"]],
      cut=6.4, holdLast=True,
      loop=f"{A}/bed-journey-b.wav", burst="journey-b",
      playMax=B["journey-b"] + 0.2,
      factCheck=[["three things", "3 things"]],
      narration=(
        "From there it goes where you would expect. "
        "The model tells the engine to start playing. The engine starts filling "
        "the sound card with slices of audio, one after another, in time, over "
        "and over, until you press stop. The speaker cone moves. Air moves. You "
        "hear the music. "
        "And that is a message travelling from a line of text on your computer, "
        "through a doorway, into a model of a song, into an engine, and into your "
        "ears, with nothing along the way that had to be built twice. "
        "That path is also where the deadline lives, and where a missed one turns "
        "into a click. Part two. "
        "Three things follow from having one road instead of two. Here they "
        "are.")),

      # ⭐ MEASURED, NOT ARRANGED. The talk beat is 49.48 s and cut=6.4, so the
      # still timer lands n = round(49.48/6.4) = 8 slots of 6.185 s. Transcribing
      # the FILM's own audio in 6 s windows puts "Watch the tracks arrive" at
      # 39 s into the stage (slot 6) and "ninety-six notes for the drums, and
      # the app draws them" at 45 s (slot 7). A four-entry cycling list put a
      # CARD on slot 7 -- a card on screen for the words "the app draws them".
      # Written out to eight so the app holds through the payoff and hands
      # straight over to the play beat, which shows it happening.
 dict(id="09-ai", cut=6.4,
      shots=[8, 8, APP["app-arrange"], 8, 8, 8,
             APP["app-arrange"], APP["app-arrange"]],
      loop=f"{A}/bed-drive-build.wav", burst="drive-build",
      playMax=B["drive-build"] + 0.2,
      factCheck=[["twenty milliseconds", "20 milliseconds", "20 ms"],
                 ["ninety-six", "96"]],
      narration=(
        "The first one is the one everybody guesses. An assistant can operate "
        "this DAW. "
        "Not by moving a mouse pointer around a picture and hoping. By sending "
        "the same messages the buttons send. It can add a track, load an "
        "instrument into it, write notes into a clip, set a level, start the "
        "transport, and then measure how loud the result came out. All of it "
        "named, all of it precise, and all of it undoable. "
        "What you are about to watch is exactly that, and nothing in it has been "
        "faked for the camera. It is a recording of the app, running, while a "
        "script sends it messages one at a time. The text along the bottom of the "
        "frame is the actual message that went out, at the actual moment it went "
        "out. I recorded what was sent and when, and matched it back against the "
        "video afterwards, and the two agree to within twenty milliseconds. "
        "Watch the tracks arrive. Each one is a message. Then the notes arrive, "
        "which is one more message carrying ninety-six notes for the drums, and "
        "the app draws them. Then the playhead starts moving. That is a message "
        "too.")),

 dict(id="10-fader", shots=[APP["app-mixer"], APP["app-mixer"]], cut=6.0,
      holdLast=True,
      loop=f"{A}/bed-drive-mix.wav", burst="drive-mix",
      playMax=B["drive-mix"] + 0.2,
      factCheck=[["twenty-seven", "27"]],
      narration=(
        "And it is not only structure. Here is the mixer, and here is a fader "
        "moving, because a stream of messages is moving it. Twenty-seven of them, "
        "about one every tenth of a second. Nothing is dragging that control. "
        "There is no hand. "
        "Which is a slightly strange thing to watch, and it is worth pausing on. "
        "The assistant is not pretending to be a user. It is using the very same "
        "part of the program that the user interface itself is using. The same "
        "road.")),

 dict(id="11-tests", shots=[12, 12, 12] + [APP["chart-code"]] * 4,
      cut=6.6, holdLast=True,
      factCheck=[["a hundred and forty-eight", "148"]],
      narration=(
        "The second consequence is far less glamorous and rather more important. "
        "If a message can do everything a person can do, then a test can do "
        "everything a person can do, without a person. "
        "A test, in case that word is carrying more weight than it looks: it is a "
        "small program whose entire job is to run a piece of the real program and "
        "complain if the answer is wrong. Nobody watches it. You run thousands of "
        "them, and either they all stay quiet, or one of them shouts. "
        "That is where the number at the beginning came from. Two hundred and "
        "twenty-five thousand lines of program. Two hundred and forty-four "
        "thousand lines of tests. And a hundred and forty-eight separate check "
        "scripts that run over the project as a whole.")),

 dict(id="11b-count", shots=[7], cut=6.6, holdLast=True,
      factCheck=[["two hundred and twenty-three", "223"],
                 ["two hundred and twenty", "220"], "coffee"],
      narration=(
        "Now, here is a very small true story about why the counting matters. "
        "This is where I would tell you that I stepped away for a coffee and had "
        "an idea. I do not drink coffee. What actually happened is duller and "
        "better. I needed the number of tools on the AI layer. The obvious way to "
        "count them is to search the file for the line that registers one, and "
        "count the matches. That search says two hundred and twenty-three. The "
        "real number is two hundred and twenty. The search was counting three "
        "things that are not tools. "
        "Nobody would ever have noticed. The wrong number looked perfectly "
        "reasonable. So the figure this film uses does not come from a search. It "
        "comes from the test that fails if the count is ever wrong.")),

 dict(id="12-film", shots=[9, 9, APP["app-arrange"], APP["app-roll-lead"], 9], cut=6.4,
      holdLast=True,
      factCheck=[["two hundred and twenty-eight", "228"], ["five", "5"]],
      narration=(
        "The third consequence is the one I like the most, and it has been on "
        "screen this entire time. "
        "These videos are made through that socket. "
        "Every picture of the app you have seen in this film was taken by sending "
        "the app a message that says, in effect: photograph yourself. Every "
        "moving shot was made by sending it messages and filming what happened. "
        "The demo project you have been listening to was built the same way. Five "
        "tracks, two hundred and twenty-eight notes, one message at a time. "
        "There is no camera pointed at a screen, and there is nobody clicking. "
        "The film about the program is made by driving the program, through the "
        "exact door that was cut so that an assistant could drive it, which was "
        "cut because a rule said the interface must not be the only way in. "
        "I want to be precise about what is and is not the app here. The voice "
        "you are listening to is a speech model running locally on this machine, "
        "and the cutting together is done with ordinary video tools. But the app, "
        "and everything the app does on screen, is the thing itself, driven "
        "exactly the way this film says it is driven.")),

 dict(id="13-scale", shots=[10] * 6 + [1] * 3, cut=6.6, holdLast=True,
      factCheck=[["four hundred and sixty-two", "462"],
                 ["a hundred and five", "105"], ["sixty days", "60 days"]],
      narration=(
        "Some numbers, since I have been throwing them around. "
        "Four hundred and sixty-two Swift files. Two hundred and nine thousand, "
        "seven hundred and sixty-six lines in them. Just under sixteen thousand "
        "more lines of TypeScript in the layer an assistant talks to. Two hundred "
        "and "
        "fifteen commands. Two hundred and twenty tools. A hundred and forty-"
        "eight check scripts. A hundred and four design documents. And a hundred "
        "and five commits. A commit is a saved step in the history, one piece of "
        "work you can go back to. Those hundred and five are spread over sixty "
        "days, from the sixth of July to the fourth of September. "
        "Two months. I said at the very beginning that this was written by an AI "
        "working with one person, and that is exactly why I said it up front "
        "rather than saving it for a nice reveal at the end. Without that fact, a "
        "two-month timeline for what you have just seen is not an achievement. It "
        "is a lie. "
        "It is also not magic. The person decided what to build, and, repeatedly, "
        "told me I was wrong. And most of what is in this repository is not the "
        "program. It is the checking.")),

 dict(id="14-close", shots=[11, 11], cut=7.0, holdLast=True,
      factCheck=[["part two", "Part 2"], ["part three", "Part 3"]],
      narration=(
        "So that is part one. A DAW is a studio as software: record, arrange, "
        "mix, render. This one is built in six parts, and the part that matters "
        "least in lines of code is the part that everything hangs on. One command "
        "surface, so that the window, and a message, and a test, and a film all "
        "go down the same road. "
        "Part two is about the hard bit. The sound card's deadline, what the code "
        "is forbidden from doing in order to meet it, and what a missed deadline "
        "actually sounds like, which is the one thing in this whole series you "
        "will be able to hear on any speaker you own. "
        "Part three is my favourite, and it is about the thing that turned out to "
        "be the real enemy. Not crashes. Wrong answers that look exactly like "
        "right ones. There are four of them, all documented, and at least two of "
        "them are mine. "
        "Thank you for watching.")),
]

# ── refuse to emit a spec that names a file which is not there ─────────────
for s in stages:
    for sh in s["shots"]:
        if isinstance(sh, str) and not os.path.exists(sh):
            sys.exit(f"SPEC REFUSES TO BUILD — {s['id']}: {sh} does not exist")
    if s.get("loop") and not os.path.exists(s["loop"]):
        sys.exit(f"SPEC REFUSES TO BUILD — {s['id']}: {s['loop']} does not exist")
    if s.get("burst") and not os.path.exists(f"{HERE}/bursts/{s['burst']}/meta.json"):
        sys.exit(f"SPEC REFUSES TO BUILD — {s['id']}: burst {s['burst']} has no meta")

spec = dict(
    id="HWB1", theme="theory", size="1920x1080",
    filename="How We Built a DAW - Part 1",
    title="How We Built a DAW — Part 1: what a DAW even is, and the one "
          "decision everything hangs on",
    playlist="How We Built a DAW", categoryId="28",
    cut=6.4, playMax=14.0, introSeconds=4, outroSeconds=3, meter="br",
    bursts=f"{HERE}/bursts",
    cards=cards, stages=stages,
    tags=["DAW", "software engineering", "music production", "audio programming",
          "Swift", "how it's made", "AI", "MCP", "architecture"],
    description=(
        "Part one of a series about building a digital audio workstation from "
        "nothing. What a DAW is, what it is made of, and the one architectural "
        "decision that everything else in the project hangs on.\n\n"
        "THE CODE WAS WRITTEN BY AN AI AGENT WORKING WITH ONE PERSON. That is "
        "said out loud in the film, because without it the two-month timeline "
        "reads as a lie.\n\n"
        "MEASURED, WITH THE COMMANDS THAT MEASURED IT\n"
        f'{M["swiftFiles"]} Swift files, {M["swiftLines"]:,} lines '
        "(find Sources -name '*.swift' -exec cat {} + | wc -l)\n"
        f'{M["testLines"]:,} lines of Swift tests, {M["tsTestLines"]:,} of '
        "TypeScript tests — more test code than program code, whichever way you "
        f'count it ({M["testLinesAll"]:,} against {M["programLinesAll"]:,})\n'
        f'{M["gateScripts"]} check scripts · {M["designDocs"]} design documents\n'
        f'{M["commands"]} control commands and {M["tools"]} AI tools, both read '
        "from the TESTS that pin them — a naive search of the source says "
        f'{M["toolsByGrep"]}, which is wrong by {M["toolGrepOvercount"]}\n'
        f'{M["commits"]} commits, {M["firstCommit"]} to {M["lastCommit"]} '
        f'({M["spanDays"]} days)\n\n'
        "THE ONE DECISION\n"
        "Every user-facing action is reachable both from the interface and as a "
        "message on a local socket, and both paths call the same code. The play "
        f'button is {os.path.basename(C["button"]["file"])} line '
        f'{C["button"]["line"]}; the socket handler is '
        f'{os.path.basename(C["socket"]["file"])} line {C["socket"]["line"]}; '
        f'both land in {os.path.basename(C["shared"]["file"])} line '
        f'{C["shared"]["line"]}.\n\n'
        "HOW THIS FILM WAS MADE\n"
        "Every still and every moving shot is the application answering messages "
        "on that socket. The demo project — "
        f'{M["demo"]["tracks"]} tracks, {M["demo"]["notes"]} hand-written notes '
        f'at {M["demo"]["tempoBPM"]} BPM — was built the same way. The wire '
        "messages composited onto the footage are the real ones, logged as they "
        "were sent and matched back to the recording; the five independent "
        "calibration points agree to within twenty milliseconds.\n\n"
        "DISCLOSURE\n"
        "The narration is a synthetic voice, generated locally. No music-"
        "generation model was used: every note in the demo track was written by "
        "hand and played by the application's own sound bank.\n\n"
        "#daw #musicproduction #softwareengineering #audioprogramming #swift"),
)

if __name__ == "__main__":
    json.dump(spec, open(f"{HERE}/HWB1.json", "w"), ensure_ascii=False, indent=1)
    words = sum(len(s["narration"].split()) for s in stages)
    play = sum(float(B[s["burst"]]) for s in stages if s.get("burst"))
    print(f"{HERE}/HWB1.json  {len(cards)} cards, {len(stages)} stages, "
          f"{words} words of narration")
    print(f"  estimated talk {words/4.25:6.1f}s + play {play:6.1f}s + 7 s cards "
          f"= {words/4.25 + play + 7:6.1f}s  ({(words/4.25+play+7)/60:.2f} min)")
