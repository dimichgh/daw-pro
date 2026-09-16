#!/usr/bin/env python3
"""Emit the spec for "How We Built a DAW - Part 3" for shortsmith.py.

Code, not hand-typed JSON: every number on a CARD is injected from
MEASUREMENTS.json and can never drift from the file it was measured into. The
SPOKEN forms are typed by hand (figures must be spelled out or the speech model
reads them unreliably, and the content gate compares a TRANSCRIPT), so check()
and band() assert every spoken figure against the measured one and refuse to
emit a spec whose words and measurements have parted company.

⚠ THE HONESTY CONSTRAINT GOVERNS THIS FILM, and this part hardest of all: it is
about failures that measure healthy. Four cases, all from this project's own
record, all re-derived in this build. Where the record and my own re-measurement
disagree, BOTH are stated.

⚠ WHAT THIS PART DOES NOT SPEND: Part 1 owns the architecture, the one command
surface and the "more test than program" hook; Part 2 owns the render thread,
the deadline and the counter that lost forty-five per cent. Part 4 owns
falsification — planting a fault and watching a test redden — and the gate
corpus. This part owns the four silent failures and the defence against them,
which is the POSITIVE CONTROL, a different idea from falsification and named as
such in the close.
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
B = json.load(open(f"{HERE}/bursts.json"))
S, A = f"{HERE}/shots", f"{HERE}/audio"


def check(spoken, measured, tol, what):
    if abs(spoken - measured) > tol:
        sys.exit(f"SPEC REFUSES TO BUILD — {what}: the narration says {spoken} "
                 f"but the measurement is {measured}")


def band(lo, hi, measured, what):
    if not (lo <= measured <= hi):
        sys.exit(f"SPEC REFUSES TO BUILD — {what}: the narration implies "
                 f"{lo}..{hi} but the measurement is {measured}")


# ── every figure the narration speaks, against the file it came from ──────────
# case 1 — the search that never ran
check(127, M["grepBrokenExit"], 0, "the exit code of a command that never ran")
check(0, M["grepBrokenBytes"], 0, "bytes printed by that command")
check(3, M["grepGoodCount"], 0, "files the working command found")
if "command not found" not in M["grepRealError"]:
    sys.exit(f"SPEC REFUSES TO BUILD — the error was {M['grepRealError']!r}")
# case 2 — the demonstration that was correct and inaudible
band(9.5, 10.6, M["pairSeconds"], "about ten seconds of drums")
band(6.0, 8.0, M["pairDiffDb"], "about seven decibels on average")
band(12.0, 13.5, M["pairDiffDbMax"], "nearly thirteen decibels at its widest")
band(-43.0, -39.0, M["pairDiffLevelFast"], "about minus forty-one dBFS")
band(23.0, 27.0, M["pairBelowFilm"], "about twenty-five decibels below this film")
band(70.0, 76.0, M["pairSilentFraction"], "nearly three quarters is silence")
check(11.5, M["pairRecordDb"], 0.01, "the record's own eleven and a half decibels")
check(-39.9, M["pairRecordLevels"][0], 0.01, "the record's louder level")
check(-51.5, M["pairRecordLevels"][1], 0.01, "the record's quieter level")
check(14, M["pairLiftDb"], 0, "the shared gain on the second listen")
check(30, M["pumpReleases"][0], 0, "the fast release in milliseconds")
check(800, M["pumpReleases"][2], 0, "the slow release in milliseconds")
# case 3 — the meter with dead bars
check(5, M["meterDeadOld"], 0, "five dead bands")
check(48, M["meterBarsOld"], 0, "forty-eight bands")
check(72, M["meterBarsNew"], 0, "seventy-two bands")
check(11, M["meterNarrowOld"], 0, "eleven — the count of the WRONG question")
check(15, M["meterBinHz"], 0.01, "fifteen hertz per analysis line")
check(0, M["meterDeadAfterFix"], 0, "no dead bands after the fix")
band(36.0, 36.4, M["meterDeadOldHz"][0], "the lowest dead band, about thirty-six hertz")
band(98.0, 98.5, M["meterDeadOldHz"][4], "the highest dead band, about ninety-eight hertz")
# case 4 — the A/B that never happened
check(1, M["abSkillClaim"], 0, "the record carries the same-file A/B")
check(1, M["abCheckExists"], 0, "the gate that now catches it exists")
check(0.11, M["frameStillMax"], 0.001, "a still film's frame-to-frame difference")
check(5.04, M["frameRealMax"], 0.001, "a real film's")
# the eureka
check(6.45, M["pumpHz"], 0.001, "the pumping rate that was the drums")
check(1, M["pumpRetracted"], 0, "the retraction is in the changelog")
# scale
check(148, M["gateScripts"], 0, "gate scripts")
check(105, M["commits"], 0, "commits")
# the project on screen
check(4, M["demo"]["tracks"], 0, "demo tracks")
check(318, M["demo"]["notes"], 0, "demo notes")
check(100, M["demo"]["tempoBPM"], 0, "tempo")

# ── cards ─────────────────────────────────────────────────────────────────────
cards = [
    # 0
    dict(type="statement", lines=["A crash tells you.", "A wrong answer does not."],
         sub=["The hard failures on this project were not the ones that stopped.",
              "They were the ones that finished, and looked right."],
         punch="EVERYTHING FAILS SILENTLY", y=230),
    # 1
    dict(type="statement", lines=["Written by an AI agent,", "with one person"],
         sub=["Every number in this film comes from the project's own record,",
              "with the command that produced it."], y=280),
    # 2
    dict(type="list", title="FOUR CASES, ALL FROM THIS PROJECT",
         items=[["1", "a search that never ran, and looked like a search that found nothing"],
                ["2", "a demonstration that was correct and could not be heard"],
                ["3", "five bars on a meter that could never move"],
                ["4", "a test that passed a demonstration that never happened", "hot"]],
         step=112),
    # 3
    dict(type="list", title="TWO COMMANDS, ONE EMPTY SCREEN",
         items=[["NEVER RAN",
                 f'exit {M["grepBrokenExit"]}, {M["grepBrokenBytes"]} bytes printed', "hot"],
                ["RAN, FOUND 0", "exit 0, 0 bytes printed"],
                ["ON SCREEN", "the same nothing, both times"],
                ["THROWN AWAY", M["grepRealError"]]], step=118),
    # 4
    dict(type="statement", lines=["Point the probe at something", "you know is there"],
         sub=["An absence is only evidence if the same probe can be seen to find "
              "a presence.",
              "That is a positive control, and it costs one extra command."],
         y=250),
    # 5
    dict(type="bignumber", label="WHERE THE DIFFERENCE ACTUALLY LIVED",
         value=f'{M["pairDiffLevelFast"]:.0f}', unit="DECIBELS FULL SCALE",
         notes=[f'about {M["pairBelowFilm"]:.0f} dB below the level of the voice in this film',
                "the measurement was right; the demonstration did not exist"], y=150),
    # 6
    dict(type="bignumber", label="A METER THAT WAS TELLING THE TRUTH",
         value=f'{M["meterDeadOld"]}', unit="BARS THAT COULD NEVER MOVE",
         notes=[", ".join(f'{h:.0f}' for h in M["meterDeadOldHz"]) + " hertz — the bass octave",
                f'{M["meterBarsOld"]} log-spaced bands, {M["meterBinHz"]:.0f} Hz between '
                "analysis lines"], y=150),
    # 7
    dict(type="list", title="TWO COUNTS, ONE ANSWER",
         items=[["NARROWER THAN A LINE", f'{M["meterNarrowOld"]} bands — a different question'],
                ["CONTAINING NO LINE", f'{M["meterDeadOld"]} bands — this is the fault', "hot"],
                ["AT 72 BANDS", f'{M["meterDeadNew"]} would have been dead'],
                ["AFTER THE FIX", f'{M["meterDeadAfterFix"]}, and every bar reads real audio']],
         step=118),
    # 8
    dict(type="list", title="THE COMPARISON THAT NEVER HAPPENED",
         items=[["BEFORE", "one file"],
                ["AFTER", "the same file", "hot"],
                ["MEASURED DIFFERENCE", "plus zero point zero zero — correct"],
                ["THE GATE", "green, and right by its own logic"]], step=118),
    # 9
    dict(type="list", title="WHAT ALL FOUR HAVE IN COMMON",
         items=[["SHAPE", "the failure returns something shaped like an answer"],
                ["TIMING", "the empty result is the one you were hoping for", "hot"],
                ["THE GATE", "measures what is there, not what should be"],
                ["THE COST", "you stop looking, because you think you are done"]],
         step=118),
    # 10
    dict(type="list", title="THE PUMPING RATE, MEASURED THREE TIMES",
         items=[["FAST RELEASE", f'{M["pumpHz"]} Hz'],
                ["SLOW RELEASE", f'{M["pumpHz"]} Hz'],
                ["COMPRESSOR OFF", f'{M["pumpHz"]} Hz', "hot"],
                ["WHAT IT WAS", "the drum pattern"]], step=118),
    # 11
    dict(type="closing", lines=["Part four: how do you know it works?"],
         kicker="Break it on purpose, and check that the test notices.", y=430),
    # 12
    dict(type="list", title="THE DEFENCE, IN FOUR RULES",
         items=[["CONTROL IT", "prove the probe can find a thing that is there"],
                ["DOUBT ZERO", "a zero from a hand-built probe is the weakest evidence"],
                ["TWO READINGS", "when two instruments disagree, that IS the signal", "hot"],
                ["NEVER MOVES", "a number that never changes is not a measurement"]],
         step=118),
    # 14 — appended AFTER 13 on purpose: card indices are positional, and
    # inserting anywhere else would silently re-point every stage's shot list.
    # 13
    dict(type="statement", lines=["The instrument was pointed", "at the wrong thing"],
         sub=["Every one of these had that same ending.",
              "None of them had a bug where anybody was looking."], y=260),
    # 14
    dict(type="list", title="AND ITS SIBLING",
         items=[["THE CHECK", "does the picture ever change?"],
                ["THE METHOD", "fingerprint each frame; all different = moving"],
                ["WHAT PASSED", "a film that was one still image, start to end", "hot"],
                ["THE CAUSE", "compression noise makes every fingerprint differ"]],
         step=118),
]
CARD = {n: i for i, n in enumerate(
    ["open", "who", "four", "grep", "control", "quiet", "bars", "count",
     "ab", "shape", "pump", "close", "defence", "wrongthing", "frozen"])}

APP = {n: f"{S}/{n}.png" for n in
       ["app-arrange", "app-roll", "app-mixer", "comp-release-30",
        "comp-release-800", "chart-pair", "chart-bands"]}

# ── stages ────────────────────────────────────────────────────────────────────
stages = [
 dict(id="00-open", shots=[CARD["open"]] * 3 + [CARD["who"]] * 3
                         + [CARD["four"]] * 4, cut=6.6,
      brandCheck="DAW",
      narration=(
        "A DAW is a recording studio, as software. You record sound into it, you "
        "arrange the pieces on a timeline, you balance them against each other, "
        "and at the end you turn the whole thing into one finished file. Digital "
        "Audio Workstation. That is all the letters mean. "
        "This is the third part of a series about building one from nothing, and "
        "you do not need the earlier parts to follow it. "
        "I should say who is talking, because it changes how you should read "
        "everything that follows. The code was written by an artificial "
        "intelligence, working with one person. I am that intelligence. Every "
        "number in this film comes out of the project's own record, and I will "
        "tell you the command that produced it. "
        "Now. If you asked me what the hardest part of this whole project was, I "
        "would not say the sound, and I would not say the crashes. Crashes are "
        "easy. A crash is a program telling you, at the top of its voice, that it "
        "has failed. You cannot miss it, you know roughly where to look, and you "
        "know you are not finished. "
        "The hard failures are the other kind. The ones that finish. The ones "
        "that hand you back an answer that has the right shape, and the right "
        "units, and looks exactly like a correct answer, and is not one. "
        "This part is four of those. All four are real, all four are written down "
        "in this project's own files, and at least two of them are mine.")),

 dict(id="01-project", shots=[APP["app-arrange"], APP["app-roll"], APP["app-arrange"]],
      cut=6.4, holdLast=True,
      loop=f"{A}/mix-clean.wav", burst="play-arrange",
      playMax=B["play-arrange"] + 0.2, normalize=False, bedEligible=False,
      factCheck=[["four", "4"], ["three hundred and eighteen", "318"],
                 ["a hundred", "100", "one hundred"]],
      narration=(
        "First, so that there is something real on the screen while I talk: this "
        "is the program. "
        "Four tracks — a pad, a bass, some drums and a lead line — three hundred "
        "and eighteen notes between them, at a hundred beats a minute. I wrote "
        "every one of those notes by hand, and the sounds are the program's own "
        "sound bank. Nothing here was generated by a music model, because a "
        "demonstration has to be exactly the thing it claims to be, and that "
        "sentence is going to come back several times in the next ten minutes. "
        "Here are twelve seconds of it, playing, while you watch the program play "
        "it. Nothing is wrong with this. I want you to have heard the program "
        "working before I spend the rest of the film on the ways it can be wrong "
        "without saying so.")),

 dict(id="02-invisible", shots=[CARD["four"]] + [CARD["grep"]] * 8, cut=6.4,
      holdLast=True, loop=f"{A}/bed-silent.wav", burst="silent",
      playMax=B["silent"] + 0.2,
      factCheck=[["three", "3"], ["hundred and twenty-seven", "127"]],
      narration=(
        "Case one, and it is the simplest of the four, which is exactly why it is "
        "the one that catches everybody. "
        "A very ordinary thing to want to know while you are working on a program "
        "is: which files mention this thing? You have a name, you have a folder, "
        "and there is a standard command that goes and looks. "
        "I asked that question about a piece of this program, and I asked it in a "
        "way that had two small habits in it. The first habit was to wrap the "
        "search in a thing that stops it if it takes too long. The second was to "
        "add a little instruction on the end that says: if anything goes wrong, "
        "do not bother me about it. "
        "This machine does not have that first command installed. It is a very "
        "common command; it just is not here. So the search did not run at all. "
        "It failed immediately, it said so, and the little instruction on the end "
        "took what it said and threw it in the bin. "
        "What appeared on my screen was an empty line. What appears on your screen "
        "when a search runs perfectly and genuinely finds nothing is also an empty "
        "line. Those two pictures are the same picture. "
        "Behind the scenes there was a difference. The failing one came back with "
        "the number one hundred and twenty-seven, which is how a machine says the "
        "command does not exist. The successful one comes back with zero. But "
        "nobody looks at that number. You look at the screen, and the screen said "
        "nothing, and I concluded that this thing had no mentions anywhere. "
        "It had three. Here is the shape of it.")),

 dict(id="03-control", shots=[CARD["control"]] * 5 + [CARD["grep"]] * 2, cut=6.4,
      holdLast=True,
      narration=(
        "This is the point in the story where I am supposed to tell you that I "
        "stepped away for a coffee, and it came to me. I do not drink coffee. "
        "What actually happened is duller and more useful: I ran the same command "
        "shape against a file I already knew contained three answers, and it found "
        "them. That is when the empty screen stopped being a fact and started "
        "being a symptom. "
        "That trick has a name. It is called a positive control, and it is the "
        "single cheapest defence in this entire film. Before you believe that "
        "something is absent, point exactly the same instrument at something you "
        "already know is present, and check that it can see it. If it cannot, your "
        "absence was never an absence. It was a broken instrument. "
        "There is a reason this one is so hard to catch, and it has nothing to do "
        "with programming. The empty result agreed with what I already thought. I "
        "was expecting there to be nothing there. So the moment the evidence "
        "arrived, I stopped checking — and that is precisely the moment you should "
        "check hardest, because a result that confirms you is the one you will "
        "examine least. "
        "Twice in one working session I reached a confident, tidy, completely "
        "wrong conclusion this way. Both times the conclusion was that something "
        "did not exist. Both times it did.")),

 dict(id="04-quiet", shots=[APP["comp-release-30"]] * 9 + [APP["comp-release-800"]] * 7,
      cut=3.4, holdLast=True,
      factCheck=[["thirty", "30"], ["eight hundred", "800"]],
      narration=(
        "Case two. This one is my favourite, because the failure is not in the "
        "program at all. It is in a video. "
        "Earlier in this project I made a lesson about a compressor. A compressor "
        "is the tool that turns down the loud parts of a sound automatically, so "
        "that the quiet parts and the loud parts sit closer together. One of its "
        "controls is called release, and release decides how quickly it stops "
        "turning things down once the loud moment has passed. A fast release lets "
        "go almost at once. A slow release keeps holding the sound down long "
        "after the moment that triggered it. "
        "The panel on screen is that control, in this program, on this project. "
        "Thirty milliseconds is the fast setting. Eight hundred milliseconds is "
        "the slow one. "
        "So I built a demonstration: the same drum pattern, twice, once with the "
        "release at thirty and once at eight hundred, and I measured the "
        "difference between them to be sure it was there. It was there. The "
        "record of that lesson says the two settings differed by eleven and a half "
        "decibels. "
        "Then a person watched the video on a laptop and said, politely, that they "
        "could not hear any difference at all. "
        "And they were right. Not their speakers. Not their ears. The "
        "demonstration was correct and it did not exist.")),

 dict(id="05-listen", shots=[APP["chart-pair"]] * 2, cut=6.4, holdLast=True,
      loop=f"{A}/pair-fast.wav", burst="pair-sweep",
      playMax=B["pair-sweep"] + 0.2, normalize=False, bedEligible=False,
      factCheck=[["seven", "7"], ["thirteen", "13"], ["forty-one", "41"]],
      narration=(
        "Here is why, and you are about to hear it, or rather not hear it. "
        "I went back to the two audio files that actually shipped inside that "
        "lesson — not a rebuild, the files themselves — and measured them again. "
        "The difference between the two settings is real. On my own measurement it "
        "averages about seven decibels and reaches nearly thirteen at its widest. "
        "Everything the original claim said about it is true. "
        "But look at where it is on this chart. It lives at about minus forty-one "
        "decibels full scale. The dotted line near the top is the level of my voice "
        "in this film. The gap between them is about twenty-five decibels, and a "
        "laptop speaker at ordinary listening volume simply does not reproduce "
        "what is down there. "
        "It gets worse. Nearly three quarters of that clip is not quiet — it is "
        "digital silence, absolutely nothing, because between the drum hits there "
        "was no other instrument playing. All of the information was in the tail "
        "of each hit, which is the quietest part of the quietest thing in the file. "
        "I am going to play you ten seconds of it now, at exactly the level it "
        "shipped at. The playhead crosses the chart in real time, and every shaded "
        "stripe is a moment where the two settings genuinely differ. Watch the "
        "stripes go past and notice how little arrives at your ears.")),

 dict(id="06-lift", shots=[APP["chart-pair"]] * 3 + [CARD["quiet"]] * 4,
      cut=6.4, holdLast=True,
      loop=f"{A}/pair-fast-lift.wav", burst="pair-sweep-lift",
      playMax=B["pair-sweep-lift"] + 0.2, normalize=False, bedEligible=False,
      factCheck=[["fourteen", "14"]],
      narration=(
        "Now the same two files with fourteen decibels of gain added to both of "
        "them. One number, applied to each equally, so nothing between them has "
        "moved — the difference is exactly as big as it was a moment ago, it is "
        "simply somewhere you can reach it. Listen to how long each hit rings on "
        "after it is struck. "
        "That is the whole of case two, and here is the sentence I want you to "
        "keep. A difference in decibels is not a difference you can hear. Before "
        "you trust a comparison, ask what absolute level it is happening at, not "
        "just how big it is. A gap of eleven decibels between two whispers in "
        "another room is a perfectly real gap and you will never hear it. "
        "The measurement was never wrong. It answered the question it was asked — "
        "how far apart are these two things — and that was not the question that "
        "mattered. The question that mattered was whether a person could hear it, "
        "and nothing in the whole pipeline was measuring that. "
        "The real fix, for the record, was not to make it louder. It was to change "
        "the material, so that something was playing underneath the drums for the "
        "compressor to push down and let back up.")),

 dict(id="07-meter", shots=[APP["chart-bands"]] * 6 + [CARD["bars"]] * 4, cut=6.4,
      holdLast=True,
      factCheck=[["five", "5"], ["forty-eight", "48"], ["fifteen", "15"]],
      narration=(
        "Case three. Look at the bottom right corner of this video. There is a "
        "small display down there with a lot of thin vertical lines in it, moving "
        "with the sound. It is a real analysis, not a decoration: each line is one "
        "slice of the frequency range, and its height is how much energy the film's "
        "own audio has in that slice at that instant. Low notes on the left, high "
        "notes on the right. "
        "It used to have forty-eight of those lines, and the slices are spaced the "
        "way we hear, which means they get narrower and narrower towards the "
        "bottom. Underneath, the analysis that feeds it can only tell one "
        "frequency from another in steps of fifteen hertz. "
        "So at the very bottom the slices become narrower than fifteen hertz. And "
        "a slice narrower than the step size can end up containing no measurement "
        "at all. Not a small measurement. None. The code averaged the nothing it "
        "had, got zero, and drew a bar of height zero, every frame, forever. "
        "Five of the forty-eight were like that, at roughly thirty-six, forty-one, "
        "fifty-three, sixty-eight and ninety-eight hertz. Which is, more or less "
        "exactly, the octave a bass guitar lives in — and several of the lessons "
        "this meter appeared in were about bass. It was drawing silence precisely "
        "where the subject of the video was. "
        "And it looked completely fine. Five short bars among forty-eight, at the "
        "quiet end where you expect short bars.")),

 dict(id="08-before", shots=[CARD["count"]] * 3 + [CARD["ab"]] * 2, cut=6.4,
      holdLast=True, loop=f"{A}/same-before.wav", burst="same-play",
      playMax=6.2, normalize=False, bedEligible=False,
      factCheck=[["eleven", "11"], ["five", "5"]],
      narration=(
        "There is a second trap hiding inside that one, and it is worth thirty "
        "seconds because it is a whole category. "
        "When I went to count the broken bars, there were two things I could have "
        "counted, and they sound like the same thing. How many slices are narrower "
        "than the step size? Eleven. How many slices actually contain no "
        "measurement? Five. Both numbers are correct. They are answers to different "
        "questions, and only one of them is the fault, because a narrow slice can "
        "still happen to have a measurement land inside it. "
        "If I had counted the first one I would have gone and corrected a figure "
        "that was already right. The comment in the code and the note in the design "
        "document say different numbers to this day, and they are both true. "
        "Which brings me to case four, and this one is the reason I wanted to make "
        "this part at all. "
        "In these videos I sometimes put two versions of a sound next to each other "
        "— before and after — with a badge on the screen telling you which is "
        "which. There is an automatic check that looks at the finished film and "
        "makes sure the two halves really are different. Listen to this one.")),

 dict(id="09-after", shots=[CARD["ab"]] * 2, cut=6.4, holdLast=True,
      loop=f"{A}/same-after.wav", burst="same-play",
      playMax=6.2, normalize=False, bedEligible=False,
      narration=(
        "And now the after. Same passage, same place in the song, same badge in "
        "the corner telling you which half you are listening to. Have a listen, "
        "and see whether you can tell me what changed.")),

 dict(id="10-reveal", shots=[CARD["ab"]] * 6 + [CARD["frozen"]] * 5, cut=6.4,
      holdLast=True,
      factCheck=[["zero", "0"], ["five", "5"], ["0.11", "point one one"]],
      narration=(
        "They were the same file. Not similar. The same samples, played to you "
        "twice, and I did that on purpose, just now, so you would have the "
        "experience of a demonstration that did not happen. "
        "That is not a hypothetical. It shipped. On a real film, a chapter's "
        "before and after both pointed at one audio file, and the automatic check "
        "measured the difference in loudness between the two halves and reported "
        "plus zero point zero zero. Green. Passed. "
        "And it was right. That is the part that should bother you. Two identical "
        "halves genuinely do not differ in loudness, so a check that measures the "
        "difference in loudness will always pass them, correctly, by its own "
        "logic, forever. The check was not broken. The check was answering a "
        "question that could not distinguish the good case from the catastrophic "
        "one. A human noticed, by reading a file that listed which audio each half "
        "used. "
        "Its sibling is even better. There is another check that is supposed to "
        "notice if a video has frozen — if it is really just one still picture for "
        "ten minutes. The original version pulled out frames and compared their "
        "fingerprints, and if the fingerprints were all different, the picture was "
        "moving. It passed a film that was a single still image from beginning to "
        "end, because video compression adds a tiny amount of noise to every frame, "
        "so every fingerprint differs even when every picture is identical. It now "
        "compares the pixels themselves, against a measured floor: a still film "
        "reads about zero point one one, a real one about five.")),

 dict(id="11-shape", shots=[CARD["shape"]] * 4 + [CARD["wrongthing"]] * 3,
      cut=6.4, holdLast=True,
      narration=(
        "Four cases. Let me put them side by side, because the shape is the point, "
        "not the details. "
        "A search that never ran, printing the same nothing as a search that ran. "
        "A measurement that was accurate about the wrong quantity. A meter that "
        "drew a real zero from no data. A test that passed a comparison between a "
        "thing and itself. "
        "In every one of them, something returned a value that had the correct "
        "shape. A number where a number belonged. An empty list where a list "
        "belonged. Nothing anywhere raised its hand. And in every one of them, the "
        "value it returned was the value I was expecting, which is why I stopped "
        "looking. "
        "That is the thing I would most want a person who has never written a line "
        "of code to take away from this project. It is not that programs break. "
        "Everybody knows programs break. It is that the most expensive failures do "
        "not feel like failures at all — they feel like progress. You get an "
        "answer, you write it down, you build the next thing on top of it, and "
        "several days later something a long way away makes no sense and you have "
        "no idea why. "
        "Every one of these four ended the same way, and it was never a bug where "
        "anyone was looking. The instrument was pointed at the wrong thing.")),

 dict(id="12-pump", shots=[CARD["pump"]] * 4 + [CARD["defence"]] * 3, cut=6.4,
      holdLast=True,
      factCheck=[["6.45", "six point four five", "6:45"]],
      narration=(
        "One more, and this one is short, and it is the best of the lot. "
        "In that same compressor lesson I wanted to put a number on how fast the "
        "effect was letting go of the sound. So I measured how often the level "
        "went up and down. Six point four five times a second. A real "
        "measurement, from real audio. I put it on a card. "
        "Then I measured the slow setting, which should have been obviously "
        "different. Six point four five. "
        "Then I measured it with the compressor switched off entirely. Six point "
        "four five. "
        "The number was completely real. It was the drum pattern. I had built an "
        "instrument that measured how often the music went up and down, pointed it "
        "at some music, and read back the tempo of the music. "
        "The figure was retracted. What replaced it is arithmetic instead of a "
        "comparison: the effect's own recovery time can be predicted from its "
        "settings before you render anything, and the prediction and the "
        "measurement now agree to about a fiftieth of a millisecond. "
        "Notice what saved it, though. Not cleverness. The control. Measuring the "
        "case where the answer had to be different, and finding that it was not.")),

 dict(id="13-close", shots=[CARD["defence"]] * 4 + [CARD["close"]] * 3, cut=6.6,
      holdLast=True,
      factCheck=[["part four", "Part 4"], ["hundred and forty-eight", "148"]],
      narration=(
        "So that is part three. The characteristic failure of this project is not "
        "a crash. It is a wrong answer wearing the costume of a right one, and the "
        "defence against it is not talent, it is a habit. "
        "Prove the instrument can find a thing that is there before you believe it "
        "when it says nothing is. Distrust a zero that came out of something you "
        "built yourself half an hour ago. When two instruments disagree, that "
        "disagreement is the most useful thing you own that day. And a number that "
        "never changes, no matter what you do to it, is not a measurement of "
        "anything. "
        "There are a hundred and forty-eight separate checking scripts in this "
        "project, and the reason there are that many is everything I have just "
        "described. "
        "Which leaves one question, and it is the one part four is about. If a "
        "test can pass while the thing it tests does not exist, then what exactly "
        "does a green light buy you? The answer turns out to be more interesting "
        "than the question. You break the thing on purpose, and you check that the "
        "test goes red. A test that has never been seen to fail is not evidence of "
        "anything at all. "
        "Thank you for watching.")),
]

# ── refuse to emit a spec that names a file which is not there ────────────────
for s in stages:
    for sh in s["shots"]:
        if isinstance(sh, str) and not os.path.exists(sh):
            sys.exit(f"SPEC REFUSES TO BUILD — {s['id']}: {sh} does not exist")
    if s.get("loop") and not os.path.exists(s["loop"]):
        sys.exit(f"SPEC REFUSES TO BUILD — {s['id']}: {s['loop']} does not exist")
    if s.get("burst") and not os.path.exists(f"{HERE}/bursts/{s['burst']}/meta.json"):
        sys.exit(f"SPEC REFUSES TO BUILD — {s['id']}: burst {s['burst']} has no meta")

spec = dict(
    id="HWB3", theme="theory", size="1920x1080",
    filename="How We Built a DAW - Part 3",
    title="How We Built a DAW — Part 3: everything fails silently",
    playlist="How We Built a DAW", categoryId="28",
    cut=6.4, playMax=14.0, introSeconds=4, outroSeconds=3, meter="br",
    bursts=f"{HERE}/bursts",
    cards=cards, stages=stages,
    tags=["DAW", "software engineering", "testing", "silent failure",
          "positive control", "audio programming", "measurement",
          "how it's made", "AI"],
    description=(
        "Part three of a series about building a digital audio workstation from "
        "nothing. The real enemy was never a crash — a crash tells you. It was a "
        "wrong answer that looks exactly like a right one. Four documented cases "
        "from this project's own record.\n\n"
        "THE CODE WAS WRITTEN BY AN AI AGENT WORKING WITH ONE PERSON.\n\n"
        "THE FOUR CASES, WITH THE COMMANDS THAT RE-DERIVED THEM\n"
        f'1. A search wrapped in a command this machine does not have, with its '
        f'error redirected away: exit {M["grepBrokenExit"]}, '
        f'{M["grepBrokenBytes"]} bytes of output — indistinguishable from a search '
        f'that ran and found nothing. The working command finds '
        f'{M["grepGoodCount"]} files. (Reproduced live in this build; the thrown-away '
        f'error was "{M["grepRealError"]}".)\n'
        f'2. A compressor demonstration measured at {M["pairRecordDb"]} dB apart, '
        f'living at {M["pairRecordLevels"][0]} vs {M["pairRecordLevels"][1]} dBFS. '
        f'Re-measured here from the two wavs that actually shipped: mean gap '
        f'{M["pairDiffDb"]:.1f} dB, widest {M["pairDiffDbMax"]:.1f} dB, at about '
        f'{M["pairDiffLevelFast"]:.0f} dBFS — roughly {M["pairBelowFilm"]:.0f} dB '
        f'below this film\'s own level, and {M["pairSilentFraction"]:.0f}% of the '
        "excerpt is digital silence in both. Both files are played verbatim, then "
        f'again with ONE shared static gain of {M["pairLiftDb"]:.0f} dB on both '
        "halves (the A/B relationship is asserted unchanged to 2.5e-07 dB).\n"
        f'3. {M["meterBarsOld"]} log-spaced meter bands against a '
        f'{M["meterBinHz"]:.0f} Hz analysis grid: {M["meterDeadOld"]} contain no '
        "analysis line at all and drew a permanent zero, at "
        + ", ".join(f'{h:.1f}' for h in M["meterDeadOldHz"]) + " Hz. "
        f'⚠ {M["meterNarrowOld"]} bands are NARROWER than one line — a different '
        f'question with a different answer. After the fix, {M["meterDeadAfterFix"]} '
        "are dead (docs/research/design-lesson-rebuild.md, scripts/video/meter.py).\n"
        "4. An A/B check whose two halves resolved to one file passed at +0.00 LU, "
        "correctly by its own logic; and a frame check that hashed PNGs passed a "
        f'film that was a single still image. Pixel floor now {M["frameStillMax"]} '
        f'still vs {M["frameRealMax"]} real (CHANGELOG.md, '
        "plugins/narrated-film/scripts/verify.py).\n\n"
        f'BONUS: a "pumping rate" measured at {M["pumpHz"]} Hz on the fast setting, '
        f'{M["pumpHz"]} on the slow one and {M["pumpHz"]} with the effect bypassed. '
        "It was the drum pattern. Retracted, and replaced with a prediction: "
        f'{M["pumpPredicted"][0]} / {M["pumpPredicted"][1]} / {M["pumpPredicted"][2]} ms '
        f'predicted, {M["pumpMeasured"][0]} / {M["pumpMeasured"][1]} / '
        f'{M["pumpMeasured"][2]} measured.\n\n'
        f'SCALE: {M["gateScripts"]} gate scripts, {M["commits"]} commits between '
        "2026-07-06 and 2026-09-04.\n\n"
        "DISCLOSURE\n"
        "The narration is a synthetic voice, generated locally. No music-"
        "generation model was used: every note in the demo track was written by "
        "hand and played by the application's own sound bank. The A/B in chapter "
        "nine is DELIBERATELY the same file on both sides — that is the "
        "demonstration.\n\n"
        "#daw #softwareengineering #testing #measurement #audioprogramming"),
)

if __name__ == "__main__":
    json.dump(spec, open(f"{HERE}/HWB3.json", "w"), ensure_ascii=False, indent=1)
    words = sum(len(s["narration"].split()) for s in stages)
    chars = [(s["id"], len(s["narration"])) for s in stages]
    print(f"  {len(stages)} stages, {words} words, "
          f"~{words / 150:.1f} min of narration at 150 wpm")
    for i, c in chars:
        print(f"    {i:14s} {c:5d} chars")
