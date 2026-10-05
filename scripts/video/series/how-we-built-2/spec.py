#!/usr/bin/env python3
"""Emit the spec for "How We Built a DAW — Part 2" for shortsmith.py.

Code, not hand-typed JSON: every number on a CARD is injected from
MEASUREMENTS.json and can never drift from the file it was measured into. The
SPOKEN forms are typed by hand (figures must be spelled out or the speech model
reads them unreliably, and the content gate compares a TRANSCRIPT), so check()
asserts every spoken figure against the measured one and refuses to emit a spec
whose words and measurements have parted company.

⚠ THE HONESTY CONSTRAINT GOVERNS THIS FILM. The central demonstration is a
CONSTRUCTED dropout — the engine was not stalled, starved or crashed — and the
narration says so in the same breath as it plays it.

⚠ WHAT THIS PART DOES NOT SPEND: Part 1 owns the architecture and the "more
test than program" hook; Part 3 owns silent failure and its four documented
cases; Part 4 owns falsification testing and the gate corpus. The one anecdote
used here is Part 2's own — the counter, and the re-attribution that followed
its fix.
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
B = json.load(open(f"{HERE}/bursts.json"))
S, A = f"{HERE}/shots", f"{HERE}/audio"
D = M["dropout"]


def check(spoken, measured, tol, what):
    if abs(spoken - measured) > tol:
        sys.exit(f"SPEC REFUSES TO BUILD — {what}: the narration says {spoken} "
                 f"but the measurement is {measured}")


def band(lo, hi, measured, what):
    if not (lo <= measured <= hi):
        sys.exit(f"SPEC REFUSES TO BUILD — {what}: the narration implies "
                 f"{lo}..{hi} but the measurement is {measured}")


# ── every figure the narration speaks, against the file it came from ───────
check(512, M["blockFrames"], 0, "block size")
check(48_000, M["sampleRate"], 0, "sample rate")
check(10.67, M["blockMilliseconds"], 0.005, "the deadline in ms")
# spoken as "about ten and a half thousandths of a second"
band(10.0, 11.0, M["blockMilliseconds"], "ten and a half thousandths")
# spoken: "more than three thousand five hundred times ... none of them late"
band(3_400, 3_900, M["windowCallbacks"], "three and a half thousand blocks")
check(0, M["windowOverruns"], 0, "late blocks in the measured window")
band(6.0, 7.2, M["windowSeconds"], "about six and a half seconds")
# spoken: "the slowest single one took under three thousandths of a second"
band(0.2, 3.0, M["peakCallbackMs"], "slowest block under three ms")
# spoken: "typically it used less than two percent of the time it had"
band(0.0, 2.0, M["averageLoadPercent"], "under two percent of the budget")
check(6, round(M["renderBlocks"]), 0, "six render blocks")
# the demonstration
check(3, len(D["dropouts"]), 0, "three dropouts")
check(512, D["blockFrames"], 0, "dropout block size")
check(1536, D["differingFrames"], 0, "differing frames")
check(12, D["excerptSeconds"], 0, "excerpt seconds")
for i, want in enumerate([2.5, 5.5, 8.5]):
    band(want - 0.1, want + 0.1, D["dropouts"][i]["startSeconds"], f"dropout {i+1}")
# the audit
check(47, M["auditSites"], 0, "audit sites")
check(8, M["auditFamilies"], 0, "audit families")
check(0, M["auditViolations"], 0, "audit violations")
check(6, M["auditWatch"], 0, "audit watch items")
if M["auditDate"] != "2026-07-10":
    sys.exit(f"SPEC REFUSES TO BUILD — audit date is {M['auditDate']}")
# the counter
check(45, M["counterLossPercent"], 0, "percent of counts lost")
check(8, M["counterThreads"], 0, "threads in the contention test")
check(20_000, M["counterPerThread"], 0, "records per thread")
check(160_000, M["counterTotal"], 0, "total records")
# the re-attribution
check(597, M["perfDebug16"], 0, "debug calls per second at 16 tracks")
check(1_394, M["perfRelease16"], 0, "release calls per second at 16 tracks")
# the load profile
check(41, M["loadTracks"], 0, "tracks in the load profile")
check(14, M["loadCorePercent"], 0, "percent of one core")
check(22.9, M["loadOfflineRealtime"], 0.05, "times realtime offline")
# the project on screen
check(5, M["demo"]["tracks"], 0, "demo tracks")
check(228, M["demo"]["notes"], 0, "demo notes")
check(100, M["demo"]["tempoBPM"], 0, "tempo")
# corpus, spoken as "about thirty thousand lines"
band(29_000, 31_000, M["engineLines"], "thirty thousand engine lines")

# ── cards ──────────────────────────────────────────────────────────────────
cards = [
    # 0
    dict(type="statement", lines=["Sound is due", "on a schedule"],
         sub=["Miss it and the listener hears a click.",
              "Everything else in the program bends around that."],
         punch="THE RENDER THREAD IS SACRED", y=230),
    # 1
    dict(type="bignumber", label="THE DEADLINE FOR ONE BLOCK",
         value=f'{M["blockMilliseconds"]:.2f}', unit="THOUSANDTHS OF A SECOND",
         notes=[f'{M["blockFrames"]} numbers, and {M["sampleRate"]:,} of them go by every second',
                "read off the running program, not off a document"], y=150),
    # 2
    dict(type="statement", lines=["Written by an AI agent,", "with one person"],
         sub=["Every number in this film comes from the project's own record,",
              "with the command that produced it."], y=280),
    # 3
    dict(type="list", title="HOW THE BROKEN FILE WAS MADE",
         items=[["1", "render the project to a file, correctly"],
                ["2", f'overwrite {len(D["dropouts"])} blocks of {D["blockFrames"]} numbers with zero'],
                ["3", "play the two files back to back"],
                ["NOT", "crash, stall or starve the audio engine", "hot"]], step=112),
    # 4
    dict(type="list", title="FORBIDDEN ON THE AUDIO THREAD",
         items=[["ASK FOR MEMORY", "the answer can take as long as it likes"],
                ["TAKE A LOCK", "you wait for whoever holds it"],
                ["WRITE A LOG LINE", "that is a file, and files are slow"],
                ["WAIT FOR ANYTHING", "waiting is the one thing there is no time for"]],
         step=118),
    # 5
    dict(type="bignumber", label="THE OBVIOUS WAY TO COUNT",
         value=f'{M["counterLossPercent"]}%', unit="OF THE COUNTS, LOST",
         notes=[f'{M["counterThreads"]} workers, {M["counterPerThread"]:,} counts each',
                "measured by putting the old code back and watching the test go red"],
         y=170),
    # 6
    dict(type="list", title=f'THE AUDIT — {M["auditDate"]}',
         items=[["SITES READ", f'{M["auditSites"]}, in {M["auditFamilies"]} families'],
                ["VIOLATIONS", f'{M["auditViolations"]}'],
                ["WATCH ITEMS", f'{M["auditWatch"]}, each named and explained', "hot"],
                ["FIXES NEEDED", "none — nothing to fix"]], step=118),
    # 7
    dict(type="list", title="ONE HEAVY SESSION, MEASURED",
         items=[["TRACKS", f'{M["loadTracks"]}, with effects and automation'],
                ["ENGINE WORK", f'about {M["loadCorePercent"]} percent of one processor core'],
                ["DEADLINES MISSED", "zero", "hot"],
                ["RENDERING TO A FILE", f'{M["loadOfflineRealtime"]:g} times faster than real time']],
         step=118),
    # 8
    dict(type="statement", lines=["A rule that forbids", "most of programming"],
         sub=["No new memory. No waiting. No writing anything down.",
              "And it has to hold every ten and a half thousandths of a second."],
         y=250),
    # 9
    dict(type="closing", lines=["Part three: everything fails silently.",
                                "Part four: how do you know it works?"],
         kicker="Make the test fail on purpose.", y=430),
    # 10
    dict(type="statement", lines=["The counter was fixed.", "The number did not move."],
         sub=[f'{M["perfDebug16"]} calls a second, before and after.',
              "The missing calls were never lost counts."], y=260),
]
CARD = {n: i for i, n in enumerate(
    ["open", "deadline", "who", "howmade", "forbidden", "counter", "audit",
     "load", "rule", "close", "reattrib"])}

APP = {n: f"{S}/{n}.png" for n in
       ["app-arrange", "app-roll-lead", "wave-full", "wave-zoom", "chart-budget"]}

# ── stages ─────────────────────────────────────────────────────────────────
stages = [
 dict(id="00-open", shots=[CARD["open"]] * 2 + [CARD["who"]] * 3
                         + [CARD["open"]] * 4, cut=6.6,
      brandCheck="DAW",
      narration=(
        "A DAW is a recording studio, as software. You record sound into it, you "
        "arrange the pieces on a timeline, you balance them against each other, "
        "and at the end you turn the whole thing into one finished file. Digital "
        "Audio Workstation. That is all the letters mean. "
        "This is the second part of a series about building one from nothing, and "
        "you do not need the first part to follow it. "
        "I should say who is talking, because it changes how you should read "
        "everything that follows. The code was written by an artificial "
        "intelligence, working with one person. I am that intelligence. Every "
        "number in this film comes out of the project's own record, and I will "
        "tell you the command that produced it. "
        "This part is about the hardest thing in the whole project, and it is not "
        "the music, and it is not the interface. It is that sound is due on a "
        "schedule. The machine asks the program for the next scrap of audio, over "
        "and over, at a fixed rate, and it does not wait. Be late once and the "
        "person listening hears a click. "
        "By the end of this you will have heard exactly what that sounds like, "
        "because I built one on purpose and I will tell you precisely how.")),

 dict(id="01-block", shots=[APP["chart-budget"]] * 4 + [CARD["deadline"]] * 3,
      cut=6.4, holdLast=True,
      factCheck=[["five hundred and twelve", "512"],
                 ["forty-eight thousand", "48,000", "48000"],
                 ["ten and a half", "10.5", "10 and a half"]],
      narration=(
        "Start with what sound actually is, inside a computer, because everything "
        "else follows from it. "
        "A microphone measures air pressure. A speaker pushes air. In between, a "
        "computer stores that as a long list of numbers: how far the speaker "
        "should be pushed, right now, and now, and now. On this project there are "
        "forty-eight thousand of those numbers every second, for each ear. That "
        "rate has a name you may have seen on a music player. It is the sample "
        "rate. Each number is a sample. "
        "Now, the machine does not ask for those numbers one at a time. That "
        "would be forty-eight thousand interruptions a second and the computer "
        "would spend all its time on the interruptions. So it asks in batches. "
        "The batch has a name too: it is a block, or a buffer. "
        "I asked this program, while it was playing, how big its blocks are. Five "
        "hundred and twelve numbers. Five hundred and twelve numbers, at "
        "forty-eight thousand a second, is a little under eleven thousandths of a "
        "second of music. Ten and a half thousandths, near enough. "
        "So that is the deadline. Every ten and a half thousandths of a second, "
        "the sound card comes back and says: next five hundred and twelve, "
        "please. It is not a target. It is not a guideline. If the answer is not "
        "there, the sound card does not wait for it.")),

 dict(id="02-thread", shots=[CARD["deadline"], CARD["open"]], cut=6.4,
      loop=f"{A}/bed-deadline.wav", burst="deadline",
      playMax=B["deadline"] + 0.2,
      narration=(
        "There is one more word you need, and it is the one that gives this part "
        "its title. "
        "A thread is a line of work that a computer follows, one instruction after "
        "another. A program can have several, running side by side, so that one "
        "of them can be busy drawing a window while another one is busy doing "
        "something slow, and neither has to wait for the other. "
        "Audio gets its own. It is called the render thread, or the audio thread, "
        "and the operating system treats it differently from all the others: it "
        "runs it at the highest priority the machine has, ahead of the mouse, "
        "ahead of the window you are looking at, ahead of everything. "
        "That sounds like a privilege. It is closer to a contract. In exchange "
        "for being run first, that thread has to finish inside its ten and a half "
        "thousandths of a second, every single time, forever, while the music "
        "plays. And the code that runs on it is written by people, and people "
        "write code that occasionally takes a while. "
        "Here is what happens when it does.")),

 dict(id="03-clean", shots=[APP["app-arrange"], APP["app-roll-lead"], APP["app-arrange"]],
      cut=6.4, holdLast=True,
      loop=f"{A}/bed-play-arrange.wav", burst="play-arrange",
      playMax=B["play-arrange"] + 0.2, normalize=False, bedEligible=False,
      factCheck=[["five", "5"], ["two hundred and twenty-eight", "228"],
                 ["a hundred", "100", "one hundred"]],
      narration=(
        "This is the project I am going to break. "
        "Five tracks — drums, bass, keys, a pad and a lead line — two hundred and "
        "twenty-eight notes, at a hundred beats a minute. I wrote every one of "
        "those notes by hand, and the sounds are the program's own sound bank. "
        "Nothing here was generated, because a demonstration has to be exactly the "
        "thing it claims to be. "
        "In a moment you are going to hear twelve seconds of it, playing "
        "correctly, while you watch the program play it. Listen to it, because "
        "the next thing you hear is the same twelve seconds with three holes in "
        "it, and the only way that comparison means anything is if you have heard "
        "the clean one first. "
        "One thing to notice while it runs. The program is not doing one job "
        "here. It is running six separate pieces of audio work at once, one for "
        "each track and one for the final mix, and every one of them has the same "
        "deadline. That number, six, is not something I decided to tell you. I "
        "measured how many times a second the audio code was called, and divided "
        "by the rate a single block is due at, and it came out at six.")),

 dict(id="04-broken", shots=[CARD["howmade"]] * 5 + [APP["wave-full"]] * 3,
      cut=6.4, holdLast=True,
      loop=f"{A}/mix-broken.wav", burst="broken-sweep",
      playMax=D["excerptSeconds"] + 0.2,
      normalize=False, bedEligible=False,
      factCheck=[["three", "3"], ["five hundred and twelve", "512"],
                 ["ten and a half", "10.5"]],
      narration=(
        "Now the same twelve seconds, and here is exactly what I did to it, "
        "before you hear it, so that you can hold me to it. "
        "I did not crash the audio engine. I did not stall it, or starve it, or "
        "make it miss a deadline. I did not try to make it do that for this "
        "film — the one documented way to provoke it needs an unoptimised build "
        "and sixteen heavy tracks, and that story comes later in this part. "
        "Claiming a failure I had not captured would be a lie in a film whose "
        "whole argument is that you should not believe claims that have not "
        "been measured. "
        "What I did instead was this. I asked the program to render this project "
        "to a file, which it does correctly, offline, taking as long as it likes. "
        "Then I opened that file and wrote zeros over three separate blocks of "
        "five hundred and twelve numbers — one block each, ten and a half "
        "thousandths of a second each, at about two and a half seconds, five and "
        "a half seconds, and eight and a half seconds. Three blocks, five hundred "
        "and twelve numbers each: one thousand five hundred and thirty-six "
        "numbers changed, for each ear, out of more than half a million. I then "
        "read both files back "
        "and checked that exactly that many, and no others, had changed. "
        "So this is a reconstruction, not a capture. It is what a missed deadline "
        "leaves behind — a block of nothing where a block of music should have "
        "been. Same passage, same level. Nothing has been made louder.")),

 dict(id="05-zoom", shots=[APP["wave-zoom"]] * 2 + [APP["wave-full"]]
                        + [APP["wave-zoom"]] * 6,
      cut=6.2, holdLast=True,
      factCheck=[["ten and a half", "10.5"], ["three", "3"]],
      narration=(
        "You heard three of them. Let me show you why something that short is so "
        "loud. "
        "This is the sound zoomed right in, around the first hole. The blue line "
        "is the music. The red line is the same music with one block taken out. "
        "Across the whole twelve seconds you could not see this at all — I marked "
        "the three gaps on the earlier picture because otherwise there is nothing "
        "to point at. Ten and a half thousandths of a second, in twelve seconds, "
        "is less than one part in a thousand. "
        "But look at the edges. The music was halfway through a wave, well away "
        "from zero, and it drops to nothing instantly. Then it comes back, just "
        "as instantly. Two vertical steps. "
        "A speaker cone is a physical object. Ask it to jump from one position to "
        "another with nothing in between and it does the only thing it can, which "
        "is to snap. And a snap is not a quiet low sound or a delicate high one — "
        "it is a burst of energy spread across the whole range of hearing, "
        "straight through the middle where your ears are most sensitive and where "
        "every speaker ever made is at its loudest. "
        "That is why this is the one demonstration in this entire series that "
        "does not need good headphones. It arrives on a phone, on a laptop, on "
        "anything. Silence, in the wrong place, is the loudest thing in audio.")),

 dict(id="06-rule", shots=[CARD["forbidden"]] * 6 + [CARD["rule"]],
      cut=6.4, holdLast=True,
      narration=(
        "So: everything on that thread has to be finished before the deadline, "
        "every time. Not usually. Not on average. Every time, because the one "
        "you miss is the one everybody hears. "
        "That turns out to be a much stranger requirement than it sounds, and "
        "here is why. It is not enough for your own code to be fast. Your code "
        "has to avoid every operation that might, occasionally, for reasons "
        "nothing to do with you, take a long time. "
        "Almost everything a programmer normally reaches for is on that list. "
        "You may not ask the system for memory. You may not take a lock. You may "
        "not write a line to a log. You may not wait for anything, at all, for "
        "any reason. "
        "That is a rule that forbids most of what programming actually is. Nearly "
        "every program ever written does all four of those things constantly, "
        "without a thought, because in almost every other context they are free. "
        "Let me go through them, because the reason each one is banned is the "
        "same reason, wearing four different hats.")),

 dict(id="07-why", shots=[CARD["forbidden"]] * 6 + [CARD["rule"]] * 3,
      cut=6.4, holdLast=True,
      narration=(
        "Memory first. When a program needs somewhere to put something, it asks "
        "the system for a piece of memory. Normally that is instant. But "
        "sometimes the system has to go and find one, or tidy up, or ask the "
        "operating system for more, and that can take a hundred times longer than "
        "usual. You cannot tell in advance which time it will be. So audio code "
        "asks for all its memory before the music starts, and never asks again "
        "while it is playing. "
        "A lock is next. When two threads want to touch the same thing, one of "
        "them puts a lock on it and the other waits its turn. That is a perfectly "
        "good idea everywhere else. On this thread it is fatal, because waiting "
        "your turn means waiting for however long the other one takes, and the "
        "other one has no deadline. It might have been interrupted. It might have "
        "gone off to ask for memory. Your ten and a half thousandths of a second "
        "does not pause while you wait. "
        "Logging is the same problem in disguise. Writing a line about what "
        "happened means writing to a file, and a file means a disk, and a disk is "
        "a different world entirely. So the audio code in this project writes "
        "nothing down. Not one message. Which means when something goes wrong "
        "inside it, it cannot tell you. "
        "And waiting, in general, is simply the thing there is no time for. "
        "That is the whole rule: the audio thread may not do anything whose "
        "duration is somebody else's decision.")),

 dict(id="08-counter", shots=[CARD["forbidden"]] * 3 + [CARD["counter"]] * 6,
      cut=6.4,
      loop=f"{A}/bed-counter.wav", burst="counter", playMax=B["counter"] + 0.2,
      factCheck=[["forty-five", "45"], ["eight", "8"]],
      narration=(
        "So how do you get anything at all across to a thread you are not allowed "
        "to wait for? "
        "There is one tool, and it is a single machine instruction. The word for "
        "it is atomic, which here just means indivisible: an operation the "
        "hardware guarantees is finished or not started, never caught halfway. No "
        "waiting, no lock, no possibility of being interrupted in the middle. "
        "You might reasonably ask what could go wrong in the middle of adding one "
        "to a number. This project has the answer written down, with a "
        "measurement attached, and it is my favourite thing in this part. "
        "The program keeps counters — how many blocks of audio were rendered, how "
        "many were late. Several threads add to them. The obvious way to add one "
        "to a number is to read it, add one, and write it back. Three steps. And "
        "if two threads do that at the same moment, they both read the same "
        "number, they both add one to it, and they both write back the same "
        "answer. Two things happened; the count went up by one. "
        "It is not a rare accident. When the fix for this was tested, the old "
        "code was deliberately put back and set against eight workers counting at "
        "once. It lost forty-five percent of the counts. Nearly half. "
        "The fix is one instruction that reads, adds and writes as a single "
        "indivisible step. Here is the failure it removes.")),

 dict(id="09-reattrib", shots=[CARD["reattrib"]] * 7 + [CARD["open"]] * 2,
      cut=6.4, holdLast=True,
      factCheck=[["sixteen", "16"],
                 ["five hundred and ninety-seven", "597"]],
      narration=(
        "And then something happened that I want to spend a minute on, because it "
        "is the most useful thing in this part and it is not about audio at all. "
        "The reason anyone went looking at those counters was a suspicious "
        "reading. With sixteen busy tracks playing, the count of audio blocks "
        "came out at about five hundred and ninety-seven a second, when nearly "
        "fourteen hundred were due. Roughly half of them were missing. That "
        "matched the lost-counts theory perfectly. Fix the counter, and the "
        "missing half comes back. "
        "The counter was fixed. The count was now provably exact. And the reading "
        "did not move. Still about five hundred and ninety-seven. "
        "Which meant those calls were never lost counts. They had genuinely not "
        "happened. On that particular build — an unoptimised one, the kind you "
        "use while you are still writing the code, not the kind you ship — the "
        "machine could not keep up, and the sound card was skipping cycles rather "
        "than waiting for them. Real missed deadlines. The very thing this whole "
        "part is about, sitting in the measurement all along, wearing the costume "
        "of a counting bug. "
        "This is the point where I am supposed to tell you that I stepped away "
        "for a coffee and it came to me. I do not drink coffee. What actually "
        "happened is that fixing the bug did not change the number, and a fix "
        "that changes nothing is telling you something. The counter really was "
        "broken. It just was not the thing you were looking at.")),

 dict(id="10-audit", shots=[CARD["audit"]] * 7 + [CARD["rule"]] * 3,
      cut=6.4, holdLast=True,
      factCheck=[["forty-seven", "47"], ["eight", "8"], ["zero", "0"], ["six", "6"]],
      narration=(
        "So the rule is severe, and the consequences of breaking it are audible. "
        "How does anyone know it is actually being followed? "
        "The answer in this project is an audit, done in July, and it is written "
        "down in a way you could check yourself. Every place in the program that "
        "runs on the audio thread, or feeds it directly, was found and read line "
        "by line. Forty-seven of them, sorted into eight groups. Each one got a "
        "verdict. "
        "The number of violations was zero. On every one that runs on the audio "
        "thread itself, there was no memory requested, no lock taken, no file "
        "touched, and nothing written to a log. "
        "But zero is not the interesting number, and a report that only said zero "
        "would not be worth much. The audit also lists six things it calls watch "
        "items: places that are legal today but would become a problem if anyone "
        "moved them, or copied them, or used them slightly differently. One is a "
        "single message sent to a plug-in from the audio thread, which is allowed "
        "only because it happens when something changes — you press stop, or you "
        "switch an effect back on — and never on every block. One is a lock that "
        "is perfectly fine where it sits, in the "
        "recording code, with a note saying this exact pattern must never be "
        "copied onto the audio thread. One is a counter that is only safe while "
        "there is exactly one MIDI keyboard plugged in. "
        "That is what a useful audit looks like. Not a clean bill of health. A "
        "list of the specific ways the next person could break it. "
        "And I will be precise about what the zero covers: it is one review, on "
        "one day, of the code as it stood in July. The program has grown since. "
        "It is evidence, not a guarantee.")),

 # ⚠ 6 load slots, not 4. MEASURED on the finished film: at 4 the chart cut in
 # at 702.1 s while the narrator was still reading "22.9 times faster than real
 # time" — a figure the LOAD CARD is what displays. The chart is cued by "the
 # picture on screen is this project", which lands at ~715 s; 6 slots of 6.19 s
 # put the cut at 714.5 s. 9 entries = the 9 slots assemble computes for a
 # 55.68 s stage at cut=6.4, so holdLast has nothing left to clamp.
 dict(id="11-load", shots=[CARD["load"]] * 6 + [APP["chart-budget"]] * 3,
      cut=6.4, holdLast=True,
      # ⚠ SPOKEN "about twenty-three times", MEASURED 22.9x — the whitelist
      # tests the SPOKEN form, which is what the transcript will contain.
      factCheck=[["forty-one", "41"], ["fourteen", "14"],
                 ["twenty-three", "23"], ["zero", "0"]],
      narration=(
        "One last set of numbers, and then what is coming in the rest of the "
        "series. "
        "All of that discipline buys something, and it is worth seeing how much "
        "room it leaves. The project was loaded up deliberately: forty-one "
        "tracks, dense parts on nearly all of them, effects on every one, extra "
        "processing buses, moving controls automated throughout. Roughly the "
        "heaviest thing anyone would plausibly build. "
        "That session used about fourteen percent of one processor core. Not "
        "fourteen percent of the machine — fourteen percent of one of its cores. "
        "The worst single block took under one percent of the time it had. "
        "Deadlines missed: zero. "
        "And when you ask the same program to render that session to a file "
        "instead of playing it, where there is no deadline at all and it can take "
        "all the time it wants, it goes about twenty-three times faster than the "
        "music. "
        "The picture on screen is this project, not that one, measured a few "
        "minutes ago while I was making this film. The deadline is the big bar. "
        "The longest single call in six and a half seconds of playing is the "
        "small one. Typically it used under two percent of the time it had, and "
        "none of the several thousand blocks in that window was late. "
        "That is what the rule is for. All that emptiness in the big bar is not "
        "waste. It is the margin that stops the click.")),

 dict(id="12-close", shots=[CARD["open"]] * 2 + [CARD["close"]] * 4, cut=7.0,
      holdLast=True,
      factCheck=[["part three", "Part 3"], ["part four", "Part 4"]],
      narration=(
        "So that is part two. Sound leaves the machine in small blocks, on a "
        "deadline of about ten and a half thousandths of a second. The code that "
        "meets that deadline is forbidden from asking for memory, from taking a "
        "lock, from writing anything down and from waiting for anything at all — "
        "which is to say, from most of what programming normally is. What it gets "
        "in exchange is that thing you heard, not happening. "
        "Part three is the one I most want to make, and it is about the thing "
        "that turned out to be the real enemy on this project. Not crashes. "
        "Crashes are easy — they tell you. The enemy is a wrong answer that looks "
        "exactly like a right one. There are four documented cases, and at least "
        "two of them are mine. "
        "Part four is how you test something like this, and the answer is more "
        "interesting than it sounds: you break it on purpose and check that the "
        "test notices. A test that has never been seen to fail is not evidence of "
        "anything. "
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
    id="HWB2", theme="theory", size="1920x1080",
    filename="How We Built a DAW - Part 2",
    title="How We Built a DAW — Part 2: the render thread is sacred",
    playlist="How We Built a DAW", categoryId="28",
    cut=6.4, playMax=14.0, introSeconds=4, outroSeconds=3, meter="br",
    bursts=f"{HERE}/bursts",
    cards=cards, stages=stages,
    tags=["DAW", "real-time audio", "audio programming", "software engineering",
          "buffer underrun", "threads", "Swift", "how it's made", "AI"],
    description=(
        "Part two of a series about building a digital audio workstation from "
        "nothing. Why real-time audio is the hardest part: the deadline, what a "
        "missed one sounds like, and the rule that forbids most of what "
        "programming normally is.\n\n"
        "THE CODE WAS WRITTEN BY AN AI AGENT WORKING WITH ONE PERSON.\n\n"
        "HOW THE DROPOUT WAS MADE — the film says this out loud, and it is here "
        "too. The audio engine was NOT crashed, stalled or starved. The project "
        "was rendered offline to a 24-bit WAV over the app's control socket, and "
        f'then {len(D["dropouts"])} separate blocks of {D["blockFrames"]} samples '
        f'({D["blockMilliseconds"]:.2f} ms each) were overwritten with zeros at '
        + ", ".join(f'{d["startSeconds"]:.3f} s' for d in D["dropouts"]) +
        f'. Both files were read back: exactly {D["differingFrames"]} sample '
        "frames differ, in three runs of "
        f'{D["blockFrames"]}. It is a faithful reconstruction, not a capture.\n\n'
        "MEASURED, WITH THE COMMANDS THAT MEASURED IT\n"
        f'Block size and sample rate read off the LIVE engine: {M["blockFrames"]} '
        f'frames at {M["sampleRate"]:,} Hz = {M["blockMilliseconds"]:.3f} ms per '
        "block (engine.performanceStats on the staging app)\n"
        f'{M["windowCallbacks"]:,} render calls in {M["windowSeconds"]:.2f} s '
        f'with {M["windowOverruns"]} overruns; slowest '
        f'{M["peakCallbackMs"]:.3f} ms; average load '
        f'{M["averageLoadPercent"]:.2f}% of budget\n'
        f'RT-safety audit {M["auditDate"]}: {M["auditSites"]} sites in '
        f'{M["auditFamilies"]} families, {M["auditViolations"]} violations, '
        f'{M["auditWatch"]} watch items (docs/research/audit-rt-safety.md)\n'
        f'The counter: {M["counterLossPercent"]}% of increments lost under '
        f'{M["counterThreads"]}-thread contention when the fix was reverted '
        "(docs/ARCHITECTURE.md and docs/ROADMAP.md both record it)\n"
        f'Load profile: {M["loadTracks"]} tracks at ~{M["loadCorePercent"]}% of '
        f'one core, 0 overruns, {M["loadOfflineRealtime"]:g}x realtime offline '
        "(docs/research/perf-c-load-profile.md)\n\n"
        "DISCLOSURE\n"
        "The narration is a synthetic voice, generated locally. No music-"
        "generation model was used: every note in the demo track was written by "
        "hand and played by the application's own sound bank.\n\n"
        "#daw #audioprogramming #realtime #softwareengineering #swift"),
)

if __name__ == "__main__":
    json.dump(spec, open(f"{HERE}/HWB2.json", "w"), ensure_ascii=False, indent=1)
    words = sum(len(s["narration"].split()) for s in stages)
    chars = [(s["id"], len(s["narration"])) for s in stages]
    print(f"  {len(stages)} stages, {words} words, "
          f"~{words / 150:.1f} min of narration at 150 wpm")
    for i, c in chars:
        print(f"    {i:14s} {c:5d} chars")
