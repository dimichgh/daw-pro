#!/usr/bin/env python3
"""Emit the spec for "How We Built a DAW - Part 4" for shortsmith.py.

Code, not hand-typed JSON: every number on a CARD is injected from
MEASUREMENTS.json and can never drift from the file it was measured into. The
SPOKEN forms are typed by hand (figures must be spelled out or the speech model
reads them unreliably, and the content gate compares a TRANSCRIPT), so check()
and band() assert every spoken figure against the measured one and refuse to
emit a spec whose words and measurements have parted company.

⚠ THE HONESTY CONSTRAINT GOVERNS THIS FILM, and this part carries the ending:
§5 must say what is still broken. Every "still hard" item below is an OPEN
`- [ ]` line in docs/ROADMAP.md, checked by measure.py's openitem(), which
refuses to record an item it cannot find open. A fixed thing reported as broken
would be a fabricated war story in reverse.

⚠ WHAT THIS PART DOES NOT SPEND: Part 1 owns the architecture, the one command
surface, the definition of "a test", the program-vs-test line counts and the
223-vs-220 counting anecdote. Part 2 owns the render thread, the deadline, the
counter that lost forty-five per cent and the safety audit. Part 3 owns the four
silent failures and the POSITIVE CONTROL. This part owns FALSIFICATION — a
different idea, and the close says so — and the open problems.
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


def same(spoken, measured, what):
    if spoken != measured:
        sys.exit(f"SPEC REFUSES TO BUILD — {what}: narration {spoken!r} vs "
                 f"measurement {measured!r}")


# ── every figure the narration speaks, against the file it came from ─────────
# the plant
same([96, 256, 256, 4096], M["plantErrors"], "the four planted alignment errors")
check(4, M["plantTests"], 0, "four tests in the pin")
check(2, M["plantRedCount"], 0, "two tests reddened")
check(2, M["plantGreenCount"], 0, "two tests stayed green")
check(5, M["plantIssues"], 0, "five failures in total")
check(4096, M["pdcGapSamples"], 0, "the biggest plug-in's delay in samples")
band(85.0, 85.5, M["pdcGapMs"], "about eighty-five milliseconds")
check(0.5, M["plantMixValue"], 0.001, "half the height it should have been")
check(1393, M["plantLine"], 0, "the line number")
check(0, M["plantMarkerGone"], 0, "no trace of the plant left in the file")
check(1, M["plantMarkerLeft"], 0, "the original line is back")
check(0, M["plantGitClean"], 0, "git sees no change to that file")
# the suite
check(7924, M["suiteTests"], 0, "the number of tests")
check(709, M["suiteSuites"], 0, "the number of suites")
band(265, 280, M["suiteSeconds"], "about four and a half minutes")
same([], M["suiteFailedNames"], "no test failed")
check(148, M["gateScripts"], 0, "gate scripts")
check(105, M["commits"], 0, "commits")
check(131, M["openRoadmapItems"], 0, "open items")
# the vacuous check
same("true false", M["vacuityLive"], "the empty-list demonstration")
# the ladder
same([2165.1, 2167.1, 2165.1, 2167.1], M["live_gm_centroids"], "the flat ladder")
same([2370.7, 2489.0, 2556.8, 2557.3], M["live_gu_centroids"], "the rising ladder")
band(0.05, 0.12, M["live_gm_spread"], "under a tenth of one per cent")
band(7.5, 8.2, M["live_gu_spread"], "nearly eight per cent")
check(1, M["live_gm_groups"], 0, "one tone")
check(3, M["live_gu_groups"], 0, "three tones")
same("static", M["live_gm_verdict"], "the flat verdict")
same("live", M["live_gu_verdict"], "the moving verdict")
band(27.0, 29.0, M["liveRmsSpreadDb"], "about twenty-eight decibels louder")
check(26, M["centroidTestsBlind"], 0, "twenty-six tests")
band(6.4, 6.8, M["centroidTrueSpread"], "six and a half per cent")
band(0.25, 0.35, M["centroidBrokenSpread"], "three tenths of one per cent")
# the flam
band(85.0, 85.5, M["flamMeasuredGapMs"], "eighty-five milliseconds, measured")
same(False, M["flamIdentical"], "the two renders are not the same file")
check(6, M["flamOnsetsTogether"], 0, "six hits")
check(12, M["flamOnsetsApart"], 0, "twelve hits")
# capture
band(2.9, 3.2, M["captureFps"], "three frames a second")
check(3.5, M["captureRecordFps"], 0.01, "the recorded three and a half")
check(5, M["uiCaptures"], 0, "five screenshots")
check(3, M["uiDefectsFound"], 0, "three defects")
# the project
check(4, M["demo_tracks"], 0, "four tracks")
check(318, M["demo_notes"], 0, "three hundred and eighteen notes")
check(100, M["demo_tempoBPM"], 0, "a hundred beats a minute")
# the gate
check(0, M["gateExit"], 0, "the gate passes")

E = M["plantErrors"]

# ── cards ────────────────────────────────────────────────────────────────────
cards = [
    # 0
    dict(type="statement", lines=["A test that has never", "been seen to fail"],
         sub=["is not evidence that anything works.",
              "It is a light that has never been wired to anything."],
         punch="SO BREAK IT ON PURPOSE", y=210),
    # 1
    dict(type="statement", lines=["Written by an AI agent,", "with one person"],
         sub=["Every number in this film comes from the project's own record,",
              "with the command that produced it — and this one closes the series."],
         y=280),
    # 2
    dict(type="list", title="WHAT THIS LAST PART IS",
         items=[["THE METHOD", "how you check a program you cannot listen to"],
                ["THE PROOF", "plant a fault in the real code and watch it go red", "hot"],
                ["THE ENDING", "what is still broken, named out loud"]],
         step=118),
    # 3
    dict(type="list", title="GREEN IS THE WEAKEST COLOUR",
         items=[["IT PASSED", "the program did the right thing"],
                ["IT PASSED", "the test looked at the wrong thing"],
                ["IT PASSED", "the test could not have failed", "hot"],
                ["ON SCREEN", "the same green, all three times"]], step=118),
    # 4
    dict(type="bignumber", label="A CHECK OVER AN EMPTY LIST",
         value="true", unit="EVERY TIME, WHATEVER THE RULE",
         notes=["[].every(x => false) — the rule is never satisfiable and it still passes",
                "docs/research/2026-08-09-every-vacuity-census.md — a sweep for exactly this"],
         y=150, size=170),
    # 5
    dict(type="list", title="WHAT A PLUG-IN DELAY IS",
         items=[["THE JOB", "an effect reads audio in, and hands audio back"],
                ["THE COST", "some of them need a head start to do it"],
                ["THE RESULT", "that track comes out late — everything drifts apart", "hot"],
                ["THE CLAIM", "we slide it back into line, to the single sample"]],
         step=118),
    # 6
    dict(type="list", title="THE EXPERIMENT, IN THREE RUNS",
         items=[["RUN ONE", "the program as it ships — four tests, all green"],
                ["THE PLANT", f'one line of shipping code: the delay becomes 0', "hot"],
                ["RUN TWO", "the same four tests, on a program with one number wrong"],
                ["RUN THREE", "put the line back, and run them again"]], step=118),
    # 7
    dict(type="list", title="WHAT THE RED RUN SAID",
         items=[["LIMITER", f'out by {E[0]} samples'],
                ["DYNAMICS", f'out by {E[1]} samples'],
                ["MULTIBAND", f'out by {E[2]} samples'],
                ["TIME-PITCH", f'out by {E[3]} samples — {M["pdcGapMs"]:.0f} ms', "hot"]],
         step=118),
    # 8
    dict(type="statement", lines=["It failed by exactly", "the right amount"],
         sub=["A test that reddens for everything is a smoke alarm you take the "
              "battery out of.",
              "This one named the fault, in the units of the fault."], y=250),
    # 9
    dict(type="list", title="THE PROBE THAT CALLED A SAXOPHONE LIFELESS",
         items=[["THE QUESTION", "does playing harder change the TONE, or only the volume?"],
                ["THE ANSWER", "'no' — for a sound bank with three real tone layers", "hot"],
                ["THE TESTS", f'{M["centroidTestsBlind"]} of them, green before AND after the fix'],
                ["THE CONTROL", "a pure tone, which reads the same either way"]], step=112),
    # 10
    dict(type="statement", lines=["An explanation that", "dismisses a discrepancy"],
         sub=["is a load-bearing claim, and needs the same evidence as code.",
              "Mine said 'a few percent'. It was a factor of two to three."], y=250),
    # 11
    dict(type="list", title="A GATE THAT REFUSES TO SCORE",
         items=[["WHAT IT DOES", "counts one thing two independent ways"],
                ["THE TWIST", "it first checks that it can still find anything at all"],
                ["IF IT CANNOT", "it exits WITHOUT giving you a verdict", "hot"],
                ["WHY", "a broken gate saying 'fine' is worse than no gate"]], step=118),
    # 12
    dict(type="list", title="STILL HARD — ONE PLUG-IN CAN STOP EVERYTHING",
         items=[["WHAT HAPPENS", "a third-party plug-in can freeze the whole window"],
                ["WHAT WE DID", "made the freeze visible from outside the app"],
                ["WHAT WE DID NOT", "unfreeze it. The real fix is measured, and unbuilt", "hot"],
                ["THE RECORD", "docs/ROADMAP.md, three open items, quoted in full"]],
         step=112),
    # 13
    dict(type="list", title="STILL HARD — NOTHING HERE HAS EYES",
         items=[["NO GATE", "compares the words on screen to the words in the voice"],
                ["NO GATE", "sees a button drawn in the wrong state"],
                ["THE ONLY FIX", "somebody looks at it", "hot"],
                ["THE COST", f'{M["uiCaptures"]} screenshots of one panel found '
                             f'{M["uiDefectsFound"]} defects']], step=112),
    # 14
    dict(type="bignumber", label="THINGS THIS PROJECT KNOWS ARE NOT DONE",
         value=f'{M["openRoadmapItems"]}', unit="OPEN ITEMS, WRITTEN DOWN",
         notes=["every one of them is a line in docs/ROADMAP.md that starts with an empty box",
                "the list is not the embarrassing part. Not having one would be."],
         y=150),
    # 15
    dict(type="closing", lines=["That is how we built a DAW."],
         kicker="Four parts. One idea: measure it, then try to prove yourself wrong.",
         y=430),
    # 16
    dict(type="list", title="THE WHOLE SUITE, RUN FOR THIS FILM",
         items=[["TESTS", f'{M["suiteTests"]:,}'.replace(",", " ")],
                ["SUITES", f'{M["suiteSuites"]}'],
                ["FAILURES", "none"],
                ["TIME", f'{M["suiteSeconds"]:.0f} seconds', "hot"]], step=118),
    # ── 17.. appended AFTER 16 ON PURPOSE. Card indices are POSITIONAL, so
    # inserting anywhere else would silently re-point every stage's shot list.
    # These exist because reading slots.py's schedule showed EIGHT chapters
    # holding ONE still for 35-56 seconds — "a static frame with a voice over
    # it is the failure mode", and no gate can see it.
    # 17
    dict(type="list", title="WHY IT READ THE SAXOPHONE AS FLAT",
         items=[["THE JOB", "find the average brightness of a sound"],
                ["THE SLIP", "square the amounts before averaging them", "hot"],
                ["THE EFFECT", "the low harmonics drown out the high ones"],
                ["WHERE LAYERS LIVE", "in the high ones"]], step=118),
    # 18
    dict(type="statement", lines=["\"I looked and found", "nothing wrong\""],
         sub=["is a completely different sentence from \"I was unable to look\".",
              "Most software prints the same green tick for both."], y=250),
    # 19
    dict(type="list", title="THE FREEZE, AS THE RECORD HAS IT",
         items=[["SHIPPED", "you can ask a frozen app what is wrong, and it answers"],
                ["THE RECORD SAYS", "IT DOES NOT UNWEDGE ANYTHING", "hot"],
                ["THE REAL FIX", "run the plug-in in its own process — measured, unbuilt"],
                ["STILL OPEN", "three items, plus a transport that lies about playing"]],
         step=112),
    # 20
    dict(type="statement", lines=["The plug-in is not late.", "It is early enough"],
         sub=["Latency is the head start an effect needs to do its job at all.",
              "The bug is never the delay. The bug is failing to line it back up."],
         y=250),
    # 21
    dict(type="list", title="THE CHECK THAT MEASURED NOTHING",
         items=[["ASKED", "is every measurement under the limit?"],
                ["MEASUREMENTS", "none — nothing was recorded"],
                ["ANSWER", "yes, correctly, and about nothing at all", "hot"],
                ["ON SCREEN", "a pass, identical to a real one"]], step=118),
    # 22
    dict(type="list", title="WHAT I WROTE INSTEAD OF LOOKING",
         items=[["I SAID", "the two instruments differ by a few percent"],
                ["I SAID", "ours is the accurate one"],
                ["I SAID", "do not be alarmed"],
                ["IT WAS", "a factor of two to three", "hot"]], step=118),
]
CARD = {n: i for i, n in enumerate(
    ["rule", "who", "what", "green", "empty", "pdc", "experiment", "red",
     "exact", "probe", "comment", "gate", "wedge", "eyes", "ledger", "close",
     "suite", "why", "unable", "freeze", "early", "measured", "wrote"])}

IMG = {n: f"{S}/{n}.png" for n in
       ["app-arrange", "app-arrange2", "app-roll-bass", "app-roll-pad",
        "chart-plant", "chart-ladder", "term-green", "term-red",
        "term-controls", "term-restore"]}

# ── stages ───────────────────────────────────────────────────────────────────
# ⚠ LENGTH IS MEASURED, NOT ESTIMATED. spec.py's "N min at 150 wpm" runs long;
# Parts 2 and 3 both landed at 0.255 seconds of finished film per narration
# word (776 s / 3040 words and 763 s / 2999 words). The first draft of this
# stage list was 4224 words = a predicted 18 minutes against a 13-minute house
# standard, and was cut on that arithmetic rather than by feel.
stages = [
 dict(id="00-open", shots=[CARD["rule"]] * 3 + [CARD["who"]] * 3 + [CARD["what"]] * 3,
      cut=6.4, brandCheck="DAW",
      narration=(
        "A DAW is a recording studio, as software. You record sound into it, "
        "you arrange the pieces on a timeline, you balance them against each "
        "other, and at the end you turn the whole thing into one finished file. "
        "Digital Audio Workstation. This is the fourth and last part of a "
        "series about building one from nothing, and you do not need the "
        "earlier parts to follow it. I should say who is talking. The code was "
        "written by an artificial intelligence working with one person. I am "
        "that intelligence, and every number in this film comes out of the "
        "project's own record. This part answers the question the series has "
        "been walking towards. Here is a program that has to hit a deadline "
        "thousands of times a second, that fails quietly when it fails at all, "
        "and that nobody can check by listening except a person. How do you "
        "know it works? The answer is not a bigger pile of tests. I have a very "
        "large pile of tests, and it is not the answer. The answer is one "
        "sentence. A test you have never seen fail is not evidence that "
        "anything works. So you break the program on purpose, and check that "
        "the test notices. And then, because a series that ends on a victory "
        "lap is not worth much, I am going to tell you what is still broken.")),

 dict(id="01-project", shots=[IMG["app-arrange"], IMG["app-roll-bass"], IMG["app-arrange2"]],
      cut=6.4, holdLast=True,
      loop=f"{A}/mix-clean.wav", burst="play-arrange",
      playMax=B["play-arrange"] + 0.2, normalize=False, bedEligible=False,
      factCheck=[["four", "4"], ["three hundred and eighteen", "318"],
                 ["a hundred", "100", "one hundred"]],
      narration=(
        "First, so there is something real on screen while I talk: this is the "
        "program. Four tracks — a pad, a bass, some drums and a lead line — three "
        "hundred and eighteen notes between them, at a hundred beats a minute. I "
        "wrote every one of those notes by hand, and the sounds are the program's "
        "own sound bank. Nothing here was generated by a music model. "
        "Twelve seconds of it playing, so you know what the thing we are about to "
        "break actually does.")),

 dict(id="02-green", shots=[CARD["suite"]] * 3 + [CARD["green"]] * 4, cut=6.4,
      holdLast=True,
      factCheck=[["seven thousand nine hundred and twenty-four", "7924", "7,924"],
                 ["seven hundred and nine", "709"],
                 ["two hundred and seventy", "270"]],
      narration=(
        "Before this film was assembled I ran the whole test suite once, on "
        "this machine, so the number I am about to say is one I watched happen. "
        "Seven thousand nine hundred and twenty-four tests, in seven hundred "
        "and nine groups, in two hundred and seventy seconds. Nothing failed. "
        "That sentence is built to sound like an achievement, and I want to "
        "take it apart, because it is the most misleading kind of sentence in "
        "this subject. Here is what a green result actually tells you. It might "
        "mean the program did the right thing and the test noticed. It might "
        "mean the program did the wrong thing and the test was looking "
        "somewhere else. Or it might mean the test could not have failed at "
        "all, whatever the program did. All three print the same word. All "
        "three are green. And nothing in the colour, and nothing in the count, "
        "tells you which one you are looking at. The third sounds like a silly "
        "mistake a careful person would not make. It is not. It is very easy to "
        "make.")),

 dict(id="03-empty", shots=[CARD["empty"]] * 3 + [CARD["measured"]] * 3, cut=6.4, holdLast=True,
      loop=f"{A}/bed-vacuous.wav", burst="vacuous", playMax=B["vacuous"] + 0.2,
      narration=(
        "Suppose you want to check that a piece of audio never gets too loud. "
        "The natural way to write that is: every one of these measurements is "
        "under the limit. If any is over, complain. Good check. Now suppose "
        "that on some run the list of measurements is empty. Nothing was "
        "recorded — maybe the audio never arrived, maybe a setting was wrong, "
        "maybe the thing you were measuring never ran. Ask it again. Is every "
        "one of these measurements under the limit? There are no measurements. "
        "So there is no measurement over the limit. So the answer is yes. The "
        "check passes. It passes brightly, and it is not lying — it is "
        "answering exactly the question you asked. It simply did not measure "
        "anything, it has no way to tell you that, and from outside it looks "
        "precisely like a check that ran and was happy. That is not a "
        "hypothetical I invented for a video. Somebody here swept the whole "
        "body of checks for exactly that shape. So green is the weakest colour. "
        "Watch it happen.")),

 dict(id="05-pdc", shots=[CARD["pdc"]] * 4 + [CARD["early"]] * 4, cut=6.4, holdLast=True,
      narration=(
        "Here is the thing I am going to break, and it needs a minute of "
        "explaining, because the explanation is what makes the experiment mean "
        "anything. A plug-in is a small piece of software you drop onto a track "
        "to change how it sounds — a compressor, an equaliser, a reverb. Audio "
        "in, audio back. Some cannot hand it back immediately. To do the job at "
        "all they have to look a little way ahead — a limiter has to see a peak "
        "coming before it can catch it — so they hold the sound for a moment "
        "before letting it out. That is called latency, and it is not a bug. It "
        "is the cost of the work. Think what that does to music. You put one of "
        "these on the drums. The drums now come out a fraction of a second late "
        "and the bass does not, and your two tracks are no longer together. "
        "Three plug-ins on three tracks, and each drifts by a different amount. "
        "So every serious audio program corrects it. It asks each plug-in how "
        "long it holds the sound, works out the worst case, and delays "
        "everything else by that much, so the whole thing lands back in line. "
        "The claim this project makes is a strong one. Lined up to the single "
        "sample. Four tests say so, one for each of four real plug-ins on this "
        "computer. And those four tests were green, which by everything I have "
        "just said means nothing yet.")),

 dict(id="06-flam", shots=[CARD["pdc"], IMG["chart-plant"]], cut=6.4, holdLast=True,
      loop=f"{A}/flam-together-play.wav", burst="flam-together",
      playMax=B["flam-together"] + 0.2, normalize=False, bedEligible=False,
      factCheck=[["four thousand and ninety-six", "4096", "4,096"],
                 ["eighty-five", "85"]],
      narration=(
        "First let me make the size of the error something you can hear, because "
        "otherwise it is just a number. "
        "The largest of those four plug-ins holds the sound for four thousand and "
        "ninety-six samples. At forty-eight thousand samples a second, that is "
        "about eighty-five milliseconds. It sounds like nothing written down. "
        "It is not nothing. Here are six wooden clicks played by the program, one "
        "every one and a fifth seconds. This is them landing together.")),

 dict(id="07-apart", shots=[IMG["chart-plant"]], cut=6.4, holdLast=True,
      loop=f"{A}/flam-apart-play.wav", burst="flam-apart",
      playMax=B["flam-apart"] + 0.2, normalize=False, bedEligible=False,
      narration=(
        "And this is the same click, twice, eighty-five milliseconds apart. Same "
        "volume, same sound, everything the same except the timing. Drummers have "
        "a name for it. They call it a flam. "
        "That is what an uncorrected plug-in delay does to your music, and now you "
        "know what you are listening for.")),

 dict(id="08-plant", shots=[CARD["experiment"]] * 3 + [IMG["term-green"]] * 3, cut=6.4,
      holdLast=True, loop=f"{A}/bed-falsify.wav", burst="falsify",
      playMax=B["falsify"] + 0.2,
      factCheck=[["four", "4"], ["thirteen ninety-three", "1393", "1,393"]],
      narration=(
        "So. The experiment. "
        "Somewhere in this program is one line that reads how long a plug-in holds "
        "the sound. Line thirteen ninety-three of a file called PlaybackGraph. "
        "Everything I have just described depends on that one number being right. "
        "I ran the four tests first, exactly as the program ships. All four "
        "passed. That is the picture on your screen, and it is the picture that "
        "means nothing yet. "
        "Then I opened that file and replaced that number with zero. Not a copy of "
        "the file. Not a special test version. The actual code that makes sound, "
        "told that every plug-in in the world holds audio for no time at all. "
        "And then I ran the same four tests again, without changing one character "
        "of any test. If those tests are real they should now fail — and not just "
        "fail, but fail in a way that describes the fault I introduced.")),

 dict(id="09-red", shots=[IMG["term-red"]] * 4 + [IMG["chart-plant"]] * 4, cut=6.4,
      holdLast=True,
      factCheck=[["ninety-six", "96"], ["two hundred and fifty-six", "256"],
                 ["four thousand and ninety-six", "4096", "4,096"]],
      narration=(
        "There it is. Read the numbers, because the numbers are the point. The "
        "limiter test failed by ninety-six samples. The dynamics processor by "
        "two hundred and fifty-six. The multiband compressor by two hundred and "
        "fifty-six. The time-pitch plug-in by four thousand and ninety-six. Now "
        "compare those with what I told you a few minutes ago. Ninety-six. Two "
        "hundred and fifty-six. Two hundred and fifty-six. Four thousand and "
        "ninety-six. Every test failed by exactly the delay of its own plug-in. "
        "Not roughly. Not within a tolerance. Exactly. A smoke alarm just goes "
        "off; this told me what was wrong in the units of the thing that was "
        "wrong. And the last of them is the flam you just heard. The test that "
        "checks the mix reported the drum hit coming out half the height it "
        "should have been, because instead of two copies landing on top of each "
        "other and adding up, they landed eighty-five milliseconds apart.")),

 dict(id="10-controls", shots=[IMG["term-controls"]] * 4 + [CARD["exact"]] * 3, cut=6.4,
      holdLast=True,
      factCheck=[["four", "4"], ["two", "2"]],
      narration=(
        "There is a second half to this, and it is the half people skip. Four "
        "tests ran. Two went red. Which means two stayed green, under a program "
        "I had deliberately broken. That sounds like a failure of those two. It "
        "is the opposite. The first checks that the whole thing produced any "
        "sound at all, at the right moment, before anything else is "
        "interpreted. It has to stay green — because if it goes red the "
        "experiment measured silence, and a measurement of silence is not a "
        "measurement of anything. The second is a plug-in with no delay, a "
        "simple filter that hands the audio straight back. It should get no "
        "correction, so breaking the correction should do nothing to it. It "
        "stayed green, and that is how I know the two red results came from the "
        "thing I broke and not from some general wobble I caused by touching "
        "the file. A test that reddens for everything is a test you learn to "
        "ignore. You want one that goes red for the fault and stays green for "
        "what the fault did not touch.")),

 dict(id="11-restore", shots=[IMG["term-restore"]] * 5 + [IMG["term-green"]] * 2, cut=6.4, holdLast=True,
      factCheck=[["four", "4"]],
      narration=(
        "Then I put the line back. This is where I am supposed to tell you I "
        "stepped away for a coffee and it all came together. I do not drink "
        "coffee. What actually happened is duller and more important: I "
        "checked, four separate ways, that I had genuinely undone what I did. "
        "The file is byte for byte identical to the copy I made before "
        "starting. The marker I left in the planted line appears nowhere. The "
        "original line is back, once. And the version control system, asked "
        "whether that file has changed at all, says nothing. Four checks, "
        "because the one thing I could not accept is a film about deliberately "
        "breaking a program that quietly leaves it broken. And not one of the "
        "four is the return code of the command that put it back — a command "
        "that fails silently returns success too. Then the same four tests, one "
        "more time. All green. And now that green is worth something, because "
        "it is the same green that was there at the start of this chapter, and "
        "in between I watched it go red for a reason I chose.")),

 dict(id="12-probe", shots=[CARD["probe"]] * 4 + [IMG["chart-ladder"]] * 3, cut=6.4,
      holdLast=True,
      factCheck=[["twenty-six", "26"], ["three", "3"]],
      narration=(
        "Here is a second case, and a more uncomfortable one, because here the "
        "tests were not merely useless. They actively agreed with a wrong "
        "answer. When a real player plays a note harder it gets louder — but it "
        "also changes tone. Cheap instrument sounds only do the first: volume "
        "up, tone identical, and it sounds like a toy. I cannot hear, so I "
        "built a measurement for it. Play the same note at four increasing "
        "strengths; measure how much louder it got, and how much brighter. A "
        "lot of loudness with no brightness change means the instrument is a "
        "volume knob. Twenty-six tests covered it, and all of them passed. Then "
        "somebody pointed it at two real sound banks — the basic one built into "
        "this computer, and a free one with genuine layers recorded at "
        "different playing strengths. It said the same thing about both: "
        "neither of them changes tone. It called a saxophone with three "
        "separately recorded layers lifeless.")),

 dict(id="13-ladder", shots=[IMG["chart-ladder"]] * 4 + [CARD["why"]] * 2, cut=6.4, holdLast=True,
      # ⚠ THE WHITELIST IS COMPARED TO A TRANSCRIPT, NOT TO THE SCRIPT. The
      # narration says "twenty-one hundred and sixty-five hertz" and Whisper
      # writes "2165 hertz", so a whitelist of {"twenty-one hundred","2100"}
      # matches nothing and shortsmith REFUSED TO SHIP on a take that was
      # word-perfect. The gate was right; the whitelist was wrong.
      factCheck=[["twenty-one hundred", "2100", "2,100", "2165", "2167"],
                 ["twenty-eight", "28"], ["three", "3"]],
      narration=(
        "The chart on screen is that measurement, run again today, live, on the "
        "program, while I was making this film. On the left is the sound bank "
        "built into the computer. Twenty-one hundred and sixty-five hertz. "
        "Twenty-one hundred and sixty-seven. Twenty-one hundred and sixty-five. "
        "Twenty-one hundred and sixty-seven. Flat: under a tenth of one per "
        "cent of movement, across notes played four times as hard. On the right "
        "is the free one, on the same scale. Twenty-three seventy, twenty-four "
        "eighty-nine, twenty-five fifty-seven, twenty-five fifty-seven. Nearly "
        "eight per cent, resolving into three distinct tones — exactly the "
        "three layers somebody recorded. Both got about twenty-eight decibels "
        "louder across those four strengths. Only one of them changed. So what "
        "had gone wrong? The measurement averaged the brightness with the wrong "
        "weighting. It squared the amounts before averaging, which hides the "
        "high harmonics under the low ones — and the high harmonics are exactly "
        "where the layers differ.")),

 dict(id="14-blind", shots=[CARD["probe"]] * 3 + [CARD["comment"]] * 3, cut=6.4,
      holdLast=True,
      factCheck=[["twenty-six", "26"]],
      narration=(
        "That measurement had a self-check built into it. Before giving you an "
        "answer it feeds itself a signal it already knows the answer for, and "
        "refuses to report anything if it cannot get that right — exactly the "
        "discipline the previous part of this series was about. Now the part "
        "worth carrying away. The self-check could not possibly have caught "
        "this. The signal it feeds itself is a pure tone — one single frequency "
        "— and a signal with only one frequency comes out at the same answer "
        "under both the right weighting and the wrong one. So the control "
        "proved the instrument could tell one pitch from another. Nothing "
        "proved it could handle a sound made of many frequencies at once — "
        "which is every real sound there is. A control built from a signal "
        "simpler than the thing you are testing can be blind to an entire class "
        "of error while passing perfectly. All twenty-six tests passed before "
        "the fix and all twenty-six after it. Only a real instrument disagreed.")),

 dict(id="15-comment", shots=[CARD["comment"]] * 3 + [CARD["wrote"]] * 3, cut=6.4, holdLast=True,
      narration=(
        "And here is the second thing I would tell you about over a coffee, if "
        "I drank coffee. This one stings. A few hours before any of that was "
        "found, I had noticed that two different instruments disagreed about "
        "the brightness number. I looked into it. And then I wrote a comment in "
        "the source code explaining the disagreement away. I said it was a few "
        "percent. I said ours was the accurate one. I pointed at the pure-tone "
        "self-check as the reason to believe that, and told whoever read it "
        "next not to be alarmed. Every clause of that was defensible. The "
        "conclusion was wrong — the gap was a factor of two to three — and the "
        "comment was load-bearing in the wrong direction, because it existed "
        "specifically to stop the next person looking. An explanation that "
        "dismisses a discrepancy is a claim, and it needs the same evidence as "
        "a piece of code. Two instruments disagreeing is not noise to be tidied "
        "away. It is the signal.")),

 dict(id="16-gates", shots=[CARD["gate"]] * 4 + [CARD["unable"]] * 3, cut=6.4, holdLast=True,
      factCheck=[["a hundred and forty-eight", "148"]],
      narration=(
        "Underneath the tests there is a second layer, and it is the one I lean "
        "on hardest: a hundred and forty-eight small scripts that run over the "
        "whole project at once, asking questions no single test can ask. One is "
        "worth describing exactly, because its design is this whole film "
        "compressed into one script. Its job is to check a count, and it "
        "derives that count two independent ways and compares them — already "
        "better than counting once. But before it scores anything, it checks "
        "that its own method still works: that the pattern it searches with can "
        "still find something it knows is there. And if that check fails, it "
        "does not say everything is fine, and it does not say everything is "
        "broken. It exits without giving you a verdict at all. There is an "
        "enormous difference between I looked and found nothing wrong, and I "
        "was unable to look. Most software collapses those into the same green "
        "tick.")),

 dict(id="17-wedge", shots=[CARD["wedge"]] * 5 + [CARD["freeze"]] * 4, cut=6.4, holdLast=True,
      narration=(
        "Which brings me to the end, and the part I care most about getting "
        "right. What is still wrong with this thing. The first is the worst. "
        "This program can host plug-ins made by other people, which is most of "
        "what makes a music program useful. And one kind, when asked to load, "
        "can take hold of the part of the program that draws the window and not "
        "give it back for minutes. Everything freezes. The audio keeps playing, "
        "which is almost funny, but nothing responds. What we built in response "
        "was not a fix. It was honesty. There is now a second door into the "
        "program that does not need the frozen part, so if you ask what is "
        "wrong while it is stuck, it answers and tells you how long it has been "
        "stuck. The record of that work says, in capital letters, that it makes "
        "the freeze legible and does not unfreeze anything. A status light is "
        "very easy to mistake for a repair. The real fix is to run those "
        "plug-ins in a separate process. Somebody measured whether that was "
        "feasible and it came out far cheaper than we had assumed. And then it "
        "was not built. It sits in the record as an open item with the "
        "measurement attached. And a second is still open, quieter: the program "
        "reporting that it was playing while the playhead did not move and the "
        "meters fell to silence.")),

 dict(id="18-eyes", shots=[CARD["eyes"]] * 4 + [IMG["app-arrange"]] * 3, cut=6.4, holdLast=True,
      loop=f"{A}/bed-slowcap.wav", burst="slowcap", playMax=B["slowcap"] + 0.2,
      normalize=False, bedEligible=False,
      factCheck=[["three", "3"], ["five", "5"]],
      narration=(
        "The second thing still hard is that nothing in this entire apparatus "
        "has eyes. Not one of those hundred and forty-eight scripts can look at "
        "a picture. Nothing compares the words printed on the screen to the "
        "words being spoken over them. Nothing notices a switch drawn in the "
        "off position while everything around it says on — which happened, on a "
        "real panel, and was found by a person opening the screenshot. Five "
        "screenshots of one panel turned up three separate defects that every "
        "test, every search and every review had passed. The only known fix is "
        "that somebody looks. That is not a satisfying engineering answer and I "
        "will not dress it up as one. Here is a smaller one that bit this very "
        "film. The way I photograph the program takes about three frames a "
        "second. Not thirty. Three. So I cannot film anything that moves. What "
        "you are about to watch is the program playing, filmed at that rate, "
        "this evening. It is not a broken video. That is what three frames a "
        "second looks like.")),

 dict(id="19-close", shots=[CARD["ledger"]] * 4 + [CARD["close"]] * 4, cut=6.4,
      holdLast=True,
      # ⚠ brandCheck ON THE CLOSE AS WELL AS THE OPEN. The first take of this
      # stage said "What a day out we is" for "What a DAW is" — the series' key
      # term, mangled in the closing summary — and scored 0.98 with every fact
      # present, because four syllables cannot move an aggregate over 200 words.
      brandCheck="DAW",
      factCheck=[["a hundred and thirty-one", "131"]],
      narration=(
        "There are a hundred and thirty-one of these written down. A hundred "
        "and thirty-one lines in this project's plan that begin with an empty "
        "box, each one a thing somebody knows is missing or wrong. There are "
        "two ways to read that number and only one is right. It is not a "
        "confession, and it is not a boast. It is the honest shape of a piece "
        "of software about two months old that is being used for real. The list "
        "is not the embarrassing part. Not having one would be. So — four "
        "parts. What a DAW is, and the one decision it all hangs on. Why the "
        "deadline the sound has to meet is the hardest constraint in the "
        "building. Why the failures that hurt are the ones that hand you a "
        "wrong answer wearing the costume of a right one. And this one: that a "
        "passing test earns your trust only if you have watched that same test "
        "fail. The same idea from four directions. Measure it rather than "
        "asserting it, then try to prove yourself wrong — the only move in the "
        "whole discipline that can tell you something you did not already "
        "believe. It took one person and one machine about two months. It is "
        "not finished, and I have told you exactly how. Thank you for watching.")),
]

spec = dict(
    id="HWB4", theme="theory", size="1920x1080",
    filename="How We Built a DAW - Part 4",
    title="How We Built a DAW — Part 4: how do you know it works? Break it on purpose",
    playlist="How We Built a DAW", categoryId="28",
    cut=6.4, playMax=18.0, introSeconds=4, outroSeconds=3, meter="br",
    bursts=f"{HERE}/bursts",
    cards=cards, stages=stages,
    tags=["DAW", "software engineering", "testing", "falsification",
          "plugin delay compensation", "audio programming", "measurement",
          "how it's made", "AI"],
    description=(
        "Part four, the last, of a series about building a digital audio "
        "workstation from nothing. A test you have never seen fail is not "
        "evidence. So this one plants a fault in shipping code and watches four "
        "separate tests go red at exactly their own plug-in's delay — and then "
        "says what is still broken.\n\n"
        "THE CODE WAS WRITTEN BY AN AI AGENT WORKING WITH ONE PERSON.\n\n"
        "THE EXPERIMENT, RUN IN THIS BUILD\n"
        f'Line {M["plantLine"]} of {M["plantFile"]} reads a hosted plug-in\'s '
        f'latency. It was replaced with 0 and `./scripts/test.sh --filter '
        f'PDCHostedAURender` was re-run: {M["plantRedCount"]} of {M["plantTests"]} '
        f'tests reddened with {M["plantIssues"]} failures, at alignment errors of '
        + " / ".join(str(e) for e in M["plantErrors"]) +
        f' samples — each exactly its own unit\'s latency — and the mix leg at '
        f'{M["plantMixValue"]} instead of 1.0. ⭐ The two CONTROLS stayed green: the '
        "positive control (every render makes signal) and the negative control (a "
        "0-latency AU gets no compensation). The line was restored and the restore "
        f'proved four ways: cmp exit 0, planted marker {M["plantMarkerGone"]}, '
        f'original line {M["plantMarkerLeft"]}, git porcelain '
        f'{M["plantGitClean"]} lines. Logs kept beside the film.\n\n'
        f'{M["pdcGapSamples"]} samples at 48 kHz is {M["pdcGapMs"]:.1f} ms. The '
        "film plays six wooden clicks together and then the same click twice "
        f'{M["flamMeasuredGapMs"]:.0f} ms apart (measured), one shared static gain '
        "on both halves so the demonstration is timing and not level.\n\n"
        "THE SECOND CASE — A CONTROL SIMPLER THAN THE SIGNAL\n"
        f'A liveness probe called a genuinely velocity-layered saxophone lifeless. '
        f'{M["centroidTestsBlind"]} tests passed before AND after the fix. Its '
        "self-check measured a PURE SINE, which reads identically under both the "
        "power-weighted (wrong) and magnitude-weighted (right) spectral centroid. "
        f'It compressed a true {M["centroidTrueSpread"]} % spread to '
        f'{M["centroidBrokenSpread"]} %. Re-measured LIVE on staging for this film: '
        f'Apple GM DLS ' + " / ".join(f"{x:.0f}" for x in M["live_gm_centroids"]) +
        f' Hz ({M["live_gm_spread"]} %, {M["live_gm_verdict"]}) vs GeneralUser GS ' +
        " / ".join(f"{x:.0f}" for x in M["live_gu_centroids"]) +
        f' Hz ({M["live_gu_spread"]} %, {M["live_gu_verdict"]}, '
        f'{M["live_gu_groups"]} timbre groups), both across ~'
        f'{M["liveRmsSpreadDb"]:.0f} dB of level.\n\n'
        "WHAT IS STILL HARD — every one an OPEN item in docs/ROADMAP.md\n"
        "· A third-party plug-in can wedge the main actor for minutes (m23-av). The "
        "shipped work makes the wedge LEGIBLE and explicitly DOES NOT UNWEDGE "
        "ANYTHING; out-of-process hosting was measured feasible and is unbuilt "
        "(m23-av-3), plus two further open legs (m23-av-1, m23-av-2).\n"
        "· A transport reported `playing` while the playhead stayed frozen and the "
        "meters decayed to silence — ruled out as the wedge, still open (m23-cb).\n"
        f'· Nothing here has eyes: no gate compares words on screen to words in the '
        f'voice. {M["uiCaptures"]} captures of one panel found {M["uiDefectsFound"]} '
        "defects every test, grep and review had passed.\n"
        f'· debug.captureUI runs at {M["captureFps"]} fps measured in this build '
        f'({M["captureMs"]:.0f} ms per frame; the record says '
        f'{M["captureRecordFps"]}), so it cannot film motion.\n'
        f'· {M["openRoadmapItems"]} open items in total.\n\n'
        f'SCALE, RUN FOR THIS FILM: {M["suiteTests"]} tests in {M["suiteSuites"]} '
        f'suites, {M["suiteSeconds"]:.1f} s, zero failures. {M["gateScripts"]} gate '
        f'scripts. {M["commits"]} commits. {M["sourceLines"]:,} lines of program '
        f'against {M["testLines"]:,} lines of test.\n\n'
        "DISCLOSURE\n"
        "The narration is a synthetic voice, generated locally. No music-"
        "generation model was used: every note in the demo track was written by "
        "hand and played by the application's own sound bank. ⚠ THE 30 fps FOOTAGE "
        "OF THE APP PLAYING WAS FILMED FOR PART 3 EARLIER THE SAME DAY, of this "
        "same project on this same staging instance: the screen was LOCKED "
        "throughout this build and a locked screen delivers no frames to the "
        "recorder. The stuttering shot in the closing chapter IS filmed in this "
        "build, at its real measured rate, and the narration says so.\n\n"
        "#daw #softwareengineering #testing #measurement #audioprogramming"),
)

if __name__ == "__main__":
    json.dump(spec, open(f"{HERE}/HWB4.json", "w"), ensure_ascii=False, indent=1)
    words = sum(len(s["narration"].split()) for s in stages)
    print(f"  {len(stages)} stages, {words} words, "
          f"~{words / 150:.1f} min of narration at 150 wpm  "
          f"(⚠ this estimate runs ~1.5x long; judge from the built film)")
    for s in stages:
        print(f"    {s['id']:14s} {len(s['narration']):5d} chars"
              + (f"   +play {s.get('burst','')}" if s.get("loop") else ""))
