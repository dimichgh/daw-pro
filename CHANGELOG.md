# Changelog

## 2026-07-30 — Groundwork: playing at the right speed on any audio device

Nothing you can see yet — this is a measurement that clears the way for
something you will.

Audio devices run at a fixed speed. Most run at 48,000 samples a second, but
plenty run at 44,100, and some hardware insists on its own. A project also has
a speed. When the two disagree, something has to convert between them, and
*where* that conversion happens decides whether it costs you anything.

We wanted to do the conversion at the very last step, on the way out to the
device, so everything before it stays at one clean speed. The open question was
the price: would it drift out of tune, arrive late, or fall over when you
switch headphones mid-song?

Measured, on a real loopback device: a 997 Hz tone through a 48 k project on a
44.1 kHz device comes out at **996.991 Hz** — 0.009 Hz off, where getting it
wrong would have landed at 1085 Hz. The conversion adds **0.004 ms** of delay,
which is at the limit of what the measurement can even resolve, against a
15 ms budget. And flipping the device between 44.1, 48 and 96 kHz *while audio
is playing* recovered correctly all ten times.

One genuinely useful surprise: conversion at the output is essentially free,
but doing the same conversion earlier in the chain — at the mixer, where it
happens today — costs about **0.94 ms**. That is the argument for the change,
and we would not have known it without measuring both.

## 2026-07-30 — A Panic button, for when a note will not stop

**There is now a way out of a stuck note.** Every so often a note gets stuck
sounding and nothing you do makes it stop. It is almost never your fault: a
keyboard sends "key down" and "key up" as two separate messages, and if the
second one never arrives — you unplug the cable mid-note, the device drops off,
another app quits with a key held — the note is left hanging on. The DAW is
right to keep sounding it, because as far as anything can tell, the key is
still down.

What was missing was the exit. Pressing Stop did nothing, because Stop only
does something when there is something playing to stop. Nothing in the AI
copilot's vocabulary could clear it either. So the only fix was to quit the app.

There is now a **PANIC button in the transport bar** — the red octagon next to
Record. Press it and everything goes quiet. Your AI assistant can do the same
thing when you ask it to, using the new `transport.panic` command.

Two things about it are deliberate. It works **whether or not anything is
playing**, which is the whole point — a stuck note usually happens when you are
not playing anything. And it does **not** stop playback or recording, so if a
note jams in the middle of a take you can silence it and keep the take.

## 2026-07-30 — The sustain pedal holds for as long as you hold it

**Live MIDI thru: a pedalled note no longer dies after 8 seconds.** Hold the
sustain pedal, play a note, lift your finger — the note is supposed to ring on
until you lift the pedal. It did, for eight seconds, and then stopped dead in
the middle of the sound. Any pedalled phrase longer than a bar or two ran into
it.

The engine was watching the wrong thing. It kept a track awake while a *key*
was held down, which is the right rule right up until you use a pedal: under
the pedal your finger comes off the key while the sound keeps going. So the
engine saw nothing held, started its idle countdown, and cut a note that was
still sounding. It now watches the pedal as well as the keys.

Lifting the pedal still releases everything exactly as before — that is
checked, because "never stops" would have been a worse bug than "stops too
early".

## 2026-07-30 — Let go of the key and the note stops

**Live MIDI thru: a retrigger no longer strands the previous voice.** Play a
note, then play the same note again without lifting the key first — something
real hardware does constantly, and any source that drops a note-off does by
accident. The second press used to leave the first note stranded: nothing could
ever switch it off, so it sounded until the whole instrument was flushed, and
the note-off you eventually sent went to the *second* voice instead. The
retrigger now closes the first voice itself.

Under the hood this was a capacity change, not a one-line fix. Each incoming
note can now produce two outgoing events, so the render thread's fixed scratch
buffer was resized (768 -> 1280 events) and the drain loop was changed to count
*presses* rather than emitted events — bounding on emissions would have left
half a busy quantum's input queued a beat late, every beat.

Verified end to end through real CoreMIDI, not just in unit tests: a new gate
creates a virtual MIDI source, plays on/on/off into a sustaining synth, and
watches the master meter fall silent. Deliberately re-run against a build with
the fix removed, where it stays loud forever — so the test is known to be
capable of catching the bug it was written for.

One accepted trade: two MIDI devices holding the *same* note now replace each
other rather than stacking. That is the better failure — previously they
stranded a voice *and* mis-paired the key-up.

## 2026-07-30 — The last check that was quietly measuring a zombie

The internal check that proves your window-follow preference survives a restart of the app used to kill the app, wait, and ask "is it gone?" — and get back "no, still running" even when it had already exited. The answer was an artifact of how the check was being run, not of the app: nothing was left to notice the process had died, so the question kept returning the stale answer. That mattered more than it sounds, because that one question is what rules out the check accidentally re-connecting to the OLD app and congratulating itself on a setting that never actually persisted. It now measures what it claims, and the tooling around it says so out loud.

Two other things in the same area stopped being taken on trust. This check was the last one in the suite that ran against whatever copy of the app happened to be lying around rather than building a fresh one, and it measured the screen through a small helper program that had last been compiled by hand four days earlier. Both are now rebuilt every single run. And the audit that reports "nothing launches the app behind our back" turned out to have never been able to see this particular check doing exactly that — it was looking for a literal filename and this one used a variable. The audit has been taught to see it, and to refuse to stay quiet unless each case is justified in writing.

Separately, four genuine problems this check has been reporting for a while are now written down as their own task rather than living inside a wall of output — they all look like one cause, the same one already logged against a sibling check: the screen measurements are aimed at coordinates the layout has since moved away from.


## 2026-07-30 — An internal check that had been quietly testing a third less than it claimed

The resize sweep is one of our internal display checks: it resizes the app to four
window sizes and photographs the screen in each, so we can see that nothing overlaps
or gets cut off. It is meant to take 24 photographs.

It was taking 16. The last eight needed a project with some music in it — a few notes,
a volume curve, an EQ — and the check never made one. It expected whoever ran it to set
that up by hand first and tell it where to look. If you just ran it, it took the 16
photographs it could and stopped, without mentioning the eight it had skipped. That has
been true since the check was written in July, and the runs that did produce all 24
happened because a person staged the project by hand that day.

The check now builds that project itself, every time, so all 24 photographs get taken.
We recovered what the project should contain from the notes of the original 24-photograph
run rather than guessing, then confirmed by eye that the photographs really do show it:
the notes, the volume curve continuing past the end of the clip, the EQ panel.

Also fixed: this check read a setting called PORT to decide which copy of the app to
talk to. PORT is a name lots of tools set for unrelated reasons, so an unlucky value
could have pointed a 24-step resize sweep at the app you were actually working in and
resized your window out from under you. It now talks only to its own private copy.

Filed for a follow-up sweep: any other internal check that quietly does less than it
says when something optional is missing.

## 2026-07-30 — The two long-running stress tests start the app themselves, and the last of the risky `PORT` shortcuts is nearly gone

The two endurance checks — one that repeatedly deletes an audio file mid-playback
to make sure the app never wedges, and one that rebuilds a 40-track session five
times over to make sure the sound never silently drops out — now build and launch
their own private copy of DAW Pro. Verified over eight runs: identical results
every time, and the measured loudness of the 40-track mix came out the same to
four decimal places whether the check started the app itself or not.

These two carried the same hazard fixed yesterday, in a worse form: they defaulted
to a port that was neither the private one nor your live one, and still obeyed a
`PORT` setting from the environment. Pointed at your real session, one of them
would have deleted files during playback and the other would have rebuilt your
project forty tracks at a time. Both overrides are gone. One check still carries
this shortcut and is scheduled next.

## 2026-07-30 — Two more internal checks start the app themselves, and a stray `PORT` setting can no longer aim them at your project

The mixer-strip and piano-gutter layout checks now build and launch their own
private copy of DAW Pro instead of quietly attaching to whatever happens to be
running. Every picture they take came out **byte-for-byte identical** to the old
way — all 25 of them, across nine runs — so nothing they look at has changed.

The reason this mattered more than housekeeping: both checks used to read an
environment variable called `PORT`, which is one of the most commonly set names
on any developer's machine. If it happened to be set to the port your real DAW
Pro window listens on, these checks would have driven **your** session — and the
first thing they do is start a new empty project, discarding what you had open.
Their own instructions named a different variable entirely, so the setting people
were told to use did nothing while the dangerous one worked silently. The
override is gone; the checks now refuse your live app outright rather than
trusting a setting.

## 2026-07-30 — The two speed checks now start the app themselves, and it was proven not to change what they measure

Two internal checks measure how long it takes to add a track *while the project is
playing* — one with 40 audio clips rolling, one with them idle. They were the last checks
that still needed someone to launch DAW Pro by hand, and the awkward ones to change: they
assert on millisecond timings, so making them build and launch the app first could plausibly
have altered the very numbers they measure.

Rather than argue about it, it was measured. Each check was run nine times across three
setups: against an app left sitting idle for a minute with no build beforehand (how they
were originally calibrated), through the old hand-launched path, and self-launching. All
eighteen runs passed every timing band, and the self-launching average landed exactly on the
idle-app average. The startup work finishes about fifteen seconds before the first
measurement is taken.

Two side benefits. These two checks could previously be pointed at a different port by an
environment variable — including the one the user's real app runs on. That override is gone.
And a stray sixty-second override could no longer make a slow compile look like a hung check.

One thing to fix later, now written down: the active-players check requires its result to be
*at least* 330 ms, and the fastest run measured came in at 337. That floor means a genuine
speed-up in track creation would be reported as a failure.

## 2026-07-30 — The two biggest internal checks now start the app themselves

The spectrum pair — the check that the per-insert spectrum actually draws on a track's EQ
card, and the check that the vibe orb, goniometer trail and mono-safety readouts keep
running while DAW Pro is in the background — were the last two large checks still requiring
someone to launch the app by hand first. They now build and start their own copy, like the
rest. Between them they are the heaviest pair in the suite, which is why they were left
until the recipe had been proven on twelve smaller ones.

Both produced exactly the same result afterwards as before — 64 checks and 47 checks, all
passing, in the same order — so the change is in how they start, not in what they measure.

One of the two got quietly more trustworthy in the process. It works by holding focus away
from DAW Pro for its whole run, and its very first check confirms the app *is* in front
before that starts — otherwise the run proves nothing. Previously that depended on luck,
since whoever launched the app by hand would have had their terminal in front by the time
the check ran. Now the check starts the app itself, so the condition is guaranteed.

## 2026-07-30 — Three more checks start the app themselves, and one turned out to be looking at a blank patch of screen

Three internal checks — the reference-track panel, the off-clip playhead cue, and mixer
strip dragging — used to require someone to launch DAW Pro by hand first, then point the
check at it. Whatever build happened to be running is what got measured. All three now
build the app and start their own copy, so a check can no longer quietly report on
yesterday's code. The playhead check had a second version of the same problem: the small
Swift tool it uses to inspect pixels was also compiled by hand, once. It is now rebuilt on
every run too.

Two real problems surfaced while doing this, both of which predate the change and are now
written down rather than quietly fixed:

The off-clip playhead check has been examining a strip of the note grid that no longer has
anything in it. The cue it looks for sits about 165 pixels lower on screen than where the
check reads. Sixteen of its thirty-three assertions fail for that one reason, so a real
break in this feature would currently be invisible among them.

The reference panel's match-gain chip draws +24 dB and −24 dB identically. Everything in
between is distinct, so the readout is fine until you reach the extremes, where a large
boost and a large cut become indistinguishable at a glance.

One more thing worth recording: the app remembers its window size between launches, and
nothing in the checks pins it down. A check that compares screenshots can therefore change
its answer purely because the window came back a different size — which is exactly what
happened here, and it looked convincingly like a regression until the old version of the
check was re-run and produced the same result.

## 2026-07-30 — A check that times out no longer leaves a copy of DAW Pro running behind it

Twelve of the internal checks carry a stopwatch that gives up if the app stops responding.
When that stopwatch fired, the check quit — but left the copy of DAW Pro it had started
still running, invisibly, in the background. The same thing happened if you pressed Ctrl-C
to stop a check partway through.

That leftover copy is worse than untidy. Later checks would connect to it by mistake and
report on the wrong app: on one occasion in July, a single stray copy caused five checks to
pass that should have failed, and three to fail that should have passed. It is the reason a
run could look clean and mean nothing.

The shutdown now happens in the one place that starts the app, so it covers every way a
check can end — finishing normally, timing out, being interrupted, or crashing — and it
covers checks written in the future without anyone having to remember. Measured before and
after: with the old code the leftover copy was still running on every path tested; with the
new code it is gone on all of them, and the checks themselves report exactly what they did
before.

## 2026-07-30 — The four export checks now start the app themselves, and one of them stopped lying about stems

Four more of the app's internal checks — the ones covering the export window, exporting
MIDI from a track, and the stems dialog — now build and start DAW Pro themselves instead
of testing whatever copy happened to be open. All four came out the same before and
after: a hundred individual checks, none failing. The exported files landed on disk as
expected, which is the part that actually matters for export.

One of these had a real problem worth explaining. The export window remembers your
settings until you quit. The stems check tests what the window looks like *fresh*, so if
anything had opened that window earlier in the same session, the check would report
failures that looked exactly like a bug in the app — and that had already happened once,
in July, on a build with nothing wrong with it. It relied on someone remembering to
restart the app first. Now it starts its own, every time, so the situation can't arise.

We also found a piece of cleanup code that had never once run. It was written to release
resources when the check finished, but it sat in a place the program never reaches on its
way out. Harmless as written — but it is exactly where someone would later put "shut the
app down", and it would have quietly left copies of DAW Pro running after every
successful run. Fixed here, and we've made a note to check the rest for the same shape.

## 2026-07-30 — Three more checks now build the app they test, and one tool had stopped counting straight

Another three of the app's internal checks were converted so they build and launch
DAW Pro themselves instead of quietly measuring whatever copy happened to be running.
All three came out green before and after, matching step for step — so this is
plumbing, not a bug hunt. Nothing about the app itself changed.

Two things did turn up along the way.

The tool that runs a check "before" state — the reference point we compare against —
was silently dropping any arguments you gave it. Four of the checks still waiting to
be converted take a folder to write their output into, and three of those have no
fallback, so they could not have been measured at all. That is fixed, and it was
confirmed the blunt way: the same probe run through the old tool and the new one, one
losing the arguments and one keeping them.

The tool that keeps score of how many checks have been converted had started counting
one of our own tools as if it were a check. The number it reported was one too high
and had quietly stopped adding up against last week's. Also fixed, and the totals line
up again.

We also pulled two checks out of this batch. They measure how long the app takes to do
something, and they were calibrated against this specific machine on a quiet day.
Converting them would mean compiling the app immediately before timing it, which
disturbs the very thing they measure. They need a different approach and now have
their own entry, rather than being rushed through with the rest.

## 2026-07-30 — We started auditing the checks that were never really checking, and found three real problems

There is a group of 25 automated checks in this project that never start DAW Pro
themselves. They connect to a copy that is already running — one a person started
by hand, at some unknown moment, from some unknown version of the code. A check
like that can report a confident pass without having tested anything you would
recognise, and it has no way of noticing.

Rather than convert all 25 at once, this round did four as a probe, deliberately
mixed between checks that only talk to the app and checks that inspect what is
drawn on screen. All four now build the current code and start their own copy of
the app. Each was measured before and after to confirm the change itself altered
nothing.

**Two of the four were already failing before anything was touched.** That is the
finding, and it is why the probe was worth doing:

- One check **could never have reported a failure at all.** It always signalled
  success when it finished, no matter how many of its own tests had failed. It
  has been quietly failing two tests for some time while reporting a clean pass
  every single run.
- The same check also **spoils its own setup.** It tests how the app behaves when
  the AI audio generator is switched off — but starting that generator is part of
  what it does. So it passes the first time and fails every time after, until the
  generator is switched off again by hand.
- A second check **contradicts its own written rule.** A note at the top of the
  file says to clear text focus a specific way because the obvious way does not
  work. The code then does it the way the note warns against. Everything after
  that point fails in a chain.

None of these are new breakages and none were caused by this work — all three
were confirmed present beforehand. They are now written down as tasks instead of
sitting invisible.

Separately, while investigating: **the Stop button for the AI audio generator does
not reliably stop it.** If it loses track of the running process it reports "was
not running" and leaves it running. The status display, meanwhile, correctly shows
it as healthy — so the app contradicts itself. Also written up as a task.

## 2026-07-30 — The last two checks that could lie to you, and the last two that tested nothing

The previous entry ended by naming two automated checks that were still leaving
behind the false "you crashed" marker. Both are fixed. No check in the project
leaves that marker any more, so the app will only offer to recover your work when
something actually went wrong.

Those same two checks had a second, quieter problem. Every check is supposed to
rebuild DAW Pro before testing it, so that what gets tested is the code as it
stands right now. These two skipped that step and simply ran whatever build
happened to be sitting on disk — which could be hours or days old. A check like
that reports a confident pass without having looked at your current code, and
gives no sign that anything is wrong. It has bitten us before, on the very
feature these two checks were written to guard.

Both now rebuild before they run. That was the whole point of converting them,
and with it done, every check in the project that starts the app also builds it
first.

Nothing about the app itself changed here — this is entirely about whether our
own checks can be believed.

## 2026-07-30 — Our tests were leaving DAW Pro convinced it had crashed

When DAW Pro starts, it writes a small marker file to say "a session is running",
and deletes it on a clean exit. If that marker is still there at the next launch,
the app concludes the previous session crashed and offers to recover your unsaved
work. That is exactly what you want after a real crash.

Our automated checks launch DAW Pro and then stop it abruptly, which skips the
clean-exit path — so every check run left that marker behind. The next time you
opened the app for real, it would offer to recover from a crash that never
happened. Test tooling has no business telling you that.

The teardown step now removes the marker, and does it in one shared place rather
than leaving each check to remember. The safety rule is that it only ever removes
a marker it can prove belongs to the copy it started: it compares the recorded
process against its own, and if there is any doubt at all — the file is missing,
unreadable, malformed, or names a different session — it leaves the file alone.
Your real recovery marker is never a candidate for deletion.

Two things worth being straight about:

- **A check run started while you have DAW Pro open will still disturb this.** The
  app writes that marker to a fixed location, so a second copy overwrites the
  first one's. The cleanup cannot undo that, so the check now refuses to run at
  all if it sees DAW Pro already running. The deeper fix — giving test runs their
  own private data folder instead of sharing yours — is written up as its own
  task, because test runs currently share your recordings, autosaves and
  generated-audio folders too.
- **Two checks are not covered yet** (`m23o1`, `m23o2`). They still stop the app
  their own way and still leave a marker. They are next.

While verifying this we also found that our leak detector — the thing that
reports whether a check left a stray copy of the app running — was reporting
stray copies that did not exist, by matching against its own search command. It
had already been wrong in the other direction last week. It has been rewritten
and moved into the repository so it stops being re-invented.

## 2026-07-30 — Our own test tooling was quietly checking the wrong app

Nothing in DAW Pro itself changed here. This is a fix to the automated checks we
run against the app before calling a feature done — and it is worth writing down
because for a while those checks could pass without proving anything.

The checks work by launching DAW Pro and driving it like a very fast user. Eight
of them were launching it *without rebuilding first*, so they were testing
whatever version happened to be lying around from earlier — possibly hours old,
possibly missing the very change being tested.

While fixing that we found something worse. Four of the eight never shut their
copy of the app down when they finished. The abandoned copy kept holding the
connection, so the *next* check would fail to start its own copy and silently
talk to the leftover one instead. We watched this happen: five checks reported a
clean pass against an app they had not launched — one of them finishing in a
single second — and three others reported failures that were not real, caused
purely by inheriting leftover state. False passes and false failures from the
same root cause.

All eight now build first, and every one shuts down after itself, on success and
on failure alike. We also replaced the tool that audits these checks: it had been
looking for a specific line of code that an earlier cleanup had replaced with a
shared helper, so it had stopped being able to see the very thing it was built to
count. It now checks itself against a known-good list so it cannot go blind
again without saying so.

Two things this left on the machine while we were fixing it, both now cleaned up
and worth knowing about:

- **Three copies of DAW Pro were left running.** They had no window and no
  connection — they were the copies that lost the race for the connection and
  kept running anyway — so our own "did anything get left behind?" check, which
  looked at the connection, reported all clear. It only looks at connections; a
  leftover copy without one is invisible to it. It now looks for the copies
  themselves.
- **A stale recovery marker.** Shutting a copy down abruptly leaves behind the
  file DAW Pro uses to detect a crash, so the next launch can offer to recover
  from a crash that never happened. If you have seen an unexpected recovery
  prompt, that is where it came from. Only one of these checks currently cleans
  that up after itself; making all of them do it is the next task, and it will
  always leave alone any marker belonging to a copy you are actually running.

## 2026-07-30 — More insert slots on the master and bus strips, and they stay put

You asked for this one: the master and bus strips now hold **five** insert slots
by default instead of three, the slots are drawn whether or not you've filled
them, and a longer chain scrolls inside its own space.

The master strip is where the difference is biggest, because it never had any of
this. Until now it simply grew as you added effects — so every insert pushed the
volume fader, the loudness meters, the stereo display and the reference row a
little further down. Measured on the real window, an eight-effect master chain
moved the fader **205 points** down the strip. Add a compressor and the fader
you were reaching for had moved. Now the insert area is a fixed size: the fader
and everything under it stay exactly where they were, and effects past the fifth
scroll within the insert list rather than shoving the rest of the strip around.

Bus strips already held their shape; they were just cramped at three slots. A bus
is where a glue chain lives — compressor, EQ, saturation, limiter — so they now
get five as well. Ordinary channel strips are unchanged at three, deliberately:
they're the most numerous strips in the console and they don't need the space.

Two honest notes. On the master, holding five slots open costs the room the strip
used to give the fader when the chain was short, so the master now scrolls a
little sooner than it did — it already started scrolling at the third insert
before this change, so the difference is small, but it's real. And on a short
window a bus quietly gives slots back rather than squeezing the fader, dropping
to four or three; every bus does it at the same moment, so the console stays
even with itself.

## 2026-07-30 — Making the checks that guard the app check the right app

No change you can see in the DAW today. This is work on the machinery that
verifies it, and it was overdue.

Alongside the automated tests there are 42 "gates" — scripts that launch the
app for real and drive it the way a person would, because some things only a
live run can see. The trouble was that most of them never launched anything.
They connected to whatever copy of the app happened to be running, which might
have been built hours earlier from different code. Run one after a change and
it would report a confident pass that meant nothing at all.

The build-and-launch steps that a handful of gates did get right had been
copy-pasted seven times over, so there was no single place to fix. There is now:
one shared module that builds the app, launches its own private copy, and shuts
it down afterwards. Getting a connection without a fresh build is no longer
possible, and the rule that these scripts must never touch the copy of the app
you have open is enforced in that one place instead of being remembered
separately in every file.

All seven gates that already launched their own copy now use it, each checked
assertion-by-assertion against a recording of its previous run to prove nothing
changed in the process. The last two needed the shared module to grow a little
first — they start the app in a different mode, and a shared thing that cannot
accommodate real differences just gets worked around, which is how seven copies
came to exist in the first place. Still ahead: the eleven gates that launch
without building, and the twenty-four that never launch at all.

One of the gates turned out to have been failing quietly for several days — it
counts the app's commands and had not been told about two that were added on
purpose. A check nobody runs is indistinguishable from a check that passes.

## 2026-07-29 — The safety net for a stuck plug-in was never actually attached

Yesterday's investigation turned up a defect in the code that is supposed to
stop a misbehaving plug-in from hanging the app. Today it is fixed, and the fix
is smaller and stranger than it sounds.

When the app loads an instrument or effect plug-in, it starts a ten-second
countdown alongside it. If the plug-in has not finished by then, the app gives
up and reports it as stalled instead of freezing. That was the design. The
problem was that the countdown itself was scheduled on the same main thread the
plug-in runs on — so the alarm could only ring once the main thread was free,
which is to say once the problem had already gone away. It was a smoke detector
wired to the light switch in the room it was watching.

This was not theoretical. Measured side by side under identical conditions, with
the main thread deliberately held busy for one second and a 200-millisecond
countdown: the old arrangement fired zero times out of six, always returning
"finished successfully" a full second later. The new one fired six times out of
six, every time within about 201 milliseconds. An intermediate version — which
changed everything *except* moving the countdown off the main thread — also
scored zero out of six, which pins the cause precisely.

The countdown now runs independently of the main thread, so the deadline is a
real deadline. The mechanism lives in one place with its own tests rather than
being hand-rolled at each site.

**What this does not fix, stated plainly.** The app now *decides* on time that a
plug-in has overrun. It still has to get back onto the main thread to record
that decision — so a plug-in that is actively holding the main thread hostage
can still freeze the app, which is the worst case this guard was imagined for.
Genuinely solving that means running plug-ins outside the app's own process, and
that is a much larger piece of work; it is written down rather than glossed over.
No timeout can interrupt code that is already running.

One honest side effect. Several audio-plug-in tests had been passing on what
turned out to be a coin flip — the old countdown lost the race most of the time,
so a load that genuinely took twenty-odd seconds was recorded as success. With a
working deadline they started failing truthfully. The cause is the test machine,
not the app: the same load takes about half a second when run on its own, and
twenty-six seconds when several hundred other tests compete for the same thread.
Test runs now get a longer allowance while the shipped app keeps its ten-second
limit, and a new test pins that shipped value so it cannot quietly drift upward.

Full suite: 4421 tests across 448 suites, green on eight consecutive runs.

## 2026-07-29 — Chasing the last "flaky" test found a real bug in a safety net

The last of four intermittent test failures was measured rather than guessed
at, and the measurement turned up something more important than the test.

The numbers: loading a General MIDI sound bank takes about 45 milliseconds when
that test runs alone, and about 20 to 24 seconds when the full suite runs
around it — a 400-fold difference. Deliberately starving the machine of CPU
did *not* reproduce it, which rules out plain slowness. Strangest of all, the
test passes most of the time despite always exceeding its own 10-second limit,
and how long it takes doesn't predict whether it passes: a 19.6-second run
failed and a 23.8-second run passed.

The reason is a real defect, now filed. The 10-second limit is implemented as a
timer that has to get back onto the app's main thread to fire. When the main
thread is busy, the timer is stuck behind whatever is holding it — so it isn't
really a deadline at all, and whether it or the actual work finishes first is a
coin flip. That matters well beyond tests: this limit exists to stop the app
hanging on a plug-in that has seized up, and seizing up the main thread is
exactly what a bad plug-in does. The safety net fails in the precise case it
was built for.

The test itself now reports one clear failure naming the timeout, instead of
three that looked like three unrelated problems.

Suite: 4413 tests / 446 suites.

## 2026-07-29 — Two more "flaky" tests fixed, and one of them was lying

Two tests only ever failed when the whole suite ran at once. Both were
measuring something that belongs to the entire machine rather than to the code
under test.

The first checked that redrawing an EQ curve finishes in under a millisecond —
a fair thing to want, but an absolute stopwatch reading taken while every core
is busy measures the machine's mood, not the code. It now times a fixed
reference calculation in the same run and checks the curve redraw stays within
a multiple of it, so the answer no longer depends on how loaded the machine is.
The multiple was chosen from measurements across idle, full-suite, and
deliberately overloaded conditions rather than picked to make one run pass, and
a companion test deliberately triggers a slowdown to prove the budget still
catches one.

The second checked that a real-time audio path never allocates memory. It used
two probes, and the noisy one turned out to be worse than noisy: under load it
reported a *negative* number of retained allocations on a loop that only ever
retains — impossible, and caused by other threads freeing memory at the same
time. It was also blind to exactly the kind of allocation it was supposed to
catch. Removed. The surviving probe watches only the calling thread, catches
both transient and retained allocations, and was confirmed to fail when a test
allocation was deliberately added.

Suite: 4413 tests / 446 suites, verified across three consecutive clean runs.
One genuinely intermittent test remains and is being worked separately.

## 2026-07-29 — A "flaky" test turned out to be a real bug about sample rates

One of four tests we'd written off as randomly failing wasn't random at all. It
checked that the limiter reports 240 samples of lookahead delay — but 240 is
just 5 milliseconds at 48 kHz. Plug in an audio device running at 44.1 kHz and
the correct answer is 221, so the test failed every single time at that rate.
It only *looked* intermittent because the engine follows whichever audio device
is active, and this machine has several installed.

The rule that turns 5 milliseconds into a sample count now lives in exactly one
place, and both the limiter and the tests read it from there, so they cannot
drift apart. A new test pins the derivation at 44.1 kHz, 48 kHz and 96 kHz
directly, without needing any audio hardware.

Worth stating plainly: every past run that shrugged this off as "the known
flake" was mis-attributing a genuine rate-dependence bug. Three genuinely
intermittent tests remain and are being worked separately.

Suite: 4412 tests / 446 suites.

## 2026-07-29 — Running the tests no longer litters your recovery sessions

Running the test suite used to write crash-recovery snapshots into your real
application-support folder, and the app would then offer that junk back to you
on next launch as sessions to recover — empty projects with names like
`Recovered` and `T`. Merely running the tests dirtied your data.

Test processes now write their recovery bundles into a throwaway temporary
folder instead. The shipped app is unaffected: it still uses the real location,
and the rule that decides where files live is unchanged and still has exactly
one definition, so the autosave writer and the recovery scanner cannot drift
apart.

The five stray bundles already in your folder were deliberately left alone —
deleting things in your data directory is your call, not the fix's. They are at
`~/Library/Application Support/DAWPro/Autosave/` if you want them gone.

Verified by running the whole suite twice and confirming the real folder was
untouched both times, while the redirected temporary folders were confirmed to
have actually been created — proving the writes were diverted rather than
simply not happening. Suite: 4411 tests / 445 suites.

## 2026-07-29 — Voice training: use any voice you have the rights to

The rule that you could only train a voice on your own recordings is gone, on
the project owner's instruction. Train on whatever dataset you supply, or drop
in a third-party voice model — the app does not check whose voice it is, and it
will not refuse one on provenance grounds. **Responsibility for holding the
rights to a voice sits with you**, including if you choose to use one you are
not authorised to.

The app, the control surface and the MCP tool descriptions were already
relaxed. What was still contradicting the policy was documentation and agent
guidance, which is now aligned: the AI-agent wire reference no longer instructs
agents to refuse third-party voices, and the voice sidecar's README and
voice-store comment no longer claim voices can only come from your own
recordings. No behaviour changed and no logic was touched — the sidecar edit is
comment-only.

Unchanged: nothing is bundled — the voice store still ships empty, and `base`
remains an untrained smoke-test target rather than a voice. Importing a model
file you supply is supported; going out and finding voice models at scale is
not something the app does.

## 2026-07-29 — Note-level vocal pitch correction: design spike says GO

No user-facing change. This is a decision, not a feature.

We investigated what it would take to build Melodyne/Auto-Tune-class pitch
correction — split a vocal into notes and edit each one's pitch and timing —
and the answer is **GO**. The expensive half turns out to be already built: the
time-stretch library we ship for clip stretching can also shift pitch while
keeping formants intact (so a corrected vocal still sounds like the same
singer, not a chipmunk), and it can do it on a curve that changes over time
rather than one fixed amount per clip. The missing half is a pitch detector,
which we can write ourselves on an FFT already in the app, adding no new
licensing obligations.

First shippable piece is an automatic tuning pass an AI agent can drive,
estimated 4.5–5.5 weeks; the full note-by-note editor is 14.5–19.5 weeks. The
largest genuine unknown is how it sounds on real voices — a listening test that
is scheduled as the first half-week of work rather than assumed away.

Two documents landed in `docs/research/`: a survey of pitch-detection
algorithms and note segmentation, and the design with the GO/NO-GO. They were
written independently, and comparing them surfaced an open question — the
design picked a hand-written detector without having seen a small MIT-licensed
model that may do the job better. That is filed as `m23-ap` and must be settled
before implementation starts.

## 2026-07-29 — Click a track header to select everything on it

Click a track's header in the sidebar and every clip on that track is selected —
ready to move, nudge, or delete as one. Hold Shift (or Command) and click a
second header to add its clips to what you already had, and click it again to
take them back off. Mix and match freely: a header click, then a Shift-click on
one more clip, and the whole lot deletes in a single undoable step.

Selecting a track selects its *clips* — a track is not a separate thing you can
select, so group delete never has to guess whether you meant "these clips" or
"this whole track". Clicking the header of an empty track simply clears the
selection, the same way clicking empty space in the timeline does.

One deliberate quiet moment: selecting a track does **not** open the piano roll
on any of its clips. A header has no one clip you pointed at, and opening the
note editor on whichever happened to sort first is the kind of surprise that is
worse than doing nothing. Clicking a clip still opens it, exactly as before.

## 2026-07-29 — Arrow keys nudge clips in the arrange

Select a clip — or twenty — and tap the left and right arrow keys to walk them
along the timeline. Each press moves the selection by one grid step, so what the
arrow does always matches the grid you can see. Hold Shift for a whole bar,
Option for a fine 1/32-beat step, and hold the key down to slide something into
place; a burst of presses collapses into a single undo rather than forty.

A nudge MOVES your clips, it does not tidy them up. A clip sitting deliberately
off the grid keeps its offset and simply travels — and a group keeps its internal
spacing exactly, including when it runs into the start of the song, where the
whole selection stops together instead of stacking up at beat zero. If snapping
is off, the arrows still work, one beat at a time.

Arrows stay out of the way when they belong to something else. Renaming a track,
typing in any field, or working with a modal open, the arrow keys do what they
always did. And while you have notes selected in the note editor, the arrows are
left alone rather than sliding the clip out from under you.

Up and down do not move clips between tracks yet — that needs groundwork we have
not built.

## 2026-07-29 — AI assistants can now delete and move clips in groups, as one undo

Ask the assistant to delete four clips and it used to issue four separate
commands, leaving you four separate undos to walk back. Now it sends one, and one
Cmd-Z puts everything back — the same single-step behaviour you already got when
you selected and dragged clips by hand.

Group moves also report what actually happened. If you ask to shift a selection
eight beats earlier but the leftmost clip is only two beats from the start, the
whole group stops at the edge together, keeping its spacing, and the assistant is
told it moved two beats rather than eight — so it can adjust instead of quietly
compounding the mistake on its next move.

## 2026-07-29 — A new instrument track now tells you what to do with it

Add an instrument track and its lane no longer sits there blank. A quiet
"Double-click to add a clip" appears on it, and stays until the lane actually has
a clip. Add one and the hint goes; delete it and the hint comes back.

The double-click itself has worked since the previous round. The problem was that
nobody could tell — a gesture you cannot see is not an affordance, and the report
that prompted this used exactly that word. So the fix is the sentence, not the
behaviour.

It only appears where it is true. Audio and bus lanes refuse MIDI clips, so they
never show it; the hint asks the same question the refusal does, rather than a
second one that happens to agree today. And it is about the lane's contents and
nothing else — add a track while the transport is rolling and it still appears,
because an empty lane is empty either way.

It is deliberately dim and deliberately not clever: no arrow, no exclamation, no
animation. In a project with four fresh tracks you see it four times at once, and
anything louder would read as clutter rather than help.

## 2026-07-29 — Hold a key after pressing stop, and it no longer goes quiet on you

Play something, press stop, then hold a key down on your MIDI keyboard. Until now the note
sounded for eight seconds and then died underneath your finger, while the key was still
down. Nothing you could do brought it back except letting go and pressing again.

This was filed as an obscure corner case — supposedly it needed a freshly-launched app and a
track that had never played. That turned out to be wrong, and a comment inside the engine
asserting the false version is what kept it filed that way. Every stop, seek and tempo change
unpublishes the track's schedule, so the affected state is simply "the transport is stopped":
the ordinary condition for practising, auditioning a sound, or noodling between takes.

The engine now counts how many thru keys are actually held down and keeps the instrument
rendering while any of them are. A note held for a minute sounds for a minute. Releasing it
still lets the tail ring out and then genuinely goes idle, so a stopped project costs nothing.

Two limits are documented rather than hidden. A note sustained by the pedal alone — key
already released — is still cut, because the count tracks keys rather than voices. And if a
note-off is genuinely lost (a cable pulled mid-note), the note stays stuck, which is honest —
the voice really is stuck — but there is still no panic button to clear it. Both are filed.

## 2026-07-29 — The note editor's BAR readout stops pretending to be the playhead

In the note editor's header, beside the buttons that add or remove a whole bar, sits a small
`BAR 1` readout. It was drawn in the same glowing cyan the app uses everywhere for "here is
where playback is" — so if the playhead was sitting four bars away from the part you were
editing, the header still lit up `BAR 1` in playback cyan. It looked like a position. It
never was one: it is simply the bar those two buttons will act on.

It now reads in the same quiet grey as the zoom percentage a few chips to its left. The
words and the number have not changed, and neither has what the buttons do — the only thing
that was lying was the colour. Cyan in the note editor means the playhead, and now it only
ever means the playhead.

## 2026-07-29 — Your effects have their names back

Insert slots in the mixer used to eat their own labels. A compressor read `Compr...`, a
limiter read `Lim...`, and the newest effect read `Bass Enh...` — which is worse than it
sounds, because `Co...` is not obviously a compressor rather than a chorus. You were being
asked to recognise your effects by their first few letters.

Every built-in effect now shows its full name, on every strip, whether or not it is working.
There are only ten of these names and we know all of them, so there is no good reason for
any of them to be cut short.

Making the room meant moving the little activity meter on compressors, limiters and gates.
It used to be a small bar squeezed in beside the name; it is now a thin line running under
the whole row, lighting up the same way. It is a fair trade but it is a trade: the meter is
easier to miss at a glance than it was, and in exchange the name it was crowding is
readable. Built-in slots also lost their small "edit" glyph — clicking anywhere on the slot
opens the controls, which it already did.

Plug-ins are different and stay different. A third-party plug-in's name comes from its
maker and can be any length, so those still shorten with a `…` when they have to. A name we
chose is a label; a name someone else chose is data.

## 2026-07-29 — The bass enhancer tells you what it is doing

The knobs are in the mixer now. Add **Bass Enhancer** from a channel's "+" menu and you get
the three controls: **crossover** (set it to the low limit of the speaker you are worried
about), **amount**, and **mix**.

The card also tells you something most plug-ins in this category do not. Above the knobs,
before you touch anything, it says: **adds harmonics that are not in your recording**. Both
things about this effect are true at once — it makes bass audible on small speakers, *and*
what it makes audible is new sound rather than something uncovered. A beginner should not
have to work that out from a spectrum analyser. So the card says it plainly, says the
harmonics print into your bounce, and explains what the knob ranges cannot. Where to
put the crossover — the lowest note your speaker plays. That amount sets how loud *and* how
bright the harmonics are, and that the character holds whether the part is quiet or loud.
That mix trims how much of them you hear and never turns your own signal down.

None of that is a tooltip. It is drawn on the card, in plain type, and it carries no
numbers: a number sitting an inch above the real readouts would read as a measurement of
your track, and it is not one.

If you want to hear the point of the effect, play a sub-heavy bassline on a laptop speaker
with the enhancer bypassed and then active. Rendered through a simulated small speaker, the
dry part loses around 31–40 dB of what it started with, and the enhanced part still delivers
11–17 dB more than the dry one does — most where the note is lowest, which is where the
speaker is worst.

## 2026-07-29 — Bass that survives a phone speaker

A laptop speaker cannot move enough air to reproduce a 50 Hz note. It never will. But
your ear will happily *infer* that note if it hears the harmonics that sit above it — the
missing-fundamental effect, and the reason a bassline can still read as a bassline through
a phone.

There is now a bass enhancer that does exactly this. It listens to the low end below a
crossover you choose, generates the harmonics that low end *would* have produced, and mixes
them back in above the crossover. Your original low end is untouched; the harmonics are
added on top. On a big system you hear the real bass, on a small one you hear the
harmonics and infer the rest.

It is not a distortion or a saturator, and the difference is audible. A saturator shapes
everything you feed it, so it colours the whole track. This works on the low band alone,
and it normalizes that band's level before shaping it — which means the effect sounds the
same on a quiet passage and a loud one, instead of getting harsher as the part gets louder.
Two controls do the work: **amount** sets how much harmonic content is generated and how
bright it is, **mix** sets how much of it you hear.

Turn either control to zero and the audio is bit-for-bit what went in — not "almost the
same", byte-identical.

You will find it in the "+" menu on any mixer insert slot, alongside the other effects, and
your AI assistant can add it for you by name.

One thing we want to be straight about, because it is easy to sell this the wrong way: this
effect **adds sound that was not in your recording**. It is not uncovering bass that was
hidden in there — it is manufacturing new overtones and printing them into your bounce. That
is the honest description of what every enhancer of this kind does, and the effect's own
panel says so above its controls rather than leaving you to find out later.

## 2026-07-29 — The EQ now shows you where the instrument lives

The frequency reference stopped being something only the AI assistant could read. Open the
EQ on a bass or a guitar track and the plot itself now shows you two things: a soft shaded
band where that instrument's notes actually sit, and a dashed line at the frequency below
which there is nothing worth keeping. You can see, while you drag, whether you are cutting
rumble or cutting the instrument.

The guidance deliberately does not look like your settings. Everything bright on that plot
means something true about *your* track right now — the cyan curve is what you built, the
green is what is actually being measured. A reference is published advice about a *kind* of
instrument, so it is drawn in neutral dashes, and its labels read `TYPICAL 41–98 Hz` and
`CUT BELOW 30 Hz` rather than borrowing the wording of the real controls. Advice should
never be able to pass for a readout.

Where the app does not know, it says so plainly instead of inventing a range. A recorded
audio track gets "the app cannot know what was recorded"; a track with no instrument chosen
asks you to choose one; a drum kit points out that each piece has its own range and suggests
asking the Copilot about the kick or the snare specifically. And where the underlying
research is soft — a drum's pitch is a tuning choice, not a physical constant — the row says
so on the face of it.

Being straight about the reach: today this draws for pianos, guitars and basses. Other
instruments are in the reference the assistant reads, but cannot yet be identified from the
track alone well enough to draw on your plot.

## 2026-07-28 — Your AI assistant now knows where an instrument actually lives

Ask an assistant to "clean up this bass" and until now it was guessing. It could add a
high-pass filter and it could measure the result, but it had no idea where a bass guitar's
lowest note actually sits — so it had no way to tell a cut that removes rumble from a cut
that removes the instrument.

There is now a built-in frequency reference the assistant can read: for each instrument
family, the range its fundamental notes occupy, the regions that make it sound like itself,
the regions engineers usually clean up, and a recommended high-pass corner it can act on
directly. Ask for the vocabulary with no arguments and it lists every family it knows. Point
it at a track and it works out the family from the instrument, or from the drum note you
name. When it cannot tell, it says so and tells you how to be specific — it never guesses.

**Every number is cited to a source, and the sources were checked.** Each entry carries the
verbatim sentence it came from, the page it came from, and the date it was read. Where the
honest answer was "no reliable source says this", the entry was **removed rather than filled
in with something plausible** — seven instrument families were dropped for exactly that
reason, mostly because no trustworthy source gives an instrument-specific filter setting for
them. Three drum entries ship with an explicit note in the text the assistant reads, saying
their pitch is a tuning choice rather than a fixed property, because that is true and
pretending otherwise would be the kind of confident-sounding advice that ruins a mix.


## 2026-07-28 — An AI assistant can now hear what an effect is doing

Until now an agent working on your mix could read the master output and nothing else. It could
add an EQ, change its settings, and have no idea what came out the other side — it was mixing
with its eyes shut. `fx.spectrum` lets it measure any single effect on any track, or on the
master, and get back the same twenty-four frequency bands the master analyser has always
reported.

The measurement tells you where it was taken, because that turns out to matter. An effect on a
track is measured *before* that track's fader, so moving the fader does not change the reading.
An effect on the master is measured *after* the master fader, so moving that one does. The two
numbers mean genuinely different things, and a reading that did not say which it was would make
a strip and the master look like they disagreed when both were right.

Measuring costs something, so it is leased rather than left running: a measurement stays live
for three seconds and lapses on its own if nobody asks again. Eight effects can be measured at
once. Ask for a ninth and it says no, and tells you the limit, rather than quietly switching one
of the others off. If you have an EQ window open on the same effect the assistant is measuring,
neither one can turn the other off — they each hold their own.

## 2026-07-28 — Your meters keep moving when you click away from DAW Pro

Three more live displays used to freeze the moment DAW Pro stopped being the frontmost window:
the vibe orb in the transport bar, the goniometer's trail, and the stereo correlation numbers
beside it. Click into your browser to look something up, or into a plugin window, and they
stopped where they were — still lit, still showing a number, just no longer telling you the
truth. Come back and they'd jump to catch up.

That is the same freeze the master EQ analyser had, and this is the sweep that found the rest
of them rather than fixing one and hoping. They now update continuously: the orb sixty times a
second, the goniometer trail twenty, the correlation readouts ten.

If you are wondering about battery: while DAW Pro is in front, nothing costs more than it did,
and the orb actually costs less — it had been running at the display's own rate, 120 times a
second, and now holds a steady 60. The whole of the added work is in the background, which is
exactly the work that was missing. That is the difference between a meter that tells you the
truth and one that lies to you, which is not a trade a DAW gets to make. Deliberately absent:
any "pause it when the window is hidden" behaviour. That idea is what caused this in the first
place.

## 2026-07-28 — Channel strips stop shuffling when you add an effect

Every channel strip now keeps a fixed space for three inserts. The fader, the dB number, the
Mute/Solo/Arm buttons, the sends and the output all sit at the same height on every strip, and
they stay there whether a track has no effects or twelve. Add a fourth insert and the list
scrolls inside its own little window instead of shoving everything below it downward.

Before this, a strip grew as you added effects. Five ordinary inserts pushed that strip's pan
row, fader and dB readout down by 121 points while the strip next to it stayed put, so the
console never lined up and the controls moved under your cursor as you worked.

Folding the inserts away still gives the fader more room — it hands back the whole reserved
space, not just the rows you were using, because a fold that kept three empty rows would be a
button that does nothing.

The reserved space explains itself rather than sitting there blank. A strip with no effects
shows a dashed outline saying "No inserts"; a strip with one or two shows the effects you have
and then dashed outlines for the rest, so it reads as "three slots, one filled" instead of
looking like something failed to appear. The outlines are deliberately faint — a hairline, not
a grid of boxes competing with the effect names.

Two honest notes. Compressors and gates are taller rows than the others, so two of them fill
the space and start scrolling sooner — the controls below still do not move. And adding a
*send* can still nudge the rows beneath it; only the inserts are pinned so far.

## 2026-07-28 — The EQ on any track now shows the frequencies, not just the master

This is the one you asked for. Open the EQ on any track and the moving green spectrum is
there behind the curve, exactly like the master EQ has always had. Before today only the
master showed it, because only the master had a meter running; the last three rounds of
groundwork built one that any effect can borrow, and this turns it on.

One thing on the card is worth reading once. The green fill on a track's EQ is measured
*before* that track's fader — so if you pull the fader down, the picture does not move.
That is correct, not a broken meter: it is showing what the EQ is working on, not what is
leaving the channel. The master EQ's fill is measured *after* the master fader, so that one
does follow its fader. The two look identical, so each card now says in plain words which
one you are looking at when you hover it.

If the meter cannot run for some reason, the card shows a flat floor and tells you it is not
running, rather than drawing something that looks like silence. Nothing is ever invented.

Only the EQ card you have open is measured — closing it, or switching the card to the knob
view, stops the measurement. Nothing is running in the background on inserts you are not
looking at.

**Also fixed, and it was there before today:** the master EQ's spectrum froze whenever DAW Pro
was not the frontmost app — click your browser, and the green fill stopped moving while still
looking like a live meter. It has been that way since the curve editor shipped. It now keeps
running whether or not the window has focus, which also matters because an AI agent driving
the app leaves the window in the background most of the time.

## 2026-07-28 — Proving the chain probe works everywhere, not just somewhere

No visible change again — this is the last groundwork entry before the feature surfaces.

The probe was attached to effect chains in the previous entry. The question this one answers
is whether it works on *every* kind of track, or only the one that happened to get tested.
Instrument tracks, audio tracks, buses and the master output are built differently inside the
app, and a probe that quietly worked on three of them would look fine right up until someone
tried the fourth.

All four are now covered, along with the awkward moments: switching one effect for another
while the probe is running, a plugin being swapped underneath it, changing the audio device's
sample rate, and turning an effect off and back on. In each case the reading has to keep
working without a gap, and now has to keep working, because a test fails if it doesn't.

There is also a limit on how much this can cost. A probe that made playback stutter would be
worse than no probe. Eight can run at once, and the measured cost of all eight together is
about 0.7 microseconds per audio block — roughly one part in fifteen thousand of the time
available. The ceiling is enforced by a test rather than by hope.

One thing worth knowing came out of the measurements, and it will be visible when the
displays arrive: a probe on a track reads the sound *before* that track's volume fader, while
a probe on the master output reads it *after* the master fader. Both are correct and useful,
but they answer slightly different questions, so the two displays will say which is which.

## 2026-07-28 — Connecting the chain probe, without disturbing the sound

Still nothing visible, and still deliberately so. The previous entry built the piece that
carries audio safely off the processing thread. This one attaches it to the effect chains
themselves, so any single effect on any track can be asked to report what it is hearing.

Two things had to be true, and both are now proven rather than assumed. The first is that
turning the probe on cannot change your audio in any way — not the sound, not the timing,
not a single sample. Switching it on and off mid-session leaves the output bit-for-bit
identical, and none of an effect's internal state is disturbed, so nothing clicks and no
reverb tail gets cut short when you open or close a display.

The second is subtler. When the audio engine restarts itself — which it does on its own
after certain changes, without telling you — everything gets rebuilt from scratch. A probe
that was switched on before that point has to still be switched on after it. Otherwise the
display stays open showing a reading that stopped updating, which is worse than showing
nothing at all: it looks like silence rather than like a failure. That case now has a test
that fails loudly if it ever breaks.

One unrelated improvement came out of the work. Measuring the audio path closely enough to
prove it never pauses for memory revealed that the effect-chain loop itself had been asking
for small amounts of memory on every pass — harmless in practice, but exactly the kind of
thing that becomes a click under load. It no longer does.

## 2026-07-28 — Groundwork for seeing inside an effect chain

Nothing changes for you in this release. This is the first piece of a feature that will let
you watch the spectrum at any point in an effect chain — before the compressor, after the
EQ — instead of only at the master output.

The hard part is that audio processing happens on a thread that must never be interrupted.
It cannot wait for anything, and it cannot ask the system for memory; if it stalls even
briefly, you hear a click. So the measuring cannot happen there. What landed here is the
handover: the audio thread does nothing but copy samples into a fixed buffer it already
owns, and all the actual analysis happens elsewhere, on the same code that already draws the
master spectrum. Not a copy of that code — the same code, so the two readings can never
drift apart.

The buffer has a fixed size, which means it can fill up if the display side stalls, such as
when the window is hidden. Rather than lag further and further behind or show a torn
half-updated reading, it keeps the newest audio, discards the oldest, and counts exactly how
much it dropped — so the display can be honest about what it missed instead of quietly
lying.

None of this is wired to anything yet: no meter, no menu, no visible change. It ships now,
tested on its own, because getting the handover wrong is the kind of bug that shows up as an
occasional click during playback and is nearly impossible to trace later.

## 2026-07-28 — The commands that quietly accepted anything

Twenty-six of DAW Pro's 161 commands used to ignore options they didn't recognise. Ask one
for a project overview and misspell an option, and it would hand back the overview as if
nothing were wrong. Nothing was corrupted — every one of the twenty-six only *reads* — but
a typo looked exactly like success, which is the one response that teaches you nothing.

All twenty-six now answer the way the other 135 already did: they name the option you got
wrong, and either list the ones they accept or tell you they take none. The check runs
before the command does any work, so a mistyped request never reaches a sidecar, a plugin
scan, or the telemetry counters it would otherwise have reset.

This one reversed a decision rather than filling a gap. Six tests asserted the old
permissive behaviour on purpose — one called it "house style", which it had stopped being
some time ago, once 135 commands did the opposite. Those tests now assert the new
behaviour and say why it changed.

The safeguard is that a command can no longer be added without this check: a test reads
the source, compares it against the command list, and names any command that slipped
through. Worth noting what that test *can't* do — it proves the check exists, not that it
runs first. So the ordering is verified separately, by confirming a rejected request never
touches the engine at all. Moving the check later in one command left the source test
perfectly green and only the ordering test caught it.

Because stricter input checking can break whatever was already sending the old, sloppier
requests, the AI-agent bridge was checked too: every one of the twenty-six sends either no
options at all or exactly the ones now allowed, and its test suite passes unchanged.

## 2026-07-28 — A comment that said the work was done

Eighteen commands in DAW Pro take no options at all. Misspell an option on one of them
and it tells you so by name. That behaviour was only actually *checked* for one of the
eighteen — the other seventeen were running on trust.

They are all checked now, from a single table, with the exact sentence pinned rather than
a loose "does it mention the word I typed". Adding a nineteenth such command is a one-line
addition, and if someone forgets, a test reads the source and fails — it no longer depends
on anyone remembering.

What made this worth doing was finding *why* the gap survived. A comment in the test file
announced itself as a completed survey and listed eight commands as covered. Three were.
The other five had never been tested anywhere, and every later count — including the one
that scheduled this work, and the one this session took to double-check it — inherited the
claim without re-deriving it. The comment has been corrected to say what it actually
covers. A comment is not coverage.

Verified on the live control port: four of the five untested commands were driven over the
real connection and answered exactly as pinned, including one that starts a background
process — it refused the bad option without starting anything.

One more thing surfaced while measuring: twenty-six other commands accept misspelled
options *silently*, with no complaint at all. They are all read-only, so nothing can be
damaged, but an assistant that typos an option gets a cheerful success instead of being
told. That is filed as its own item.

## 2026-07-28 — Packaging the app somewhere other than on top of your copy

The script that assembles DAW Pro into a real `.app` could only ever build it in one
place: `dist/DAWPro.app` — the copy you actually launch. That made the packaging path
awkward to test. Checking that a bundle with the speech-model weights sealed inside it
still passes Apple's signature check meant overwriting your app with a 1.5 GB version of
itself, so the check kept getting deferred instead of run.

It now takes `--output`, so a throwaway bundle can be built off to the side and verified
without your copy being touched at all. Both modes were exercised that way and both pass
the stricter signature check.

Two details worth naming. The script registers the bundle with macOS so "quit DAW Pro"
resolves by name — and that registration is machine-wide and outlives the folder, so a
throwaway bundle would leave a ghost entry competing with your real app. Registration is
now skipped for any non-default output. And because the new flag feeds a path straight
into `rm -rf`, an empty path or one that doesn't end in `.app` is refused outright.

The check that mattered most was the one asked before any of this: does the app actually
look inside its own bundle for those weights? It does. But nothing tested that it did —
the neighbouring tests covered every other location, so that one could have quietly
disappeared and left them all green while every weights-bundled build shipped a gigabyte
and a half the app then ignored. That test exists now.

The bundled mode was exercised with a small stand-in for the weights rather than the real
1.5 GB. That proves the payload lands inside the signature and the app finds it; it does
not prove a copy that size completes. That run is filed and waits for you.

## 2026-07-28 — An error message that trailed off mid-sentence

Ask the DAW to play, and misspell one of the options you pass it, and the error you got
back stopped in the middle: "unknown parameter 'bogus' — valid keys are ". Nothing after
"are". That happened for the eighteen commands that take no options at all — there were
no valid keys to list, so the sentence simply ended. Commands that do take options were
always fine.

Those eighteen now say what is actually true: "transport.play takes no parameters."
Commands with real options are untouched, down to the byte.

The interesting part is what the tests said. The change to the wording should have
broken every test that checked the old sentence — and it broke none of them. Not because
the tests were weak, but because for these particular commands there was nothing
checking that part of the message at all: eight of the eighteen checked only that an
error happened, and ten had no such test whatsoever. The message had been wrong for a
while with nothing to notice.

There are now checks on the corrected wording, including the plural form, which turned
out to be unguarded even after the first fix. The ten commands with no coverage are
written down as work rather than left as a quiet gap.

## 2026-07-28 — The voice tools no longer refuse what the product permits

The voice panel and the voice tools carried a rule that had been withdrawn. They said
you could only train and convert with your own voice, never anyone else's — and that
line was still being shown to you in the app and told to any AI agent connected to the
DAW, long after the decision had gone the other way. An assistant asking what it could
do with voices was reading a prohibition that no longer existed.

The product now says what it actually does: third-party voice models are supported, and
you are responsible for having the rights to any voice you train or convert with. That
is a statement about who carries the responsibility, not about what you are allowed to
attempt. One phrase survived the change untouched — "a voice you have the rights to
use" — because what was withdrawn was the prohibition, not the requirement that you
have the rights.

The old wording lived in fifteen places, which is roughly twice as many as anyone had
written down. Two tests were guarding the old copy; both were pointed at the new copy
rather than deleted, so the words stay guarded. A new check now walks the entire family
of voice tools and fails if the withdrawn rule reappears in any of them — and it earned
its place immediately, catching a description that a hand-written search had missed.

One layer still disagrees: the local voice-conversion sidecar's own documentation
continues to assert the old rule. Those files are on a do-not-touch list, so that
correction is filed and waiting rather than quietly skipped.

## 2026-07-27 — Starting a speech-model download and checking in on it, instead of waiting on it

The speech-model installer from the previous entry could only be driven from inside the
app itself. Now an agent can ask for a model by name and get an answer back immediately
— not the finished model, just an acknowledgment that the download has begun. Checking
whether it succeeded is a separate question, asked as many times as you like, with no
consequence to asking again.

That split matters because the honest cost of this download is unknown in advance: it
could be forty megabytes or a couple of gigabytes, and the network could be fast or
slow or unavailable. A command that waited for the answer would either time out on a
slow connection or hold a conversation hostage on a fast one. So starting the download
and checking on it became two different questions, the same way an audio time-stretch
already works: kick it off, then look in on it whenever you like.

The one rule that had to be enforced rather than assumed: only one of these downloads
ever runs at a time. Nothing before this stopped two requests from both deciding a
model wasn't installed yet and both writing into the same folder at once — the kind of
mistake that only shows up the day someone actually asks twice, which an agent that
doesn't remember asking already might well do. A second request while one is already
running is turned away, told which one is currently in progress, rather than queued or
silently merged with the first.

Checking in on progress meant confronting a small annoyance in how progress normally
gets reported: it arrives on its own schedule, from code that has no idea an agent is
waiting, and there's no guarantee it arrives in order if you're not careful about how
you listen to it. The fix was to always keep only the latest update rather than a
running log — a poller doesn't want history, it wants "where are things right now," and
that question has one right answer at any moment, however the updates arrived.

## 2026-07-27 — Downloading a speech model, and the folder nobody would have looked in

DAW Pro can now fetch a Whisper model for itself instead of expecting one to already
be sitting on disk. The download is WhisperKit's own — we do not own an HTTP client
for this, the same way we do not own a resampler.

The whole item was one mismatch. WhisperKit hands its download to Hugging Face's Hub
client, which files things away as `<base>/models/<repo-id>/<variant>/`. Our catalog
scans the *immediate children* of the models folder. Point one at the other and you
get a complete, correct, multi-gigabyte download that the app reports as "no speech
model installed" — no error, no warning, nothing to search for. So the download is
staged and then moved into the shape the catalog actually reads, and the installer
refuses to call itself finished until the catalog's own scan can find what it just
wrote.

Staging happens inside the models folder as a dot-prefixed directory, not in a temp
folder. Two reasons: same volume means the move is a rename rather than a second copy
of 1.5 GB, and the scan skips hidden files, so a half-finished download can never
show up as a broken model. It is deleted on failure, which was confirmed the hard way
— a real fetch timed out mid-install and left nothing behind.

The tokenizer turned out to be a second download from a different repository
altogether: the WhisperKit model folder contains no tokenizer at all. Without it the
first transcription would quietly go online, which is the one thing on-device
transcription is supposed to avoid. It now lands per-variant, because an English-only
model cannot borrow a multilingual model's tokenizer.

One behaviour is now written down rather than merely true: the model used when nobody
names one is the first in alphabetical order. Install `base` next to `large-v3-turbo`
and every transcription silently switches to `base`. That is pinned by a test so the
decision to change it is a decision, not an accident.

The MCP server's test command used to name its 24 test files one by one. That works
until someone adds the 25th: it compiles, it produces output, and it never runs. The
suite reports all green and the exit code is zero, because nothing was ever told the
file existed.

It now globs the directory instead. A list is something you maintain; a query is
something that stays true.

This was proved rather than assumed, by putting one deliberately failing test on disk
and running both versions against it. The old command: **exit 0, 262 passed, 0
failed**. The new one: **exit 1, 263 tests, 1 failed**. Same file, sitting there
compiled, in both runs — the old gate simply never looked at it.

The glob matches `*.test.js` specifically rather than sweeping the whole directory,
because Node treats *anything* under a folder named `test/` as a test file. A future
shared helper would have been executed as a suite — which is the same class of
surprise, just pointing the other way.

## 2026-07-27 — Transcription is now something you can ask for

`clip.transcribe` (and the `clip_transcribe` MCP tool) turns a clip on the timeline
into words with beats attached. An agent can now ask "what is sung here?" and get an
answer it can edit against.

The interesting decisions were about what to *refuse*.

**A time-stretched clip is refused, not mapped.** A stretched clip's audio no longer
lines up with its source file, so every returned timing would be wrong — but
plausibly wrong, which is worse than an error. It now throws and names the ratio,
telling you to run `clip.setStretch ratio 1` first. The refusal triggers on exact
identity: a ratio of 1.0001 is refused too, because "close enough" silently
reintroduces the drift. Pitch-shift alone is *not* refused — it doesn't move the
timeline — and there is a test whose only job is to hold that line, because the
neighbouring `isStretchIdentity` property bundles the two together and would have
been the easy, wrong guard to reach for.

MIDI clips and unknown clip IDs are refused the same way, with errors that say what
to do instead rather than just what went wrong.

**It blocks rather than returning a job handle.** That follows the precedent already
set by `vc.convertVocals`, not a fresh preference. The MCP timeout is a new 300-second
tier, sized off the measured ~94-second first-run cost on a cold machine — a one-time
Neural Engine compilation, not a per-length cost, so it sits between the render tier
and the voice-conversion tier rather than scaling with clip duration.

The clip-window-to-file-range mapping reuses the existing rule rather than restating
it, and WhisperKit turned out to already clamp a range that overruns the end of a
file, so a clip whose window extends past its source degrades to "read to the end"
instead of reading out of bounds.

One hazard found in passing and **not** silently absorbed: the MCP server's test
script is a hand-maintained list of files rather than a directory glob, so a brand-new
test suite can compile, produce output, and never run — passing green by omission. The
new suite was added to the list; making that structural is filed as its own item
rather than folded in here.

## 2026-07-27 — The DAW can hear words, and knows which beat each one lands on

`WhisperTranscriber` turns an audio file — or a sub-range of one — into text with
**segment and word timings expressed in beats**, not just seconds. Local, on-device,
nothing leaves the machine.

Beats are the point. Seconds are what a speech model returns; beats are what a DAW
can act on. The mapping goes through the project's existing `TempoMap`, so a
transcript stays correct across a tempo change instead of drifting after the first
one.

Three things were measured by running the path rather than reading documentation,
and each changed the work:

- **The resampling was already handled.** The plan called for converting audio to
  16 kHz mono ourselves. WhisperKit does that, and accepts a time range while it is
  at it. Writing our own would have been a second copy of a rule it already owns.
- **Word timings depend on the model, not just the flag.** They require alignment
  heads in the compiled decoder; ours has them, confirmed before a line was written.
- **First transcription on a machine costs ~90 seconds; every later one ~1 second.**
  That is one-time CoreML compilation for the Neural Engine, cached afterwards. It
  is why the transcriber holds a single loaded model rather than constructing one
  per call — and why the forthcoming control command has an explicit decision to
  make about whether it may block.

Two bugs found by running rather than assuming: raw transcripts came back full of
`<|startoftranscript|>` markers because that stripping is off by default; and the
first concurrency test was blind — three simultaneous jobs returned correct text
even with the lock disabled, so "the results agree" could not observe the bug at
all. The invariant is now counted and asserted instead.

Not user-visible yet: there is no command to call this. That is the next step.

## 2026-07-27 — One home for "where DAW Pro keeps things on disk", and an autosave bug that was never going to announce itself

The rule for `~/Library/Application Support/DAWPro/<Category>/` was open-coded in
**nine places across six files in three modules**. It now lives once, in
`DAWCore/AppDirectories.swift`, behind a `Category` enum whose raw value *is* the
on-disk directory name — so renaming a case can no longer orphan a user's files.

**The refactor was the excuse; this was the actual find.**
`ProjectStore.defaultAutosaveDirectory()` and `AutosaveManager.defaultDirectory()`
each computed `DAWPro/Autosave` independently. The manager *writes* the rolling
autosave there; the store *scans* that directory for recovery bundles. Nothing
made them agree — they simply happened to. Had either drifted, autosaves would
have been written faithfully and never offered back, and the failure would have
surfaced only to someone who had already lost work.

They now agree by construction: one producer, the other delegates. A test pins
the equality.

Worth stating plainly, because it is the argument for having done this at all:
when that delegation is deliberately broken, **the new test is the only thing in
the suite that notices**. Fifty tests across eight suites ran against the broken
version and every pre-existing autosave and recovery test stayed green.

Also preserved deliberately: the fallback expression
`systemBase ?? URL(…).appendingPathComponent("Library/Application Support")` binds
as `first ?? (home + "Library/Application Support")`, because member access binds
tighter than `??`. A well-meant parenthesis would silently make the fallback the
bare home directory. That behaviour is unchanged and now has its own test.

Not covered, on purpose: the scratch paths under `NSTemporaryDirectory()/DAWPro`
and the sidecar logs under `~/Library/Logs/DAWPro` are a different rule with a
different lifetime — purgeable rather than durable user data — and folding them in
would let a change to one silently move the other.

## 2026-07-27 — Speech-model weights move out of the repo, and the app learns where to look

The 1.5 GB of Whisper weights no longer live in the working tree. They now sit in
`~/Library/Application Support/DAWPro/Models/`, beside `SoundBanks/`, `Autosave/`
and `VoiceDatasets/` — the same place the rest of the app already keeps large
user-managed assets.

**The app no longer has one place to look; it has an ordered list.**
`WhisperModelCatalog` walks candidates highest-priority first and takes the first
that actually *holds* a usable model:

1. `DAWPRO_WHISPER_MODELS_DIR` — wins outright when set, even if empty, so
   pointing the knob somewhere deliberate yields that place's teaching error
   instead of quietly resolving elsewhere.
2. `~/Library/Application Support/DAWPro/Models` — user-installed weights.
3. `<App>.app/Contents/Resources/Models` — a copy sealed into the bundle.
4. `<repo>/Models` — the dev walk-up, anchored on `Package.swift`.

Application Support deliberately outranks the bundle: it means a small model can
ship inside the app and still be upgraded to large-v3-turbo by dropping the
bigger one in, with no reinstall. The rule is "first **stocked**", not "first that
exists" — otherwise an empty Application Support folder would shadow a perfectly
good bundled copy.

**Packaging is now a choice, defaulting to slim.** `scripts/bundle.sh` ships a
small app and expects the weights to be installed separately;
`./scripts/bundle.sh --with-weights` instead seals them in for a self-contained,
offline-capable bundle — the right call behind a restrictive proxy, at the cost of
re-shipping and re-notarizing ~1.5 GB on every update. The copy happens before
`codesign`, so the weights land inside the seal rather than breaking it.

Not user-visible yet: nothing transcribes. This is the plumbing that decides where
a model comes from, ahead of the capability that uses one.

No shipped behaviour today — this is a design cycle, and the tree's audio path is untouched.

**m23-r (per-insert spectrum tap) is designed and split into r1 → r2 → r3 → r4**
(`docs/research/design-m23r-per-insert-spectrum-tap.md`), superseding
`design-m22b-eq-curve-editor.md` §4.3.

The headline correction: **the FFT does not have to run on the render thread, and it
must not.** The old design assumed that because the tap *point* is on the render thread,
the *analysis* had to be too — and then spent its cost argument on that premise. Only the
sample capture is render-side. The tap becomes two bounded `memcpy`s into a preallocated
lock-free ring; the FFT, band fold and ballistics run on the consumer inside an
**unmodified `MasterMixAnalyzer`**. Track and master spectra are then comparable because
they are literally the same implementation, not because two band tables agree.

Two further corrections, both found by reading the current code rather than the old doc:

- The tap hook belongs in the **chain walk loop**, not in `processActive` — a steadily
  bypassed unit calls `processActive` not at all, and a crossfading one calls it *before*
  its equal-power mix. The old anchor was not merely stale, it was the wrong host.
- **The gate this item was going to be judged by could not see the change it was
  guarding.** The cited EQ null pin builds an `EQEffect` directly and never touches the
  chain walk. Replaced with the real chain-walk pin plus an armed-vs-disarmed
  byte-identity discriminator.

Also filed: **m23-n (WhisperKit transcription) is split into n1 → n2 → n3 and BLOCKED on a
user decision.** The dependency door was measured and the 0-warn build gate survives it
unchanged; what is outstanding is consent, not information. See ROADMAP `## Blocked`.

## 2026-07-27 — Export your stems, and a mastered mix beside them

**REBUILD REQUIRED** — this lives in the source tree only; the copy in `dist/` predates it.

The Export sheet now starts with a choice: **SONG** or **STEMS**. Song is exactly what you had — one file, the whole mix. Stems writes one file per part into a folder you pick, which is what you send to a mixing engineer, a collaborator, or a mastering house.

Two extras ride along with stems, both optional. **A reference mix** — the same sum as your stems, so whoever receives them can check their rebuild against it. And **a mastered mix**, which is the real deliverable with your master chain and loudness target applied. They're independent; take either, both, or neither.

**The card tells you exactly which files you're about to get**, by name, and updates as you change your mind. That list is worth reading, because stems don't map one-to-one onto your track list: **a bus is a stem, and a track routed into a bus is not.** Route a guitar into a reverb bus and you won't see a guitar stem — its sound is inside the reverb bus's file, which is the only way the bus's own effects stay correct. The card says so, and the numbering closes up rather than leaving a gap.

Your depth and container choices apply to both modes, so a 24-bit AIFF song and 24-bit AIFF stems come from the same two controls. And if nothing in your project can produce a stem, the export button stays off rather than handing you an empty folder.

## 2026-07-27 — Save one track's MIDI straight from the track header

**REBUILD REQUIRED** — this lives in the source tree only; the copy in `dist/` predates it.

Right-click any instrument track's header and there's now an **Export MIDI…** item. It writes just that track out as a `.mid` file — the part you're looking at, not the whole arrangement. File → Export MIDI… still writes the whole project; this is the one-track version, and it lives on the track because that's the only place the app knows which track you mean.

The item only appears on instrument tracks. Audio and bus tracks don't have notes to write, so rather than offer you something that would refuse, we don't offer it — the same way "Bounce in Place" hides where it can't work.

Two things worth knowing. **An instrument track you haven't played into yet will still export**, giving you a valid MIDI file with no notes in it — that's a real file, not an error, and it's occasionally what you want as a starting point. And if the file can't be written where you pointed it, **you'll get told**: this is the first action in the track menu that reports a failure rather than quietly doing nothing.

Nothing about the whole-project export changed, and no existing file you export will come out any different.

## 2026-07-27 — An export window: pick your file type and quality before you save

**REBUILD REQUIRED** — this lives in the source tree only; the copy in `dist/` predates it.

The EXPORT button used to go straight to a save box and give you a 32-bit float WAV, every time, with no say in it. Yesterday's release made bit depth and file type choosable, but only an assistant could reach them. Now you can.

EXPORT (or ⌘E) opens a window first:

- **Quality** — 32-bit float (what the app works in), 16-bit (CD quality, smallest files), 24-bit (the usual depth for delivering a mix), or 32-bit integer. WAV or AIFF.
- **Leave tracks out** — untick a track and it's gone from the file. This is how you get an instrumental, and **your project is not changed** — nothing is left muted afterwards, and there's no edit to undo. A track that leaves takes its reverb and delay tails with it, so the result is genuinely clean rather than a vocal-shaped hole full of the vocal's ambience.
- **Match a loudness target** — off by default. Turn it on to land the mix near a chosen LUFS with a peak ceiling, the way streaming services expect.

Three things worth knowing rather than discovering. **The window remembers your choices for the rest of the session** — pick 16-bit AIFF once and the next export is 16-bit AIFF too, and the filename it suggests changes to match; it goes back to 32-bit float WAV when you next open the app. **The name it offers already carries the right extension**, because the extension is what actually decides the file type — take the name it gives you rather than retyping one. And **no loudness number is shown anywhere in this window, deliberately**: the figures we can measure describe the mix *before* it is converted to 16 or 24 bit, so a number beside a 16-bit choice would be describing a different file than the one you're about to get. Rather than print a caveat next to a misleading figure, we print neither. If your mix peaks above 0 it will still be clipped on the way to an integer file — turn on the loudness target, or stay on 32-bit float.

Nothing about the old behaviour changed underneath: open the window, touch nothing, export, and you get exactly the file yesterday's build would have written.

## 2026-07-27 — Choosing the file type and quality you export at (and a silent bug fixed)

**REBUILD REQUIRED** — this lives in the source tree only; the copy in `dist/` predates it.

Until now every export came out as a 32-bit float WAV, with no say in the matter. That is the right *working* format — it is lossless and it keeps peaks that go above 0 — but it is not what most people want to hand over. Bouncing, mixing down and exporting stems now each take two optional choices:

- **Bit depth** — 16 (CD, small files), 24 (the normal delivery depth for mixes and stems), or 32. Leave it alone and you get today's 32-bit float exactly as before.
- **File type** — WAV or AIFF. AIFF is written in the AIFF-C form macOS produces; every DAW reads it.

Two things worth knowing rather than discovering later. **The file extension is what actually decides the file type**, so if you ask for AIFF the name you get back may differ from the name you sent — always use the path the app reports. And **integer depths clip at full scale where 32-bit float does not**, while the loudness numbers in the response describe the audio *before* it is converted — so a mix peaking above 0 will be clipped on the way to disk without the report mentioning it. Normalize first, or stay on the default. Conversion is honest but undithered in this version, and the response says so rather than claiming otherwise.

**A silent bug, now fixed.** An export to a path ending in `.WAV` or `.Wav` — any capitalization other than all-lowercase — wrote a **CoreAudio Format** file with a `.WAV` name on it. No error, no warning; it would simply refuse to open properly elsewhere. This was verified against the last committed build, so it is not new breakage. Such a path is now corrected to `.wav` and you get a real WAV file. The one consequence: the path reported back to you may be spelled slightly differently than the one you gave.

## 2026-07-27 — Handing your song to someone else: a mastered mix beside your stems, and an instrumental

**REBUILD REQUIRED** — this lives in the source tree only; the copy in `dist/` predates it.

Two things you can now ask for when exporting.

- **A mastered mix delivered alongside your separate tracks.** Exporting stems already gave you one file per track plus a plain reference mix. You can now also ask for **"00 Mastered Mix.wav"** — your song with the master chain and master fades actually applied, the same way the mastered bounce makes it. It arrives *next to* the stems rather than printed onto each one, and that is deliberate: when your master chain squeezes or saturates the mix, printing it onto every track separately does **not** add back up to the mix you approved. Logic, REAPER and Studio One all hand it over the same way. Your separate tracks stay clean and still sum back to the reference mix (measured null, not a promise of bit-identical arithmetic), so whoever receives them can rebuild your balance and hear your master.
- **An instrumental, without touching your project.** Bouncing or mixing down now takes a list of tracks to leave out — mute the vocal by hand and you get the same file, but this way your project is not edited, nothing is left muted if the render fails, and there is no dirty document to explain. Worth knowing what leaves with an excluded track: **its reverb tail goes too**, and so does its effect on anything keyed off it (a compressor ducking under the vocal stops ducking). That is what makes an instrumental genuinely clean, and it also means this cannot give you "instrumental but keep the vocal's reverb" — that would be a different feature.

## 2026-07-27 — Planning note: what a complete export set should look like (no app changes)

**Nothing changed in the app in this entry** — this was a research step, and it is recorded here only so the decisions behind the next one are not invisible. We looked at how Logic Pro, Ableton Live, REAPER and Studio One structure exporting, and wrote down what DAW Pro should offer: your song as a `.mid` file (done — see below), separate files per track, a mastered mix, an instrumental with the vocal taken out, and the choice of file type and quality that every other program gives you.

Two things worth knowing from it. **You can already make an instrumental today** — mute the vocal, bounce, unmute — so what we owe you is a single button that does it without touching your project, not the ability itself. And **"mastered stems" is a trap in the obvious form**: printing the master chain onto each track separately does not add back up to your mastered mix, which is why we will ship the mastered mix *alongside* the separate tracks rather than baked into each one, as Logic, REAPER and Studio One all do. One question that would have surfaced as a bug got settled while checking the research: muting a track also removes its reverb tail from a shared reverb, so an instrumental will genuinely leave the vocal's ambience behind rather than half of it.

## 2026-07-27 — MIDI files: open them, save them, drag them in

**This is the one you'll be able to use once the app is rebuilt** — everything below lives in the source tree only; the copy in `dist/` predates all of it. **REBUILD REQUIRED.** DAW Pro now reads and writes `.mid` files — the format every other music program speaks. Drag one onto the timeline and it becomes tracks and clips at the spot you dropped it; hand your song to someone using Logic, Ableton or anything else with File → Export MIDI…. It took five steps to get here and the account of all five is below, newest capability last.

- [x] **Reading the format.** DAW Pro can now make sense of a Standard MIDI File's bytes: notes and how hard they were played, tempo and time-signature changes, mod wheel, pitch bend and aftertouch, and both of the layouts `.mid` files come in — one track per part, or everything on a single track that has to be pulled apart by channel. Broken files say what's wrong instead of looking empty: a truncated or corrupt file gives a clear error naming the problem, rather than the quiet failure where a damaged file opens as though it simply contained no music.
- [x] **Writing the format.** DAW Pro can now produce a Standard MIDI File as well as read one — notes with their velocities and how hard they were released, tempo and time-signature changes, mod wheel, pitch bend and aftertouch, in either of the two layouts (`.mid` files that keep each part on its own track, or the single-track layout that packs everything together). macOS's own MIDI reader opens what we write and gets back the music we meant. Where the format simply cannot express something — a note played at zero force, which in a `.mid` file means "stop the note" rather than "play it quietly", and would make the note vanish from a file that still opened fine — DAW Pro refuses and says so, instead of writing a file that looks healthy and is silently wrong. At the time this landed it was the engine and not the button; the button is the last step below.
- [x] **Importing one into your project.** A `.mid` file now becomes tracks and clips in your song: one track per part, each with its notes, their velocities, and the mod wheel, pitch bend and aftertouch that went with them. A file that packs several instruments onto one track is pulled apart into one track each, so a piano and a bass never end up sharing a fader — or overwriting each other's mod wheel. What happens to your tempo is a choice you make: by default the file sets the grid only when your song is still empty, so your first import establishes the tempo and a later one never silently moves everything you have already recorded; you can also say "always take the file's tempo" or "never touch mine". Either way **the notes land on exactly the same beats** — a `.mid` file measures time in beats, not seconds, so its tempo governs how fast it plays and never where the notes sit. The whole import is one undo. Anything the file asks for that DAW Pro cannot represent is reported rather than quietly dropped — an impossible tempo, a time-signature change that lands mid-bar, more controller lanes than a clip can hold, per-note aftertouch — so you always know what you did and did not get. At the time this landed you needed an assistant to trigger it; the last step below is the part you reach yourself.
- [x] **Handing your song to another program.** DAW Pro can now write your project out as a `.mid` file — the whole song, or one track on its own. Every instrument track becomes a part with its notes, velocities and controller moves, your tempo and time-signature changes ride along at the front of the file, and drum tracks land on the channel every MIDI player treats as drums. Audio tracks are left out and *named*, so "where did my vocal go" has an answer in the report instead of a mystery. What you get is what you *wrote*, not what you currently hear: a muted track is still in the file, and so is a note that runs past the end of its clip — export saves your work, it does not mix it down. macOS's own MIDI reader opens what we write and reads back the notes and tempo we meant. Anything the format cannot hold exactly is reported before it happens (run it as a rehearsal first and nothing is written): a note nudged off the grid by a fraction of a millisecond, two notes of the same pitch that overlap, a clip's fades and gain, a tempo the file's own units can't name to the last decimal. **One honest gap, said out loud rather than buried:** the file does not yet tell the receiving program *which* General MIDI instrument each track wants, so it will use its own default sounds; the instrument each track asks for is listed in the report, and making it land in the file is the next small step. At the time this landed it was reachable only by an assistant; the last step below is the part you reach yourself.
- [x] **The ways you actually reach it.** Drag a `.mid` from Finder straight onto the timeline and it imports where you dropped it — on the beat the drop line showed you, not near it. Snapping applies, so a file dropped roughly at bar 3 starts exactly at bar 3. The File menu has **Import MIDI…** and **Export MIDI…** alongside the audio entries. You can drop a `.mid` and a `.wav` together and both land on the same beat.
  - **A `.mid` used to be accepted and then quietly ignored.** macOS classifies MIDI files as audio, so the timeline and the ⌘I panel already took them — and then the import, which only understands real audio, dropped them with a note you never saw. Dragging a `.mid` in looked like it worked and did nothing. That is what this step actually fixed, and it is why ⌘I no longer offers `.mid` files: Import MIDI… is where they belong.
  - **The timeline stops promising a landing it won't honour.** Dragging a single audio file over an existing audio track highlights that track, because that is where the file will go. A `.mid` never lands on an audio track, so it no longer lights one up — the drop line still shows you the beat.
  - **Two things worth knowing.** A `.mid` dropped into an *empty* project sets your tempo from the file, the same rule imports have always used; drop it into a project that already has clips and your tempo is left alone. And a mixed audio-plus-MIDI drop is **two** undo steps, not one — press undo twice to take back the whole gesture.
  - **Still missing, and worth saying:** a `.mid` that fails to import from a *drag* does not raise an alert — the two File-menu entries do. And exported files still don't name which General MIDI instrument each track wants, so another program opens them on its own default sounds.

## 2026-07-26 — Drag your tracks into the order you want

- **Tracks reorder vertically.** Grab a track's header in the arrange page and drag it up or down; the list parts to open the slot you're aiming at, and a line marks the edge the track will land against. Until now track order was fixed at creation — the order you happened to add things in was the order you were stuck with.
- **The preview is the result, not an impression of it.** The rows that slide out of your way move by exactly the distance the committed reorder will move them, so what you see mid-drag is where things end up.
- **It's one undo.** A reorder is a single step in the history, labelled with the track's name, and undoing it restores the exact previous order. Dropping a track back where it started does nothing at all — no stray entry in your undo history.
- **Nothing about your mix changes.** Sends, output routing, automation and clips all follow their track, because they were never bound to its position. Reordering is purely visual; it cannot alter what you hear.
- **Agents can reorder too.** New `track.reorder` control command and `track_reorder` MCP tool, so an assistant can tidy a session's track order the same way you can.

- **And now the mixer's strips drag too.** Grab a strip by its name and slide it along the rack; the console parts to open the slot, and a line marks where it lands. There is only ONE track order in the project, so a strip you move in the mixer moves in the arrange page as well — the two views never disagree about what order your tracks are in.
- **The mixer draws channels first, buses after the divider** — and a strip you drag stays in its own group.
- **Because there's only one track order, moving a strip in the mixer can shift where a bus sits in the arrange list.** That's deliberate: both views read the same order, so they can never disagree about it. If you'd rather buses held their place, say so and we'll make the mixer refuse those drops.
- **A drop that wouldn't change what you can see does nothing at all** — no line while you drag, no entry in your undo history.

## 2026-07-26 — Drag a box around clips to select them

- **The timeline has a rubber band.** Drag across empty space in the arrange page and a translucent cyan box follows your pointer; every clip it touches is selected when you let go. This is the piece the multi-select release said was still missing: shift-clicking six clips one at a time works, but drawing a box around them is what you actually reach for. Hold shift while you drag and the box *adds* to what you already had.
- **It selects what the box touches, and it gives clips back when you shrink it.** Sweep too far, pull back, and the clips you overshot are released again — the box re-decides from the selection you started with, rather than accumulating everything it has ever crossed.
- **A drag with no width or height selects nothing.** That sounds like a triviality and it is not: without it, a click that wobbled by a pixel would silently replace your whole selection with whichever clip happened to be under the pointer.
- **The bug this could most easily have shipped with, and did not.** Rows in the timeline are *not* evenly spaced — a track with its automation lane open is 64 points taller than its neighbours. Work out which track a box covers by dividing by the row height and you get the right answer in every project that has nothing expanded, and the wrong track in every project that does. The box asks the timeline where each row actually is instead, and the code that does the maths is physically incapable of dividing by a row height: it is only ever handed the real positions. We proved the test can see the difference by computing both answers and confirming they disagree before checking which one the app gives.
- **Clicking to move the playhead, and double-clicking to start a new part, both still work.** They share the same surface as the new drag, and the way they are layered together was chosen deliberately once before to keep clicks feeling instant. The most interesting check reproduces the exact sequence that broke a similar feature two releases ago: click empty space (which moves the playhead to that point), then start dragging a box from that same point. A "safety check" that seemed sensible would refuse the box there, and would have passed every other check in the file.
- **Selecting is not opening.** Boxing a single clip does not fling the note editor open, even though clicking that clip would. A box has no one clip you pointed at, so choosing one for you would open an editor on a clip you never clicked — and since the box updates as you drag, the editor would flicker from clip to clip as it swept.
- Verified against a running app: **38 checks**, plus **two picture-based ones** confirming the box is genuinely drawn on screen and genuinely gone afterwards — the window with a box standing looks different from the window at rest, and returns to it pixel for pixel on release. Six deliberately broken builds were each caught by the right check. Suites: Swift 3578/378 zero warnings, agent-server 212/212. **No new commands and no new agent tools.**
- **Three things we learned the hard way and are recording rather than glossing.** A check that *skips itself* when conditions are awkward is a check that passes — the picture checks originally stepped aside on an unlucky frame, and the very first broken build we tried sailed through with the box never drawn at all; they now fail instead of skipping. Restoring a file is not restoring the program built from it, which cost a confusing round of debugging when a "clean" run was quietly testing the previous broken build. And the system's own rectangle type silently tidies up backwards drags, so an entire set of checks about dragging right-to-left passed against code that did no tidying at all; that guarantee is now checked where it can actually be seen.
- **Not claimed:** these checks drive the app's own handlers, because macOS gives no way to synthesise a real mouse drag or a real click from outside. They prove the handlers are correct and reachable; a human with a mouse still has to confirm that clicking and double-clicking feel unchanged now that a drag shares the surface. **Not included:** selecting whole *tracks* by boxing their headers is separate work and is not part of this.

## 2026-07-26 — Drag a selection and the spacing between clips survives

- **Selecting several clips and dragging one now moves all of them**, which is the piece the last release said was missing. Grab any clip in the selection and the whole group travels together, across as many tracks as you have selected.
- **The spacing between them is preserved exactly, and that is the entire point of the feature.** The obvious way to build this quietly destroys your arrangement: if each clip snapped to the grid on its own, a clip on the beat and a clip half a bar later would both land on the *same* beat — welded together, one of them eaten by the other. So snapping is treated as a property of the *drag*, not of each clip: the clip under your pointer snaps, once, and everything else moves by exactly that much. We proved this the hard way, by building the broken version too and keeping it in the test suite forever, where it demonstrates on every run that clips at beats 0 and 2.5 collapse onto beat 4 and one of them is cut from two beats down to half a beat.
- **Dragging a group into the start of the song no longer scrambles it.** When the leftmost clip reaches the beginning, the whole group stops there together. Previously, the rule that stops a *single* clip at the start would have stopped only that one clip while the rest kept going — so a shove to the left would silently squash your spacing. The trade we chose, deliberately: in that one case the clip you grabbed can end up off the grid. Keeping your spacing intact matters more, and the timeline's readout tells you where the clip actually landed rather than where you asked for it to go.
- **A data-loss bug that this feature could easily have shipped with, prevented by design.** Select two clips far apart on the same track — say bar 1 and bar 9 — and drag them. The straightforward implementation treats "bar 1 through bar 9" as one span and clears everything inside it, which would have deleted a clip sitting at bar 5 that neither of your clips ever touched. Each moving clip now only claims the space it genuinely lands on. There is a check that reconstructs the wrong version and confirms the innocent clip is destroyed by it, so this cannot quietly regress.
- **A whole drag is one undo.** Moving three clips and pressing ⌘Z puts all three back, along with anything they trimmed on the way. Dragging a *single* clip reads in the Edit menu exactly as it always did.
- **Grabbing a clip that is not selected selects it first and moves only it.** Otherwise a selection you had forgotten about would come along for the ride.
- Verified against a running app: **38 checks** reading positions from the project itself rather than the app's own report of them, plus **six deliberately broken builds** — per-clip clamping, the one-big-span version, a non-incremental drag, a missing undo key, split-up undo, and unsorted processing — each confirmed to fail the checks that are supposed to catch it. The last of those initially passed everything, which is how we found that the ordering only matters for crossfaded clips; a test for that case now exists. Suites: Swift 3553/377 zero warnings, agent-server 212/212. **No new commands and no new agent tools** — agents could already move clips one at a time; group moves on that surface are filed as separate work.
- **Not claimed:** these checks drive the app's drag handler directly, because macOS gives no way to synthesize a real mouse drag from outside — a human still has to confirm the pointer feel. **Still missing:** dragging clips *up and down* between tracks does not exist yet, for one clip or for many, and this change does not add it. Arrow-key nudging is the next piece. **One rough edge we did not smooth:** if a clip is already sitting off the grid and you nudge the group by a hair, the clip you grabbed snaps onto the nearest grid line and everything moves with it — your spacing survives, but the group shifts slightly more than you asked. That is how dragging a single clip has always behaved.

## 2026-07-26 — Select several clips at once, and delete them as one undo

- **The arrange page finally has multi-select.** Shift-click or ⌘-click clips to build up a selection across as many tracks as you like, and click a selected clip again to drop it back out. Until now only the note editor could select more than one thing, so on the main timeline you could act on exactly one clip at a time.
- **Deleting a selection is ONE undo step, not one per clip.** Delete three clips and a single ⌘Z brings back all three, with their notes, at their original positions. This is the whole point of the feature and it is the thing we tested hardest: we deliberately rebuilt it the naive way — a loop that deletes clips one at a time — and confirmed our checks caught it, reporting three undo steps where there should be one. Worth knowing *why* that matters: under that broken version, checks like "the clips are gone" and "one undo looks right" **still passed**. Only counting the actual undo history told the truth.
- **A bug we introduced, found, and fixed before shipping — and it is worth being plain about it.** The first version listened for the Delete key too broadly, so this could happen: select some clips, then open a panel such as Quantize, then press Delete. The clips were destroyed behind the panel you were looking at, in one silent edit. We measured it doing exactly that. Delete is now refused whenever a panel is open, whenever you are not on the arrange page, and whenever you are typing in a name field — and we verified the refusal by proving the same key press *does* delete when no panel is open, so it is a real guard and not a dead code path.
- **Your rename fields got their focus rings back.** Fixing the above also removed a stray setting that had been suppressing the focus outline on every rename box, Copilot input and Settings control in the app.
- **Renaming a clip still can't delete it.** Delete is a plain key press on the timeline rather than a menu shortcut, on purpose: menu shortcuts are handled *before* text input, which would have made Backspace destroy clips while you were editing a name.
- Known limits, stated rather than glossed: **deleting is currently the only thing a multi-selection does** — selecting three clips and dragging still moves only the one you grabbed, because group dragging is the next piece of work. Shift and ⌘ both mean "toggle this clip" for now; proper range-select needs the rubber band, which comes after that. And closing the note editor clears a whole multi-selection, not just the clip you were editing.

## 2026-07-26 — Dropped audio lands where you aimed, and the line goes away

- **The stranded line is gone, and we found out what it actually was before touching it.** It was the cyan drop indicator — the guide that shows where a dragged file will land. It is armed by the system's drag messages and cleared by them too, so when one of those messages never arrived, the guide simply stayed: a full-height glowing line you could not click, drag, or delete, because it was never a real object in your song. It was identified by measuring it, not by guessing: 224 pixels tall, which is the exact full height of the lane area and more than twice what a stray clip could have been.
- **The fix does not depend on knowing which message the system dropped** — we could not determine that, and we are not going to pretend otherwise. Instead there are three independent layers, and the important one is this: **your next ordinary mouse move over the timeline clears any leftover guide.** Even if the system misbehaves in a way we have never seen, you are one mouse movement away from a clean screen. It cannot cancel a guide during a real drag, because that check only runs when no mouse button is held.
- **Dropped files now magnetise to the places you actually aim for** — the very start of the song, and the start and end edges of clips already on that track. Those edges are often *off* the grid (a clip you trimmed by ear, a generated part with an odd length), which is exactly why the grid alone was not enough. The pull has a small, fixed radius on screen, so it feels the same at every zoom and can never drag your drop across a whole beat at normal zoom. **If you have turned snapping off, nothing magnetises** — off means off.
- **The guide and the drop can no longer disagree.** Before, the line you saw and the beat the file landed on were worked out twice, in two different places, and matched because they happened to use the same inputs. Magnetism would have broken that, because the timeline knows where clip edges are and the import machinery does not. Now one piece of code decides the landing beat, once, and the answer is carried through to the file — the second calculation does not exist any more. This was not just tidied and hoped for: we re-broke it on purpose to check, and found that with the old two-calculation design, one snap setting still agreed by coincidence while the rest fell apart. That is precisely the kind of bug that hides for months.
- **A second, unrelated way to get an unremovable mark was found and fixed on the way.** An audio file with no sound in it at all imported as a clip of exactly zero length — a sliver you could not grab or delete. It now lands at the same minimum length anything else can be trimmed to.
- Verified against a running app: **29 independent checks** on top of the 24 the change shipped with, reading where clips actually landed from the project itself rather than trusting the app's own report of it. Drops were confirmed landing exactly where the guide promised at four different snap settings, and the magnets were tested against a deliberately off-grid edge so that a version which quietly fell back to the plain grid would fail. Both check suites were also run against **deliberately broken builds** to confirm they can still fail. Suites: Swift 3496/373 zero warnings, npm 212/212; **no new commands and no new agent tools.**
- **Two things are not proven and are not claimed:** that macOS delivers its drag messages in the order tested here, and that a real drag from Finder is correctly detected as "button held" inside this app. Both need a human with a real file and a real drag. Dragging **several** files at once is unchanged for now — it is waiting on multi-selection, which is the next piece of work.

## 2026-07-26 — Double-click an empty lane to start writing notes

- Adding a track used to leave you nowhere to go. The note editor only ever opened on a clip you already had, and a brand-new track has none — so the only ways to start writing were to ask an agent or to know a command. **Double-click any empty spot on an instrument track** and a clip appears there, with the note editor open on it and the grid ready.
- It starts **where you double-clicked**, not at the beginning of the song, and it snaps to the same grid a single click already seeks to — so the clip's start and the playhead land on the same beat whichever of the two clicks the system decides to honour. That is by design rather than by luck: both read the same one piece of arithmetic.
- The clip is **one bar long**, and one bar means one bar of the meter actually in force at that spot — seven beats in a 7/8 section, not a fixed four. If there is already a clip to the right, the new one stops where that one starts instead of running over it. That is not tidiness: writing over a neighbour would have quietly trimmed the notes already living there, from nothing more than a double-click on empty space.
- **Double-clicking a track that cannot hold notes says so.** An audio or bus lane answers with the same sentence the app gives an agent for the same request, in an amber note right where you clicked — never a click that simply does nothing, which is the complaint this whole item exists to fix, one surface over.
- One undo removes the clip and leaves the track. Double-clicking an existing clip still splits it, exactly as before.
- A flaw in the app's own **self-checking** machinery was found and fixed alongside this, and it is the kind worth naming. The channel automated checks use to ask "what happened?" was answering one question late — it reported the result of the *previous* request instead of the one being made. That does not usually break a check; it does something worse. Because the stale answer is a real answer from a real earlier action, a check can read it and **pass on the wrong evidence**. It now waits — briefly, and with a hard stop — for the screen to actually catch up before it answers, so the request that causes a change is the one that reports it.
- Verified against a running app: 38 checks including the clip landing on the double-clicked beat at two different zoom levels, the editor opening on **that** clip rather than merely being open, the audio-lane refusal reading identically to the wire's answer, the neighbouring clip keeping its note, a 7/8 section yielding a seven-beat clip, and a sweep down the height of a lane confirming that the hover hint and the double-click always agree about which track you are on. **One thing is not proven and should not be claimed:** these checks drive the app's own double-click handler directly, so they cannot show that a real two-click sequence reaches it on a surface whose single click already moves the playhead — a human has to close that. Suites: Swift 3468/372 zero warnings, npm 212/212; **no new commands and no new agent tools** — the app already knew how to make a clip, the screen just had no way to ask.

## 2026-07-26 — You can hear the note you are dragging

- Drag a note up or down in the note editor and you now **hear the pitch** as it moves, on that track's own instrument. Click a key in the piano keyboard down the left edge and it sounds too; slide up the keys and it glissandos. Nothing is written, nothing is recorded — it is a preview, and the note goes quiet the moment you let go.
- It works with the transport **stopped**, which is the case that matters when you are editing, and it works **while the song is playing** without touching a single note of the playback. That is not a promise made in prose: audition reaches the instrument on its own path, with its own bookkeeping, and its own answer to congestion — if audition ever floods, only the audition notes are cut, never what the song is playing. The alternative, which would have been one line shorter to write, silences the whole track.
- **A held note cannot get stuck**, and the reason is worth stating plainly. Every 500 ms the app tells the audio engine "yes, still holding this." The audio side gives it three seconds; if that reassurance stops arriving — the app froze, crashed, was suspended — the note is released from inside the audio engine itself, with no app involvement required. A key you are genuinely holding down is never cut short, because the reassurance arrives six times over in every window.
- Two notes of the same pitch from two places used to be the classic way this feature ships a bug: press C on a MIDI keyboard, drag a note onto C, release the drag, then release the key — and one of the two voices sustains forever. Audition and your hardware keyboard keep entirely separate books here, so each release ends the note it actually belongs to. There is a test that fails on purpose if they are ever merged.
- Agents can audition too: one new command, `note.audition`, sounds up to eight pitches for a set duration and releases them itself. If the track is muted or its plugin is still loading it says so in the answer — `audible: false` with a reason — instead of failing or pretending.
- If you would rather edit in silence, there is a switch; it is on by default, and it stays how you leave it. The agent command deliberately ignores it, because "don't make noise while I drag" is not the same instruction as "never make sound."
- **A take starts silent.** Starting a recording while a note is held now releases it. Refusing to start *new* auditions during a take was never enough on its own: a note already sounding would have carried straight through the recording, re-asserted every 500 ms, audible to you and invisible to the recorder — heard and not captured, which is exactly the lie the refusal exists to prevent.
- One design defect was found and fixed during the build rather than after it: the safety-release path could write past the end of its own event buffer when the song was dense enough — a real memory fault on the audio thread. It was reproduced with a failing test first, then closed, and the design note was corrected.
- A second defect was caught in verification, before this ever reached a build you could run, and it is the one that mattered: with the transport stopped the note **spoke for an instant instead of being held**, and then spoke a second time when it was released. The cause was a single shortcut deep in the audio engine — when a track has nothing scheduled and nothing new arrives, it skips the instrument entirely and writes silence, which is right for an idle track and wrong for one holding a note you have your finger on. The instrument is now kept running while anything is held, and for long enough afterwards that a note's natural fade-out is never chopped off mid-tail.
- Verified as **sound**, not as a successful reply — and the checks were rebuilt after the miss above, because the original ones could not have caught it. It is not enough to ask "did it make a noise" and "did it stop": a note that sounds for a fraction of a second passes both. So the test now asks whether the level stays **flat for the whole time the note is held**, and whether the note **starts exactly once**. Against a real running app with the transport stopped: the master bus rises from a −80 dB floor to −6.8 dB and holds within **2.6 dB across the middle of a three-second note**, with **exactly one** onset, then releases to the floor. While the song played, the audition added 7.5 dB on top of the running mix, the playing notes never dropped below −14.4 dB underneath it, and after the audition released the mix returned to within **0.8 dB** of exactly where it had been — the measurement that shows an audition ending does not disturb the song. Both new checks were confirmed to fail on the broken version before being trusted on the fixed one. Suites: Swift 3456/371, npm 212/212; commands 152 → 153, MCP tools 155 → 156.

## 2026-07-26 — The view can follow the playhead now

- Press play and the arrangement used to sit still while the music left the screen. There is now a **FOLLOW** switch in the arrange toolbar: with it on, the timeline and the note editor both keep the playhead in view for as long as the transport is rolling. It is off until you ask for it, and it stays however you left it — including after a restart.
- It turns pages rather than gliding. The view holds still while the playhead crosses it, and when the playhead nears the right edge the whole view jumps forward one screen and drops it back in a little way from the left, so you can still see the bar it just played. That was not a taste call: both behaviours were built and driven through the same eight bars of the same session, and the gliding one asked the view to re-lay itself out **262** times where paging asked **4**, taking the app's main thread from 15 ms to 49 ms per round trip. Forty-nine milliseconds is longer than the gap between two playhead updates — the smooth-looking option was the one that could not keep up.
- **If you scroll while it is following, it stops following and says so.** The switch changes to an unfilled outline: still armed, not currently driving. Nothing fights your mouse, nothing snaps back a third of a second after you let go. Press play again, or click the switch, and it picks the playhead back up. Scrolling the note editor stands down the note editor only — the arrangement keeps following.
- The note editor follows on all three of its bands at once, so the notes, the velocity lane and the controller lane never disagree about where you are. Following moves the view sideways and only sideways: the pitch range you scrolled to stays exactly where you put it.
- Verified under real playback rather than by jumping the transport around: eight samples of each surface across half a minute of rolling, with the playhead measured in the actual pixels of each band, plus the switch turned off through identical playback to confirm the view stays put, plus the preference surviving a genuine relaunch of the app. Suites: Swift 3402/365, fully green, npm 207/207, zero new commands.

## 2026-07-26 — The note editor tells you where the playhead went

- "The playhead doesn't move" was the report. It moves — but only while the transport is inside the clip you happen to have open, and outside that span the editor drew nothing at all. Open a clip at bar 5, hit play from the top, and for the first eight seconds the note editor sat perfectly still. That silence was deliberate once: a playhead is a claim about where the transport *is*, so rather than park a line at the edge and lie about it, the editor said nothing. Honest, and completely unhelpful.
- Now the absence is annotated instead of silent. When the transport is outside the clip, the edge it lies beyond carries a soft cyan wash and a small readout — `◀ 3.5 BARS`, then `◀ 2.9 BEATS` as it closes in. It brightens as the transport approaches, so the editor visibly moves the whole way in and you can see the music coming before it arrives.
- The distinction that made this safe to add: the old rule forbids a *playhead* parked at an edge, and it still does — the line's behavior is untouched. What is new is not a playhead. It is pinned to the window rather than the timeline, so it stays put when you scroll, which is something a real playhead can never do; it is never a hairline, never wears the playhead's glow, and it states a direction and a distance rather than a position. It also never rounds down to "0" — a zero distance would read as "at the edge," which is exactly the claim it exists to avoid making.
- The line and the marker are driven by the same single test, so exactly one of them is ever on screen and the hand-off at the clip's edge is exact — no flicker, no moment where both draw. Both the note grid and the velocity lane get the marker, because a playhead that spans both bands and a marker that doesn't would leave the two disagreeing about where the transport is.
- Verified on the actual complaint: real playback into a clip at bar 5, sampling the off-clip stretch that used to be pixel-for-pixel frozen — every frame now differs. Suites: Swift 3383/364, npm 207/207, zero new commands.

## 2026-07-26 — The piano roll has actual piano keys now

- The keyboard down the left of the note editor was reported as reading "gray," and it was: both key colors were dark. The white keys were a dark slate barely distinguishable from the black ones, so the column that is supposed to tell you at a glance which row is which pitch told you almost nothing. White keys are now a real ivory, and the alternation reads instantly — it looks like a piano, because it is one.
- Turning the keys light meant everything drawn *on* them had to change too, and that is most of the work here. The app's chrome is built for dark backgrounds: its separator lines, octave rules and label text are all pale, and pale-on-ivory is invisible — measured, they landed between 1.0:1 and 2.2:1, which is to say gone. So the gutter became the app's one light surface with its own set of inks, each measured against the ivory: octave labels went from 4.1:1 to **10.1:1** and read identically at every octave from C-1 to C9, and the line between two neighbouring white keys — the only thing that makes the E|F and B|C pairs read as two keys rather than one tall one — is now a real key gap instead of a whisper.
- Middle C is still marked, but neutrally: a bold label over a short dark anchor bar at the key's edge, instead of the cyan it used to wear. Cyan means active transport in this app — it is the playhead in this very view — and spending it on a landmark that never moves was borrowing meaning the color needs elsewhere. On ivory it measured 1.07:1 and would have been invisible regardless.
- The note grid itself is deliberately **unchanged**. It stays dark so note blocks keep popping against it; its lane alternation was measured as already above the threshold where the eye separates two tones, and note contrast doesn't vary between lanes. Lightening it would have bought nothing and cost legibility. Suites: Swift 3378/364, npm 207/207, zero new commands.

## 2026-07-26 — Mixer strips stop eating themselves: the fader is always there, and there's a knob now too
- A user report — "in the Mix tab, when it adds inserts and other instruments or effects it eclipses the volume scales" — turned out to be worse than it read. A channel strip's fader carried a hard minimum height, and a hard minimum is something the strip hands up to the whole console; the console has no vertical scroll, so once a track collected a full effect chain the mixer started demanding more height than the window had. At a 760 pt window it pushed the app's own header row and the transport bar clean off the screen; at 640 it also cut the dB readout and the Mute/Solo/Arm buttons away entirely, with no way to reach them. Fixed properly rather than nudged: a strip now reserves its fader region — the knobs, the fader, its meter, the dB number and the Mute/Solo/Arm row — as space that **never** yields, and the effects chain above it becomes the one part that gives way, hugging its content while it fits and scrolling inside its own bounds when it doesn't. Whatever you stack on a track, the volume controls stay put, and the window's chrome stays on the window.
- Two things arrived with the fix. The INSERTS heading grew a **fold arrow** and a count, so you can tuck an eight-effect chain out of the way for a round of manual fader work and still see that it's eight effects long (the setting sticks across relaunches, and starts expanded so nothing disappears on you). And every strip grew a round **volume knob** beside the pan knob — the same level the fader sets, in a control that always fits, for exactly the moment the report described. It is deliberately in *both* Simple and Pro: volume is the most beginner-primary control on a strip, and hiding the compact one in Simple would remove it precisely where a newcomer benefits most. It wears the app's volume cyan (pan stays neutral white — pan has no meaning-color), sweeps from silence with a tick at unity so it can never disagree with the fader about where "0 dB" is, and shares one gain-to-angle calculation with everything else in the mixer. Making room for it, the pan number moved up beside its own label (`PAN L64`) instead of sitting on a line of its own — a strip's vertical space is contested, and that one line was the difference between a full effect chain fitting at the default window and its OUTPUT row being cut in half.
- The master strip needed a different answer and got one: its anatomy — chain, automation, fader, loudness, stereo image, reference row — genuinely cannot fit the smallest window the app allows, so it now scrolls internally instead of clipping, and stretches back out to fill whenever there's room, so at ordinary window sizes it looks exactly as it did. Nothing on it is unreachable any more. Pure view work throughout: **zero** new commands and zero new AI tools, verified byte-for-byte. Proven with staging captures across three window heights, both densities, and four chain lengths — every one checked for the bottom-most control actually being present, not merely for the fader being visible. Suites: Swift 3378/364, npm 207/207.

## 2026-07-26 — The reference track gets its face: A/B on the strip, the whole comparison in one panel
- The reference-track workflow is now something you can *see and press*, not just something an agent can drive. Load a finished song you trust and the master strip grows a compact REFERENCE row — the record's name, a MIX | REF chip pair, and the level-match number — that appears only when a reference is loaded and shows in both Simple and Pro, because "does my mix hold up against that record?" is a beginner question. Press REF and the mix mutes while the reference plays, turned up or down to sit at *your mix's* measured loudness, so the comparison isn't won by whichever is simply louder. That is also the app's core teaching moment here, and the in-app help says it out loud: the reference can sound quieter than it does on a streaming service, and that is deliberate.
- Clicking the row opens the REFERENCE panel: the file and its length, the A/B cluster with a plain-language line explaining exactly what the match is based on (your mix's loudness, or a standard streaming level when nothing has played yet, or an amber "turned down to protect your speakers" when a full match would have clipped), timing OFFSET and TRIM steppers, a two-curve spectrum — the reference's whole-song average in plain white under your mix's live curve in glowing cyan, on one shared frequency scale — and a row of differences (loudness, peak, range, width, phase) with a beginner sentence under it: "Your mix is 3.4 loudness units quieter than the reference." Where the mix has no evidence yet, the numbers read a dash rather than a fabricated zero, and the mix curve really is a rolling average, exactly as its label claims.
- Design discipline held throughout: **no violet anywhere** — a reference is a record you chose, not AI-generated material — the panel adds **zero new commands** (every button routes to the same store method the `reference.*` wire verbs call, so a reference imported by hand and one imported by an agent are byte-identical), and the meters use the always-ticking poll pattern rather than the one that freezes when the app isn't frontmost. The in-app copilot learned the workflow as a curated four tools (catalog 61 → 65) with the other four verbs taught inside their descriptions, so "compare my mix to the reference" is now a first-class AI move. Pixel review caught and fixed three real layout defects before landing (an empty panel padded out with dead glass, the missing-file banner pushing the caption past the card edge, and frequency labels sitting off their own gridlines — a label that doesn't point at its line lies about where the energy is). Verified on a live app: a real WAV imported and analyzed over the wire, the level match matching the law exactly, the deltas reproducing reference-minus-mix to the last digit, and two captures three seconds apart proving the panel keeps repainting while the app sits in the background. Suites: Swift 3367/363, npm 207/207. With this, the reference-track workflow (m22-g) is complete.
- One more defect fell out of independent pixel review after that: on the master strip, a wide level-match number (`+11.4 dB`, ordinary when the reference you're chasing is a quiet demo) squeezed the MIX | REF chip beside it down to an unreadable `M… | R…`, while a narrower `-5.8 dB` left it intact. The row had room the whole time — the layout was splitting its width rather than running out of it — so both the chip and the number now hold their own size instead of competing, and the reference's name stays the one thing in the row allowed to shorten. Confirmed at every value the level match can physically produce, right out to ±24 dB, in both the strip and the panel.

## 2026-07-26 — Opus 5 lands: the copilot can pick the new flagship
- Anthropic shipped Claude Opus 5, and the in-app AI copilot's model picker now offers it: `claude-opus-5` joins the curated catalog as the flagship-reasoning row (128K output ceiling, adaptive thinking with summaries visible in the transcript, same as its siblings), with Opus 4.8 and 4.7 renamed to "previous" and "older" flagship rather than dropped — anyone who already selected one keeps it instead of being silently reset to the default. Fable 5 stays offered above it as the highest-capability tier, and Sonnet 5 remains the balanced default nobody has to think about. Additive throughout: no new commands, no new MCP tools, both existing `ai_copilot_*_model` tools surface the new row automatically. Suites: Swift 3338/362, npm 207/207.
- The request-shaping side needed no change, which is the point of keeping one table: `AnthropicModelCatalog` already routes per-model max-tokens and thinking config from a single array, so Opus 5 was one row plus its pins. Also refreshed the development-side routing table in the project constitution to match the agent definitions — the whole design-and-implementation fleet (architect, DSP, app, UI) now runs on Opus 5 at half Fable 5's price, with the narrow test-gated lanes staying on Sonnet 5 and docs on Haiku 4.5 — plus the model-selection notes in the AI-integrations doc.

## 2026-07-20 — The delay learns musical time: tempo-synced divisions
- The built-in delay now thinks in note values, not just milliseconds: flip SYNC on and pick from 18 divisions — 1/1 through 1/32, each in straight, dotted, and triplet flavors — and the effective delay time derives from the project tempo (a 1/8 dotted at 120 BPM is exactly 375 ms). Change the tempo and every synced delay retunes automatically; bounces resolve the same math at the render's start tempo, so live and offline can't disagree. The free-run milliseconds value is preserved untouched underneath — switch sync off and you're exactly where you left it, and old projects load byte-identical.
- The seams are engineered honestly: all tempo math lives in one tested DAWCore home (the delay's real-time code is byte-untouched — the control plane substitutes the derived time, so the render thread never does tempo lookups), sloppy numeric division values snap to the nearest musical division rather than pretending precision, and sync/division deliberately refuse automation lanes instead of shipping lanes that couldn't work. Agents get the full vocabulary through the existing params path — no new commands — with the exact formula and snapping rules taught in the effect's self-description. Proof in the suite: impulse echoes measured at exactly the predicted sample positions across two tempos, live and through a full offline bounce. Suites: Swift 3277/354, npm 207/207.

## 2026-07-20 — Dynamics stop mixing blind: gain-reduction metering everywhere it matters
- Every built-in compressor, limiter, and gate now shows how hard it's working, live: the wire snapshot carries a per-effect `gainReductionDb` (positive dB, instant attack with a 20 dB/s held-peak release — the same ballistics convention as the level meters), published real-time-safe from the render thread as a single atomic store. It's additive on the effect entries agents already read — zero new commands — and honest to the bone: non-dynamics effects and hosted AUs simply omit the key (never a fabricated 0), bypassing re-zeros it, and a fully closed gate reads the engine's exact 80 dB cap. The suite pins the math: 8.88 dB measured against 9 expected on a 4:1 overshoot fixture, release slope exactly 20.0 dB/s.
- In the app, dynamics editor cards grow a GAIN REDUCTION ladder — 24 glowing segments on a saturating scale that gives the musical 1–6 dB region most of the travel (ticks at 0/3/6/12/24; deeper readings pin the bar while the number stays honest), zone-colored green/amber/red on compressors and limiters ("you're crushing it" is a teaching signal) but uniformly green on a gate, whose deep attenuation is its job — a closed gate says CLOSED in plain language, never an alarming "80.0". Insert chips get a five-cell mini activity bar so you can see which insert is working without opening anything. En route, pixel review caught the new meters freezing solid whenever the app wasn't the focused application (a DAW's meters must keep moving while you work elsewhere — and an AI-driven app must stay observable); the polls now use the loudness readout's proven always-ticking pattern, re-proven live in captures: a card reading 35.7 dB mid-playback with the ladder pinned. Suites: Swift 3258/352, npm 207/207; wire and MCP surface counts unchanged.

## 2026-07-20 — The mix gets eyes for stereo: correlation, width, and a real goniometer
- The master analyzer is stereo-aware at last: `mixer.masterAnalysis` now reports L/R correlation (−1…+1 with broadcast-meter 300 ms ballistics), stereo width, and left/right balance — honestly floored (+1/0/0) in silence, with a deliberate convention that a hard-panned mix reads "in phase" because mono-summing it cancels nothing, which is the question the meter answers. AI agents get taught the red flags in the MCP tool description, so "will this collapse to mono?" is now a measurable copilot question. The existing spectral analysis is byte-untouched.
- On the master strip, a STEREO IMAGE block joins the loudness readout: a glowing goniometer (mono = vertical line, anti-phase = horizontal, hard-left rides the L diagonal like the hardware scopes do), a plain-language verdict — IN PHASE / VERY WIDE / OUT OF PHASE — with one semantic color across trail, word, and bar, plus width/balance numerics in Pro. Simple mode keeps the beginner-relevant verdict and drops the pro instrument. Deterministic debug seeding makes every figure capturable headlessly. Verified end-to-end: suites 3240/350 Swift + 206/206 npm, an 11-check wire gate through real panned playback, a 15-check capture gate, and pixel-reviewed figures for mono, anti-phase, hard-pan, window-floor Simple, and live audio.

## 2026-07-20 — The master bus gets a real loudness meter, live
- The DAW now measures loudness the way broadcast and streaming platforms do, *while you play*: the master strip carries a live BS.1770 meter — momentary and short-term LUFS, the running gated integrated value, loudness range (LRA, new to the app and also added to offline measurement), and 4×-oversampled true peak, with DC-offset and crest-factor riders for diagnosis. It behaves like a hardware meter left running: stopping the transport never erases the running program, only an explicit reset starts a new measurement, and values honestly disappear (dashes, not zeros) until enough audio has been analyzed to mean anything — including a floor that keeps a fading synth tail's floating-point dust from ever masquerading as a reading.
- Trust is the feature: the streaming engine reuses the exact same math as the offline `render.measureLoudness` truth, and the suite holds live-vs-offline identical to within a billionth of a dB (true peak bit-exact) on the same program. AI agents get the same eyes — a new `mixer.liveLoudness` wire command and `mixer_live_loudness` MCP tool (granted to the plugin's mix engineer; the finisher deliberately keeps verifying its work against offline renders). Verified end-to-end on a live app: a real playback round converged with the offline measurement of the same project, stop/start accumulation and reset semantics held over the wire, and the on-strip readout tracked the wire values in a reviewed capture. En route, a test-build-only performance collapse that could wedge the full test suite was root-caused and fixed (hot loops rewritten; the whole suite runs in ~65 s again). Suites: Swift 3213/348, npm 202/202.

## 2026-07-20 — The EQ gets its face: the interactive frequency-curve editor
- The EQ is now shaped the way Logic and Pro-Q users expect: a log-frequency plot with a glowing composite curve, six draggable band handles (drag for frequency and gain, ⌥-drag or scroll for width, ⇧ for fine moves, double-click to switch a band off), a band strip with ON toggles and 12/24 slope chips, and — on the master strip — the live spectrum breathing behind the curve at its true band positions. The Simple density is the curve; Pro flips back to the full knob table. Track EQs honestly draw no spectrum yet (the per-insert analysis tap is a filed follow-up rather than a render-thread cost smuggled in).
- The curve provably cannot lie: the biquad coefficient math was extracted into one shared DAWCore unit consumed by both the audio engine and the drawn curve, the pre-existing bit-exactness pin still fingerprints the DSP identical to the pre-change engine, and a new test renders sines through the real EQ and holds the drawn curve to within four millionths of a dB of what the DSP actually does. Verified live over the wire: probe points matched textbook filter identities (−3.01 dB at a high-pass corner, exact gain at a peak's center), and undo steps stay per-parameter. No new wire/MCP surface — the editor is a new face on the already-agent-controllable EQ. Suites: Swift 3186/344, npm 196/196.
- Drop a finished song into the timeline and the AI can now *measure* it instead of guessing: the new `clip.analyzeAudio` command (and `clip_analyze_audio` MCP tool) reads an audio clip's musical key (with ranked alternatives and an honest `tonal: false` for percussion-only material), its tempo (nullable when no steady pulse exists, with a `steady` flag and half/double-time alternates, plus the offset of the first beat), and its spectral balance (24 analysis bands, six plain-language macro bands like "bass" and "air", and a brightness centroid). Confidence fields everywhere are margin-gated and deliberately never fake certainty — a null BPM is an answer, not a failure. Stretched or pitched clips also report a derived `playback` block for what the clip sounds like *now*, and results are cached so repeat calls are instant.
- The in-app copilot and the music-team plugin's composer and arranger were all taught that analysis is the first move on imported audio — proven live: asked about an imported song, the copilot called the analysis tool unprompted and reported the measured key and BPM (A minor, 120, steady) instead of guessing. Accuracy was pinned against fixtures before shipping: 7/7 known-key pieces exact, click-track tempo within ±0.05 BPM, a 60 BPM pulse honestly folded to 120 with 60 offered as the alternate, and pink noise correctly reporting "no tempo". Analyzing five minutes of audio takes ~1.2 s. With this, the instrument-control-depth milestone (M21) closes. Suites: Swift 3150/341, npm 196/196.
- The built-in EQ gains the most-used tools in mixing that it simply didn't have: high-pass and low-pass filters with selectable 12 or 24 dB/oct slopes, adjustable Q on both shelves, and a true per-band on/off switch (bypassing a band is mathematically identical to the band not existing — not a gain trick). The editor grew matching controls: filter knobs, 12/24 slope chips, and band ON toggles, and `fx.describe` now teaches AI agents the new parameters' exact semantics, including that a filter with no corner set is off.
- Compatibility is engineered, not hoped for: every new field is optional, old projects decode to byte-identical settings, and a regression test pins the new DSP against an exact replica of the old math — verified bit-equal against the actual pre-change build before the change shipped. Measured proof in the suite: a 100 Hz high-pass attenuates 50 Hz by 12.3/24.1 dB on its two slopes, corners sit at −3.01 dB, and a fully-bypassed EQ nulls to literal zero. Suites: Swift 3111/338, npm 191/191. Next up on this surface: the interactive frequency-curve editor.
- The arrange grid learned finer trim divisions (1/8- and 1/16-beat, matching the engine's real precision) — and more usefully, clips can now snap themselves to their material: "Fit to Content" (right-click a clip, or the new `clip.fitToContent` command/tool for AI agents) trims a MIDI clip to exactly its last note's end and an audio clip to its remaining source length, tempo- and stretch-aware. It's honest about edge cases: a clip that already fits reports `changed: false` and writes no undo entry, an empty clip is a safe no-op, and a note hanging past the clip edge pulls the clip *out* to cover it — fit means "match the content," not "shrink". Simple mode keeps its beginner-safe Bar snapping untouched.
- The whole convention shipped in one stroke: store operation with undo, wire command, MCP tool, copilot catalog entry, context-menu affordance, and the distributable music-team plugin's arranger now carries the tool. Verified live over the wire: an 8-beat clip with notes ending at beat 2.37 fit to exactly 2.37. Suites: Swift 3096/336, npm 191/191.

## 2026-07-20 — The tour gets its art — and the glass-cockpit pass closes
- The guided tour's welcome and done cards now open with real artwork: a dark console under a hovering cyan waveform greets first-run users, and a glass turntable whose groove is a glowing waveform ring closes the loop when their first song is saved. Both images are GPT-generated in the house design language, shipped as neatly inset media wells (the five task coach-marks deliberately stay art-free — art belongs where the app frames a moment, not where it teaches a control). A deliberate engineering choice underneath: the images load through a resilient custom loader that works identically in dev runs and the signed app bundle, and degrades to a text-only card rather than ever crashing over a missing file.
- This closes the full glass-cockpit pass — compliance audit, app icon, asset scoping (verdict: the app needs almost no generated art, which is the design language doing its job), and these two heroes — and with it, the entire Design & simplicity milestone (M8).

## 2026-07-20 — Third-party plugins open up: the AU parameter surface
- Until today, a hosted plugin was a black box to the AI — it could load Dexed or Surge onto a track but couldn't read or turn a single knob, and it would honestly tell you so. Now two new wire commands ask any hosted Audio Unit for its full parameter tree (`au.describeParams` — every parameter's name, unit, range, and current value, paged honestly for synths that expose thousands) and set any parameter by address (`au.setParam` — out-of-range values clamp, and the response echoes the value the plugin actually accepted, since some quantize what you send). Plugins that keep their state opaque (Kontakt-style) get an honest "publishes no parameter tree" answer pointing you at the plugin's own window, never a fake error. Matching MCP tools ship to AI agents, and the distributable music-team plugin's sound-designer and mix-engineer both carry them.
- Proven against real plugins, not mocks: Apple's AUDelay enumerated its true 4-parameter tree over the wire, a delay-time set moved the actual echo in a rendered impulse (the test listens, not just reads), and DLSMusicDevice proved the instrument flavor. Suites: Swift 3066/333, npm 188/188, all green. The in-app copilot was taught the surface the same day (catalog 56 → 58) and proved it in a live turn: asked to read an AUDelay's delay time and set it to half a second, it called both new commands and the plugin's own read-back confirmed 0.5 s — the "no access to plugin values" era is over for the built-in copilot too.

## 2026-07-20 — The note editor grows up: zoom, finer grids, and honest limits
- The piano roll finally zooms: pinch on the grid, ⌘+/⌘−/⌘0, or the new magnifier cluster in the editor header (4–200 pt per beat, remembered per app like the arrange timeline's zoom, which it deliberately mirrors). Grid divisions now go past 1/16 — 1/32, 1/64, and triplet feels (1/8T, 1/16T) — with sub-beat grid lines that fade in as you zoom so a fine grid never turns into visual soup at normal zoom, and quantize learned the same divisions.
- Two honesty fixes: a note can now be dragged as short as one grid step (previously the editor refused to go below the snap's default note length even though the engine happily stores far shorter — AI-written ornaments were viewable but not editable), and the delete-bar button no longer plays dead — when a part is only one bar long, pressing it explains why it's disabled in a small amber notice instead of silently ignoring you. Verified live: a 1/64-note edit accepted over the staging wire, a bar deleted from an 8-beat part, and a pixel capture of the roll at 500% showing 1/64 notes as real, editable dots. Suites: Swift 3078/334.

## 2026-07-20 — The Poly Synth gets a face: a real editor panel for the built-in instrument
- The built-in Poly Synth's sound has always been tunable — but only by the AI over the wire, which is exactly backwards for an instrument you play. Now the instrument picker grows a TUNE button (visible whenever Poly Synth is the track's current instrument) that opens a dedicated dark-glass editor card: OSC (a segmented wave picker — saw, square, triangle, sine), ENVELOPE (attack/decay/sustain/release knobs), FILTER (log-taper cutoff and resonance), OUTPUT (gain reading in dB). The same knobs the insert editors use — option-drag for fine control, double-click to reset — with honest readouts that cross ms→s and Hz→kHz where your eyes expect it.
- The panel and the AI edit the same instrument and see each other live: turn a knob and the wire's next read reflects it; let the copilot set the cutoff mid-session and the open card's knob moves. A knob drag coalesces into a single undo step. No new wire commands or MCP tools — the UI converged on the surface that already existed (`track.setInstrument`). Proven by a 14-check live gate on a staging app plus a pixel capture of the rendered card; suites grew to Swift 3042/331, still zero warnings.

## 2026-07-19 — Conversations that survive: copilot chats now live inside the project file
- Chats persist. Every copilot conversation is now stored inside the project file itself — save the project, quit, reopen it next week, and your chats are there: listable, renameable, resumable, continuable. The rail gained a quiet history view (CHATS) showing every archived conversation with its title and age; the reset button now honestly means "new chat" (it archives, never destroys); resuming is always an explicit act — reopening a project never silently reconnects a conversation to the API. A four-agent build from a settled architecture design (docs/research/design-copilot-chat-persistence.md): domain persistence, engine lifecycle, four new wire commands (ai.copilotChats/ResumeChat/DeleteChat/RenameChat, wire 135→139) with four matching MCP tools (138→142), and the rail UI.
- The honesty engineering is the story. Old project files open unchanged, and one corrupt chat can never fail a project open (per-element lossy decode). Chats ride autosave and crash recovery without ever touching the undo stack, and Cmd-Q now runs a real autosave. Caps keep project files sane — 20 chats, 400 entries / 256 KiB per chat — and when trimming happens the transcript says so in a banner instead of pretending nothing was lost; a single over-long turn is preserved whole rather than half-shown. Thinking blocks are stripped from stored provider history (they're only load-bearing mid-tool-loop, and stripping makes resume safe across model switches) while the readable summaries stay in the visible transcript. Feedback bundles exclude chats entirely — your conversations are yours. The design pass also caught and fixed two latent bugs: a reset() racing an in-flight turn could pollute fresh state through the error paths, and an all-thinking reply used to leave an empty assistant message in history that would have 400'd the next send.
- Proven end-to-end, not just unit-tested: a staging app held a real conversation (it built an ambient pad track named Nebula), saved the project, was killed outright and relaunched; the reopened project listed the chat, resumed it with the full transcript, and when asked — with tools forbidden — "what was the track called?", the model answered "Nebula" from the restored history. 17/17 gate checks. Suites: Swift 3021/330, npm 177/177.

## 2026-07-19 — Thirty rounds, a copy button, knobs where knobs belong — and an icon
- DAW Pro finally has a face: a GPT-Image-generated app icon in the house design language — near-black glass squircle, a neon waveform sweeping violet to cyan, one amber fader — with true alpha transparency (verified at the pixel level, not eyeballed). The committed `AppIcon.icns` carries every size from 16 px to 1024 px, `bundle.sh` seals it into the signed bundle, and `dist/DAWPro.app` now looks like an app instead of a generic terminal binary. This is the first fruit of the newly unblocked GPT-Image pipeline; the broader generated-asset scoping (onboarding art, empty states) remains open by design.
- The copilot's per-turn tool budget default rose from 8 to 30 rounds (the 1–32 policy range and the Settings override are unchanged, and the Settings placeholder now derives from the constant so it can never silently drift). Real compositions routinely batch instruments, clips, effects, and mix moves across many rounds — 8 was cutting legitimate work short with the honest-but-annoying "tool-round limit reached" message.
- AI output is now copyable: hover any assistant message (or an expanded reasoning strip) for a quiet copy glyph — cyan on hover, a green checkmark for a moment once copied — and the rail header gained a copy-whole-reply action that joins the latest reply's prose with blank lines, never tool traffic or collapsed thinking. The clipboard is touched through one seam, tests use a fake, and a whitespace-only copy refuses to blank your clipboard.
- The insert-effect editor was rebuilt as a vertical channel strip with real rotary knobs, guided by a same-day research pass over Logic, Ableton, FabFilter, UAD, and hardware-lineage conventions (docs/research/2026-07-19-knob-vs-slider-insert-controls.md): grouped sections per effect (compressor TRIGGER / TIME / OUTPUT; four EQ band groups; output and mix always last), label-above-knob columns, bipolar center-out arcs for EQ gains and saturator output, log frequency sweeps, mix amounts reading as percentages, gain reading in dB-equivalent, delay times crossing over to seconds — and delay's Ping Pong, secretly binary all along, is finally a real toggle. Threshold and ceiling stay knobs for now by explicit decision: the slider-beside-a-meter treatment waits for per-effect gain-reduction metering. The m17-a insert-editor gate still passes untouched, 22/22. Suites: Swift 2928/327, npm 165/165.

## 2026-07-19 — The copilot thinks out loud, streams live, and lets you pick its brain
- Four user-requested upgrades landed in one wave. The copilot no longer caps its own output: each turn requests the model's full maximum (128K tokens on Claude Sonnet 5) and rides Server-Sent-Events streaming, so long reasoning, long answers, and big tool batches can never be truncated by our own budget or killed by a fixed request timeout. The model's reasoning is now visible: requests opt into summarized thinking, and the transcript shows quiet, collapsed "REASONED" strips — expandable to the full summary, with a breathing violet dot and a live tail-preview while the model is actively thinking. And the model itself is now yours to choose: a MODEL chip in the copilot rail opens a curated picker (Sonnet 5 default, Opus 4.7/4.8, Sonnet 4.6, Fable 5, Haiku 4.5), persisted across launches, applied from the next message — with matching `ai.copilotGetModel`/`ai.copilotSetModel` wire commands and MCP tools, so agents get the same control (wire 133→135, MCP tools 136→138). One catalog drives everything — per-model token ceilings, thinking configs, and the picker — so they can never drift apart.
- Live verification earned its keep twice. A first staging-app gate proved the wire: model round-trips, teaching errors for unknown ids, real summarized reasoning arriving in transcript entries. But polling at 100ms during a streamed 2000-character answer caught ZERO in-progress entries — streaming was secretly buffered: the whole network response was collected before events fired, making "live" a burst of microseconds. The fix made the SSE assembler a true incremental consumer, with a regression test that proves the first delta's event fires before the rest of the stream even arrives. The re-run: 118 mid-stream observations of the growing answer and the model's thinking, clean finalization, nothing left dangling. Suites: Swift 2915/327, npm 165/165.
- The DAW also became a place other Claudes can work: a distributable Claude Code plugin (`claude-plugin/`, installable via marketplace or `--plugin-dir`) ships a six-agent music team — producer, composer, arranger, sound-designer, mix-engineer, finisher — each least-privilege-scoped over the 136 MCP tools (a verified disjoint partition), plus workflow skills (`/new-song`, `/arrange`, `/mix-check`, `/bounce`, `/daw-status`) and a shared wire-lore reference. The MCP server is bundled into the plugin as a single 1.7 MB self-contained file (ESM, `import.meta.url` intact), smoke-tested over a real MCP handshake serving all 136 tools — no build step for end users, no sibling-directory dependency, both strict validators green.

## 2026-07-19 — The copilot finds its voice back (user-reported "(no response)" fixed)
- The in-app copilot had gone silent: every ask ended with a bare "(no response)" and nothing else. The cause was three defects stacked so neatly that each hid the next. Claude Sonnet 5 runs adaptive thinking by default when a request doesn't say otherwise — and thinking spends the same `max_tokens` budget as the visible answer. At the old 4096-token budget, a complex ask could burn the whole allowance on internal reasoning; the provider then threw those thinking blocks away as noise, the engine saw an "empty" reply, and printed "(no response)" while discarding the one clue that told the truth (`stop_reason: max_tokens`). The fix: the turn budget rises to 16000 tokens, thinking blocks are preserved verbatim and echoed back on later rounds exactly as the API requires (which also fixes a latent bug that would have broken multi-round tool turns), and a reply with no visible output now produces an honest, actionable failure naming its stop reason — the string "(no response)" no longer exists in the codebase.
- Fixing the silence uncovered a fourth defect the old truncation had been masking: with a real 16000-token budget, a genuine generation outlives the HTTP layer's default 60-second timeout. Copilot turns now ride a 600-second request timeout (all other AI clients untouched), with the constant pinned by tests so it can't silently drift back. Verified the honest way — a staging app on the staging port replayed the user's exact failing prompt against the live Anthropic API: eight minutes, 43 successful tool calls, a full EDM arrangement with tracks, instruments, MIDI, markers, a mix chain, and a −17 LUFS loudness report at the end. Suites: Swift 2867/323, npm 159/159, all green. (+11 tests over baseline.)

## 2026-07-19 — The Voice panel arrives, honest to a fault
- Voice conversion now has a home in the app: a right-docked Voice panel (VOICE chip in the top bar) where you create named voices, build their training datasets — import audio files, or record on a track as usual and add the clip as a sample — and see the conversion engine's real state with a one-press Start. Audio clips gained "Convert to Voice…": pick a voice, optionally shift pitch, and the converted take lands as a violet AI track aligned under its source, one undo away. A matching `vc_list_voices` agent tool ships too, so everything the panel shows is equally visible to AI agents.
- What makes this release notable is what it refuses to fake. The only voice available today is plainly badged "PIPELINE TEST — proves the pipeline works, not a real voice conversion," and the result card repeats that in amber after every convert. Pressing Train sends a real request and shows the engine's own answer — "real training arrives with a coming update," with your validated request echoed back — instead of a progress bar to nowhere. The rights policy is written into the panel itself: train and convert only with your own voice, never a celebrity's, never anyone's without permission. Real voices arrive with the training update, which needs the one thing that can't be automated: the user's own recordings.

## 2026-07-19 — An agent can now convert a vocal and land it in the project, one command each
- The voice-conversion pipeline is drivable end-to-end: `vc.convertVocals` takes a vocal (either a clip already in the project or an audio file on disk), runs it through the local conversion engine, and lands the result as a new violet AI-flagged track in the arrangement — one command, one undoable edit, and redo brings it back exactly where it was. Point it at a clip and the converted take lands at that clip's own position automatically. The command blocks until done rather than pretending to be a background job — conversion runs at ~37× real time, so even long stems finish in seconds, and every timeout budget along the chain (app-side, agent-side) was sized so a legitimately long conversion is never cut off mid-run.
- Honesty is enforced at every layer: converting through the placeholder "base" voice plainly reports it isn't a real voice conversion yet; a wrong pitch value or an attempt to train over the reserved name surfaces the engine's own teaching error word-for-word; calling convert with the sidecar stopped tells you exactly which command starts it instead of a bare "connection refused"; and `vc.trainVoice` ships fully wired but honestly answers "training arrives with the Voice panel" until the real training path lands. Independent review attacked eight corner cases the build's own tests didn't cover (MIDI clips, conflicting inputs, redo, cross-sidecar isolation) — all held. One latent test bug from the previous item was also caught and fixed: the command-sweep test had been silently booting the real sidecar on every full test run, and would have failed the suite on a fresh checkout.

## 2026-07-17 — The app learns to drive its second sidecar
- The voice-conversion service installed yesterday can now be driven from inside the app — and by AI agents — through three new control commands: check the sidecar's status, start it, stop it. The status answer never shrugs: it always tells you the precise next step ("run the installer" vs. "call start"), reports which engine is loaded and how many trained voices exist (honestly zero until training ships), and if a boot is slow it says "starting, N seconds so far" truthfully instead of pretending success — the same honesty discipline the music-generation sidecar learned the hard way, applied here from day one. The existing generation-sidecar commands are byte-untouched: this is a second, independent service, and a deliberate test proved the two report their own states without cross-talk even when one is running and the other isn't.
- Under the hood the app gained a typed client speaking the service's full contract (list voices, voice status, convert, train — the last two get their commands next), and the whole surface landed with the house convention intact: every command has a matching AI-agent tool (each carrying the own-voice-only policy in its description) and tests at every layer — 43 new app-side tests plus 9 agent-side, with live verification twice over: the builder's end-to-end run caught the sidecar mid-boot on the wire, and an independent review pass attacked the corners (stopping an already-stopped sidecar, starting twice, feeding junk parameters) and found them all handled. Start-to-healthy measures about half a second.

## 2026-07-17 — The voice-conversion engine gets a permanent home
- Hours after the feasibility verdict came back GO, the engine moved from a throwaway test directory into the repo for real: an installer that sets up the whole stack — pinned engine version, isolated Python environment, the four model files (reused from cache with checksums verified), the security-mandated weight-format conversion, and the GPU-format model conversions — in 57 seconds flat, and knows to do nothing in 0.04 seconds when everything's already in place. A launcher starts the conversion service on a local-only port (loopback is hardcoded, not configurable — the service is unreachable from the network by construction), with the same lifecycle conventions as the existing music-generation sidecar.
- The service speaks a small, stable four-endpoint contract designed so the rest of the app never needs to know which engine sits behind it: list voices, check a voice's status, convert audio, train a voice. Conversion is real today (proven end-to-end twice — once in the build, once in independent review with a different input file, at 37× real time warm); the voice list is honestly empty (no bundled voices, no celebrity models — ever); and training answers with a polite "reserved: this arrives with the Voice panel," validating your request fully so the same call will just work when it does. Next: the app-side client and control-surface commands that let agents drive it.

## 2026-07-17 — Voice conversion goes from "blocked" to "GO" in one afternoon
- Six days ago the voice-conversion feasibility spike hit a wall: the corporate network hard-blocked every neural model download, leaving the engine verdict incomplete. Today a routine re-probe found the wall gone — and within the hour, all four required model files (~775 MB) were downloaded, checksummed, and cached durably. The missing measurements followed on this machine: the full conversion pipeline runs at 38× real time end-to-end, pitch extraction at 95×, content encoding at 574×, and — the number that matters most for the "train your own voice" promise — a real training step runs natively on Apple's GPU at 3.2 steps per second with zero CPU fallbacks. Verdict, written into the spike report: GO.
- The guardrails held throughout: no celebrity voice models were downloaded or touched (the pipeline was proven against a neutral untrained target — real voices arrive only when a user trains their own), the test vocal was synthesized from scratch rather than borrowed, and the one unresolved item is properly legal, not technical: the conversion engine's repository still ships no license file, which stays a shipping gate. One fresh discovery was banked for the install step: newer security rules in the ML toolchain refuse the old model format, so the installer will convert weights to the safe format up front. Next up: the install scripts and the local sidecar service that will host voice conversion for the app.

## 2026-07-17 — The test that could never pass, fixed by the numbers
- The generation-card test gate had two dormant bugs in its own checks — caught and filed two cycles ago when a header cleanup exposed them: one leg called a command that doesn't exist (a naming slip: `app.captureUI` for the real `debug.captureUI`), and one compared a number against the clock text "0:33", a comparison that can never be true. Both are fixed — the elapsed check now parses the clock string properly (the card deliberately reports elapsed time as display text, and that stays; the test adapts to reality rather than the other way around) — and the gate's header honestly records that these were always test bugs, never app bugs.
- The gate now passes all twelve checks from a cold start, twice over: once in the fixing session and once in an independent re-run, both against a real staged app, including the leg that boots a real local AI sidecar and watches the interface narrate the startup. With this, the current milestone's runnable work is complete — the remaining three items all wait on one hardware decision (installing a loopback audio device) that only a human can make.

## 2026-07-17 — The last measured freeze is gone, and it cost nothing
- Two cycles ago, measurement convicted the gain-adjustment step of loudness-targeted bounces: over a second of frozen main thread on a 2.7-minute song. Today it moved off the main thread — fused with the loudness re-measure that follows it, so the whole adjustment is one background unit instead of two round-trips. The subtle trap was memory: done naively, handing a render buffer to a background task duplicates it (hundreds of megabytes for long programs) at the moment of the first change. The implementation threads the buffer's single ownership through the hop instead — no copy, and a test pins that the audio data literally never moves in memory, byte-addresses compared.
- Proof, before and after, on the same 2.7-minute program: the app's responsiveness probe caught the old code freezing for 1.07 seconds mid-bounce; the new code's worst hiccup is 9 milliseconds, with the bounce itself no slower. The independent review then ran its own gate with a different recipe: two consecutive normalized bounces came back byte-for-byte identical (the change is deterministic end-to-end), the output landed at exactly the requested loudness, and 208 responsiveness probes never waited more than 14 milliseconds. The suite stands at 2,743 tests across 307 suites, zero warnings. With this, every heavyweight stage of a bounce runs off the main thread — the one remaining on-thread step measures ~20 milliseconds, and it stays by the numbers.

## 2026-07-17 — Sampled instruments stop running out of breath: sustain loops are real
- Until today, importing a sample library whose sounds are built to loop (nearly every sustained instrument — strings, pads, organs, brass) played each note only as long as its raw recording, then went silent; the import report could only apologize. Now loops play for real: the loop points authored in SFZ and DecentSampler files are honored, and when a library's text says nothing, the loop embedded inside the WAV file itself (the standard `smpl` chunk that most sampled instruments carry) is found and used automatically. Held notes sustain indefinitely, the sustain pedal behaves like a real instrument's — loops keep sounding under the pedal and release naturally when it lifts — and the loop seam is crossfaded at render time so it's mathematically quieter than the sine wave's own natural motion: measurably invisible. The import report's apology is gone, replaced by an honest `loopedZones` count, and every edge case (backwards loop points, loop points without a mode, unrecognized modes) degrades with a plain-language explanation instead of silence.
- Proven at every layer, twice over: the implementing agent's render gates show a 1.5-second recording sustaining at full level through a 10-second hold with pitch exact to the cycle count and release decaying to digital zero; the independent review then booted a real app instance and imported a library over the live control connection where one instrument looped by authored opcodes and another only by its embedded WAV chunk — both looped, six times past their natural end, with the report confirming both. The suite grew to 2,741 tests across 307 suites, zero warnings, with old projects' playback pinned byte-identical — a non-looping instrument renders exactly the bytes it rendered yesterday.

## 2026-07-17 — Measurement finds the next freeze before any user does
- The follow-up measurements promised after the render-freeze fix are in, and they split cleanly: writing rendered audio to disk is innocent (never more than 21 milliseconds across 21 measurements at all four write sites), but the gain-adjustment step that runs when a bounce targets a loudness level is guilty — over 1.1 seconds of frozen main thread on a 2.7-minute song, ten times the action threshold. It's now a filed, numbers-backed work item riding the same proven off-thread pattern as the loudness fix. Also swept in: the generation-card test gate got its header cleaned up and, in the process, two dormant bugs in the gate's own checks were caught and filed (one calls a command that doesn't exist, one compares a number against the text "0:33"); and the measurement probe that settled last cycle's timing-alignment question was preserved permanently in the repo with its five confirming run logs, rather than dying with the development session.
- One process incident, fully disclosed and fully recovered: a careless revert command briefly wiped an earlier uncommitted fix along with the measurement scaffolding it was meant to remove. The agent caught it immediately, reconstructed both files exactly (verified against the independently-recorded reference from that fix's own review, byte for byte), and the full suite passed twice after recovery — 2,716 tests across 305 suites, unchanged. The lesson is now a standing rule for every future work session in this repo.

## 2026-07-16 — The engine's sample rate becomes a decision, not a discovery
- First construction step of the approved device-rate redesign: the audio graph's processing rate is now handed in when the graph is built, instead of being re-asked from the output device at every use. Today it's set to the same value as before (the device's rate at build time), so nothing behaves differently — but the door this closes is real: a device changing its rate mid-session can no longer half-update the engine's internal processing chains while audio still flows at the old rate, a latent inconsistency the design review uncovered. From here, switching the whole graph to a fixed project rate (the step that ends Bluetooth-induced plugin storms) is a one-line change gated on a hardware measurement probe.
- "Nothing behaves differently" was proven three ways: the full suite (now 2,716 tests across 305 suites, including two new tests pinning that an injected rate genuinely shapes the graph) passed with every existing test untouched; a live staged session rendered a half-amplitude sine at exactly the true-peak physics predicts; and a deterministic 20-second mixdown rendered over the control connection came back byte-for-byte identical — same SHA-256 — before and after the change. The measurement probe itself waits on one thing: a loopback audio device, which needs a user's go-ahead to install.

## 2026-07-16 — The last known post-render freeze is dead
- Yesterday's design review approved it; today it shipped: loudness measurement after a render now runs off the main thread. The proof came out more dramatic than expected — on a 2.4-minute program, the pre-fix control run didn't just feel slow, it tripped the app's own wedge detector mid-operation ("main actor unresponsive for 9.5 seconds") and had the bounce command rejected outright; post-fix, nearly two thousand liveness probes through the same operations measured 34 milliseconds typical, under a second worst-case, zero rejections. An independent second gate exercised the three remaining render paths (stem export, mixdown, bounce-in-place) with the same result: median one millisecond, worst 14.
- The measurement itself is provably unchanged — a new test pins the off-thread result exactly equal (not approximately equal) to the synchronous one on a varied multi-segment program, and the full suite grew to 2,714 tests across 304 suites, all green. One honest leftover, already filed: the file-write and gain-apply steps still run on the main thread with much smaller cost; they get measured next, and moved only if the numbers say so.

## 2026-07-16 — Settled by design review: the audio engine will stop chasing your headphones
- Milestone 19 closes with its architecture question answered. Today, the whole live audio graph runs at whatever rate the current output device reports — so a Bluetooth headset dropping into call mode drags every effect, instrument, and timing calculation down to 24 kHz, forcing a storm of plugin re-preparations on every device change. The design review's verdict: the graph should run at the project's own rate, always, with a single conversion at the very edge where audio meets the device — and it turns out Apple's own SDK documents exactly this configuration (the review quotes the header text; both quotes were independently re-verified). Every downstream benefit follows by construction: effect timing and latency compensation become identical on every device, live playback finally matches exported files bit-for-bit in configuration, and device swaps stop triggering plugin re-preparation entirely.
- The review also found something worse than the filed complaint: today's device-change recovery restarts the engine without reconnecting it, briefly leaving the processing chains prepared at the new rate while audio still flows at the old one — a latent inconsistency window nobody had noticed. Because this project has been burned three times by undocumented audio-framework behavior, nothing ships on documentation alone: a five-part live measurement probe (with pass thresholds fixed in advance and a designed fallback) gates the actual switch. The implementation lands as five separately-gated steps now seeded as the next milestone, alongside one immediately-approved fix: loudness measurement after renders moves off the main thread, closing the last known way a long song could briefly freeze the app after rendering. Design only — no code changed today.

## 2026-07-16 — Quick pulse-check on native Apple-silicon music generation: nothing new, sidecar stays
- The standing question "could the AI song generator run natively in Swift instead of the Python sidecar?" got its scheduled re-check: the Swift MLX audio ecosystem still ships no diffusion or music-generation model class (text-to-speech, transcription, and codecs only), so the local ACE-Step sidecar remains the right design. The only movement anywhere nearby — a new Python diffusion text-to-speech pipeline — is both the wrong model class and the wrong language to change that verdict. The watch condition stays armed in the research notes; no code touched.

## 2026-07-16 — The proving grounds get permanent: five verification gates graduate into the repo
- The strongest end-to-end checks from the last three milestones lived in a temporary session folder that dies when the development session ends. Five of them are now permanent tooling under `scripts/gates/`: the sketchpad honesty gate, the piano-roll undo/split reseed gate, the mid-play track-add scaling pair (the before-and-after proof that idle clips no longer tax track creation), and the out-of-clip ghost-note gate. Each was made self-contained — the scaling pair now generates its own test tone at runtime instead of depending on a file that no longer exists tomorrow — and each carries an honest header: what it proves, where it came from, and for the timing gates an explicit warning that their thresholds were calibrated on this machine and belong to a human runner, not CI. All five ran green from their new homes, twice over: once by the engineer who moved them, once independently.
- The sweep tool that captures the app at every window size had a subtle honesty bug of its own: opening an effect-editor card switches the app to Mix view by design, but closing it doesn't switch back — so every later capture labeled "arrange" silently photographed the mixer. Fixed and proven across the full 24-frame matrix, including after three open/close cycles. One filed complaint turned out to be stale — git history shows the alleged bogus header note never existed in that file — recorded as such rather than "fixed." Suite unchanged at 2,713 tests across 304 suites; no app code touched.

## 2026-07-16 — The piano roll stops lying about notes past the clip edge
- Notes hanging past the end of a MIDI clip used to draw at full neon brightness — indistinguishable from notes that would actually play. The engine's truth, pinned in code before a single pixel changed: a note whose start lands past the clip end never sounds at all, and a note that starts inside but runs long gets cut off exactly at the boundary. The editor now tells that truth. A pill that runs past the edge glows to the boundary and continues as a flat dim ghost; a pill wholly beyond it (including one starting exactly on the edge — the subtlest case) is entirely ghosted; velocity stems dim only when their note's onset genuinely never fires. A shaded region and hairline now mark the clip end across all three editor bands — note grid, velocity lane, and controller strips — as one continuous column, and ghost notes stay fully editable: drag one back inside the clip and it re-lights.
- Verified live over the control connection, both directions: extending a clip re-lights everything past the old boundary in place, trimming it shows only what survives (a wire trim actually clamps and drops out-of-range notes in the project — a distinction the editor now renders honestly, since only direct note edits can leave latent notes behind). An independent check staged a scenario the implementation never saw, injecting out-of-clip notes through a different command route and confirming every treatment at native resolution — including the boundary-exact ghost and the dimmed stems. Suite grows to 2,713 tests across 304 suites, zero warnings, crash logs untouched.

## 2026-07-16 — Adding tracks mid-song got dramatically cheaper — and a hidden timing bug died on the way
- Adding a track while a song plays used to cost time proportional to every clip on the timeline, playing or not: each player paid a ~6-millisecond start-up handshake even when it had nothing to play. Now players with nothing scheduled simply don't start. Measured end-to-end over the control connection: a mid-play track add with 40 clips elsewhere on the timeline dropped from 438 ms to 162 ms once the playhead was past them, and the per-clip cost collapsed from ~6.5 ms each to zero — adding a track in a large project now costs the same whether the timeline holds ten clips or forty. Active clips are untouched (the same experiment's active-clip numbers held exactly), and six new sample-exact tests pin the tricky cases, including a clip added mid-play onto a previously-idle track landing on the grid to the exact sample.
- The design review for this work surfaced something bigger: a live measurement probe proved (five runs, unambiguous) that macOS starts a late player at its actual start time rather than its requested one — so on resumes with more than ~10 active clips, the serial start loop overran its 60-millisecond anchor window and every later player played subtly behind the grid for the rest of the roll. This had been true at scale for months, inaudible to every loudness-based gate. The fix scales the start window with the number of players that will actually start (small sessions byte-identical, a 40-clip resume waits a uniform third of a second and comes back in perfect lockstep instead of immediately-but-smeared). The probe's verdict, the alignment law, and the start-skip rule are now recorded in the architecture's settled sequencer-clock contract. 2,708 tests across 304 suites, crash logs untouched.

## 2026-07-16 — The crash that almost shipped gets a permanent guard
- Last week's rarest bug — a once-per-day crash when instrument setup raced sound-bank operations — was fixed two days ago; today it got its insurance policy. A purpose-built stress test now packs roughly an order of magnitude more deliberately overlapping prepare/renegotiate/teardown collisions into a tenth of a second than a full day of real use would produce, all aimed at the exact serialization gates that fix installed. If anyone ever weakens those gates, the suite dies loudly instead of shipping a roulette wheel. The test also has to prove it did something: it counts every operation it raced and demands the exact expected totals, so it can never silently degrade into a test that passes by testing nothing.
- The same test permanently bounds how long instrument preparation may take under load (the systemic-slowdown detector: typical half-throttle preparation measures ~2 seconds mid-churn; the alarm is set at 8), and its stress load flushed out one brittle timing assumption elsewhere in the suite — a fixed 300-millisecond wait that's now a patient poll with identical pass criteria. Verified three ways: two clean full-suite runs from the implementer, an independent re-run, and a third run with the CPU deliberately half-starved by competing processes — all green, 2,702 tests across 303 suites, and the crash-log folder unchanged through every run.

## 2026-07-16 — The second library format lands: .dspreset imports on the same honest pipeline
- One day after .sfz, the Sampler now imports `.dspreset` sample libraries — the XML format behind hundreds of free community instruments (Pianobook and friends). The new parser reads the format's real-world shape, verified against the format author's own export tooling: instrument-wide defaults cascading through groups down to individual samples, fractional-semitone tuning, linear or dB volume, velocity layers, round-robins and random alternation, and UI chrome that's deliberately ignored but always counted in the import report — never silently dropped. Both formats now funnel into one shared representation and one shared policy engine, so the honesty rules (dry-run reports, reason-coded skips, loop and size warnings) are identical no matter which format a library arrives in — a parity test literally authors the same instrument in both formats and demands field-identical results.
- Verified beyond the 22 new tests: a hand-authored preset the implementation never saw — three levels of inheritance, sample paths with spaces, and an inverted velocity split compounded with inverse octave tuning — imported over the wire and rendered the quiet note at 878 Hz and the loud note at 438 Hz, exactly as authored; the same fixture pair rendered through the .sfz path produces bit-matching peak levels, parity visible in the audio itself. Suite grows to 2,701 tests / 302 suites; the AI-facing import tool's guidance now teaches both formats.

## 2026-07-16 — Real sample libraries walk in the door: the Sampler imports .sfz instruments
- The thousands of freely available sampled instruments in SFZ format — pianos, drum kits, orchestral libraries — can now be imported directly onto the built-in Sampler: from the Instrument Picker's new "Import Sample Library…" button, over the control connection, or by an AI agent through MCP. The importer handles how these files exist in the wild: multi-file libraries stitched together with includes and macros (the flagship Salamander piano's main file is nothing but scaffolding), sample paths with spaces, note names instead of numbers, Windows line endings and path separators, and five levels of inherited settings. What a library expresses lands on the zone features built in the last two milestones: velocity layers, round-robins, layered groups, per-zone tuning, pan, trims, and envelopes.
- The design's honesty rule is enforced end to end: nothing degrades silently. A dry-run mode returns the full import report — what imported, what was skipped and why (release-triggered samples, keyswitch articulations beyond the default), which opcodes were ignored, and how many gigabytes of samples the library references (with a warning at 500 MB and a refusal above 4 GB unless forced) — before anything touches the project; the real import is a single undoable edit. Malformed macro files refuse loudly with the exact file and variable named, because a half-expanded library imports as garbage. Verified independently beyond the 61 new tests: a hand-authored library the implementation never saw — spaces everywhere, chained macros, and a deliberately inverted velocity split — imported over the wire and rendered with the quiet note at 878 Hz and the loud note at 438 Hz, exactly the inversion as authored. Suite grows to 2,679 tests / 301 suites plus 129 MCP tests; `.dspreset` support comes next on the same foundation.

## 2026-07-16 — The app stays alive while it bounces: no more frozen UI during renders, on any audio device
- Chasing last cycle's "AirPods broke the tests" mystery uncovered something better than the suspected cause: bouncing a song froze the entire app for the render's duration — a full-length song meant ~25 seconds of dead UI and rejected commands, long enough that the app's own health monitor declared it wedged. The offline renderer now yields between chunks, capping any pause at about 85 milliseconds of audio. Proven live over the control connection: during a 39-second render, 282 status probes answered in 37 milliseconds typical, 58 worst-case, zero rejections — where before the fix that entire window was silence. The AirPods, it turned out, were innocent of this half: the freeze always existed; a long test render simply crossed the health monitor's threshold at the same time the headphones changed the sample rate.
- The headphones were guilty of the other half: tests had silently assumed a 48 kHz output device, and a Bluetooth headset in mic mode really runs the graph at 24 kHz. Those expectations are now computed from the device's actual rate (with a dedicated 24 kHz proof that the formula tracks rate, never a constant), so the suite is honest on any machine. And the new cooperative timing surfaced a third find with its own dividend: a rare, pre-existing crash race between instrument setup and sound-bank operations — already on file from a one-off crash log — became reliably reproducible, got fixed at both sites, and the crash corpus has been flat since. All 2,618 tests and the full MCP suite green; one architecture question filed: should the live engine follow a degraded Bluetooth rate at all, or run at project rate like the pros do.

## 2026-07-16 — Every zone gets its own voice: per-zone tuning, pan, sample trims, and a real ADSR envelope
- The Sampler's zones now carry the playback half of what real sample libraries express: per-zone tuning in cents, stereo placement with the standard constant-power pan law, a velocity-to-loudness depth control, per-zone one-shot (a kick that always rings out on a kit where everything else releases), sample start/end trims, and a full attack-decay-sustain-release envelope computed per voice — the same proven state machine the built-in synth uses. Zone gain's ceiling doubled to +6 dB so imported libraries that boost quiet samples arrive at level. As always, every field is optional and old projects play back bit-identically — one test literally replays the old playback law sample-for-sample against the new engine and demands equality.
- Two things surfaced beyond the feature itself. First, a save/reopen hole: none of the new-generation zone fields were being written into project files, so a velocity-layered kit built over the wire would silently lose its layers on reopen — found, fixed additively (old project files stay byte-identical), and pinned with its own persistence tests. Second, verification caught the test environment drifting underneath us: eight latency assertions and three integration tests began failing identically on completely clean code. The culprit turned out to be delightfully mundane — AirPods connected mid-session, macOS made them the default output at Bluetooth's 24 kHz, and the limiter's five-millisecond lookahead honestly reported half as many samples; the tests had silently assumed a 48 kHz device all along. Filed as the next priority item (including the real finding buried in it: the app's control surface stalls hard enough to trip its own watchdog when a Bluetooth headset is the default device) so the suite's green stays trustworthy on any machine. The feature itself proved out end-to-end over the wire: hard-left pan bounced to a file with the right channel at exact digital zero, +1200 cents doubled the rendered frequency (ratio 2.002), the sustain plateau landed 19 loudness units down, and the +6 dB gain lift measured 6.02. Suite grows to 2618 tests / 298 suites.

## 2026-07-16 — The built-in Sampler learns how real instruments are sampled: velocity layers, round-robins, and layered groups
- Sampled instruments sound alive because a soft piano hit and a hard one are different recordings, repeated drum hits alternate between takes, and layered mics fire together. The Sampler's zones can now express all of that: a velocity range per zone picks the right recording for how hard the note was played, round-robin and random gates rotate or shuffle between alternates, and zones in different groups layer while zones in the same group take turns. Every field is optional — existing projects decode untouched and play back bit-identically (the regression suite proves it byte-for-byte), and AI agents get the same power over the wire and through MCP, so an agent can hand-build a velocity-layered kit today, before any file import exists.
- The real-time contract held the line: alternation state lives with the render thread (allocated up front, never touched by the UI), a seeded generator makes renders reproducible in tests, and the voice pool grew from 16 to 64 so pedal-down velocity-layered playing doesn't starve. Verified twice over — the engine suite measures the rotation order, the random split, and the layering math sample-by-sample, and an end-to-end wire check with deliberately inverted zone gains proved the routing: the soft note rendered nine loudness units louder than the hard one, exactly as designed. Suite grows to 2602 tests / 295 suites.

## 2026-07-16 — The open piano roll now follows the truth when an AI edits the clip out from under it
- With the piano-roll editor open on a clip, a trim, split, or undo arriving from the arrangement or over the wire (the way AI agents edit) used to leave the entire editor frozen on the pre-edit picture — notes and controller points the project had already deleted kept drawing, and the readout quoted a deleted point's value until the clip was reselected. The editor's edit models now watch the incoming clip value and reseed themselves whenever it genuinely diverges: matters because a human watching the editor while an agent works must never be shown dead data.
- The refresh is surgical, not a sledgehammer: the editor's own edits round-trip through the store and arrive back looking like external changes, so the models compare canonical content first and refuse to reseed on their own echo — scroll position, note selection, and the chosen controller lane survive normal editing untouched. A reseed keeps the selection's survivors, cancels any in-flight drag cleanly, and recomputes the beyond-clip ghost boundary from the new length. Verified live across all three mutation paths (trim both directions, undo, split) with the editor open the whole time and zero reselects; suite grows to 2594 tests / 294 suites. M18, the hardening round, closes with this — all nine items verified.

## 2026-07-16 — SFZ and .dspreset import gets a verdict: GO, scoped honestly, ten days of work mapped
- The spike asking whether the built-in Sampler should read the two big free-sample-library formats came back a clear GO, built on real evidence: a census of five actual free libraries (fetched as raw text, opcode by opcode) showed the practical core is key ranges, velocity layers, round-robin/random alternation, tuning, and simple envelopes — while loops barely appear in acoustic content, and the famous Salamander piano can't even be read without SFZ's include/macro preprocessing layer (its main file contains zero note data). That preprocessing was promoted to must-have; loops moved to a later round, reported honestly on import rather than silently dropped.
- The design maps everything onto the existing zone model with additive-optional fields (old projects decode unchanged and play byte-identically), keeps the real-time contract intact (round-robin state lives with the render thread, allocated up front like the pitch-bend machinery), and rejects the tempting shortcuts by name: embedding a third-party SFZ engine (a C++ dependency inside the audio path that AI agents couldn't edit zone-by-zone) and import-and-flatten (which would quietly discard the velocity layers that make sampled instruments sound alive). Work is filed as four independently shippable roadmap items totaling ten to eleven days; both docs live in docs/research/ with every claim cited, spot-checked against the original sources.

## 2026-07-16 — Sketchpad candidate rows stop lying during model warm-up: one job, one story, everywhere
- While the AI generator was booting and loading its model, the generation card told the truth ("LOADING THE MODEL…") but the Sketchpad's candidate row — tracking the same job — still said QUEUED with an amber RECONNECTING badge, because its own status poll couldn't land yet. The row now resolves against the generation registry (the card's source of truth) at render time: during boot it shows the card's exact stage words, while running it carries the generator's rich progress text verbatim with matching percentages, and when the registry says the job died it fails the row on the spot with the same reason — a killed generator now reads as a red FAILED row with the actual error, not an eternal RECONNECTING. Terminal rows (done, imported, failed on their own) keep their richer local presentation untouched.
- Verified live on the real boot path twice over: once through the full happy lifecycle (boot → load → generate → done, row and card agreeing frame by frame on screen), and once through a deliberately induced production failure (generator process killed mid-job — both surfaces converged on the same FAILED story in the same second, verbatim reason included). Suite grows to 2584 tests / 293 suites.

## 2026-07-16 — Ultra-wide windows lose the dead glass: the piano roll now fills whatever screen you give it
- On very wide windows (up to the 3456-point ultra-wide stress case) the piano roll's note grid, velocity lane, and controller strip used to stop at their content width, leaving as much as 89% of the editor as an empty black void that read like broken rendering. All three bands now extend to the panel edge as shaded latent grid — one shared layout rule decides the width, and the honesty language survives intact: the lit grid is still exactly the playable window, the shade and the clip-end hairline mark everything beyond as latent. Creating a note out there is deliberately legal and behaves exactly like the controller-point rule shipped earlier today (silent until the clip is extended over it).
- The transport bar's left-anchored readout cluster at ultra-wide was judged and kept on purpose, with the rationale now written into the design language: readouts ride the buttons they describe, surplus width goes to the middle of the bar, and controls that drift with window size break muscle memory. Fixed chrome never re-flows for wide windows; workspace content claims the surplus. All alignment checks pixel-exact; suite grows to 2570 tests / 292 suites.

## 2026-07-16 — Controller points past the clip's end now tell the truth: ghosted, not glowing
- CC points beyond a clip's end are legal data that simply doesn't play (the engine schedules strictly inside the clip; extending the clip brings them to life). The controller strip used to render them at full neon past the note grid — bright, glowing, and lying about being audible. Now the lit trace ends exactly at a thin clip-end hairline and everything beyond renders as a ghost: the lane's own color, dimmed, no glow — visible, editable (drag a point across the boundary and its treatment flips live), but unmistakably inert. One engine-honest definition in the model decides the split, so the drawing can never drift from what actually plays. The rule and its rationale are recorded in the design language; a small correction landed with it (trimming a clip doesn't preserve out-of-window points — it drops them; the docs now say so).
- Verification went three lengths deep: the original seam state before/after, an extension re-lighting the ghosts, and a trim dropping them — and that last pair exposed a separate, pre-existing bug now filed on the roadmap: an open piano-roll editor doesn't refresh when the clip is trimmed from the arrangement or over the wire (notes, velocities, and controller data all render stale until the clip is reselected). Suite: 2568 tests / 292 suites.

## 2026-07-16 — A test-runner annoyance turns out to be a real crash bug in instrument loading — now fixed
- What was filed as "the test helper sometimes crashes at exit, polluting crash reports" was actually a live memory-corruption race in sound-bank loading: Apple's DLS/SF2 instrument engine keeps process-global unlocked state, so loading a bank while another sampler was being disposed (or while a second bank loaded) could fault — and the shipping app was exposed through everyday paths like setting instruments on two tracks in quick succession, or starting a bounce while a bank loaded. Two crash reports captured the exact two-thread interleave; a purpose-built stress test then reproduced it on demand (3 for 3).
- The fix serializes every dangerous touch of that engine — loads, teardowns, even the final release when an instrument's last owner lets go — on one dedicated queue, with a trap that turns any future violation into a clean failure instead of silent corruption. The stress test stays in the suite as a permanent regression gate. Proof: 5/5 stress runs and 3 consecutive full suites clean where the old code crashed roughly once per run, plus a live wire-level storm against the running app (24 concurrent instrument loads; project teardowns fired mid-load, six for six survived). Suite grows to 2564 tests / 292 suites; the audio render path is untouched.

## 2026-07-16 — The "slow track add" turns out to be the price of pressing play: a measurement clears the rebuild's name
- The filed defect said adding a track mid-playback got ~2.7× slower since spring (143 → ~390 ms at 41 tracks). Per-phase measurement proves the engine-rebuild core is unchanged (~140 ms today, same class as the m13 record) — the difference is the benchmarks: the old one had a single rolling audio clip, the new one has forty, and each rolling player costs ~6 ms to restart (a per-player render-cycle handshake inside Apple's framework, paid identically by a plain transport play of the same session). The honest budget is linear: ~140 ms plus ~6 ms per rolling clip. Confirmed by independent variation at fixed track count: 10 clips → 240 ms, 40 clips → 404 ms.
- No code changed — the deliverable is the cost model, now written into the architecture doc, plus two filed candidates for shrinking the per-player term (skipping players with nothing scheduled; batching the starts, which needs a design round first). Both m16 regression gates green, suite at 2563 tests / 291 suites.

## 2026-07-16 — The app can now report its own hang: a wedged UI answers honestly instead of going silent
- The engine watchdog has always covered a stalled engine; a frozen main thread was invisible — the app would keep accepting control connections and then silently hang every command, leaving an AI agent staring at a dead peer. Now a background monitor pings the main thread every second and declares a wedge after 2.5 s of silence, and the control server answers from outside the frozen tier: `engine.watchdogStatus` reports `mainActor: {responsive: false, wedgedForSeconds}` in about a millisecond, every other command fails fast with a plain-language explanation instead of hanging, and a breadcrumb log (`~/Library/Logs/DAWPro/main-actor-wedge.log`) records every wedge and recovery with durations — written off-main, because the wedged thread can't. Healthy responses gain `mainActor: {responsive: true}` beside the usual engine fields. No auto-restart by design: detection and honesty only.
- Verified hard: during a staged freeze a brand-new control connection established in 5 ms and immediately learned the app was wedged; the audio engine played straight through a 10-second wedge (the playhead advanced ~25 beats — the render thread never depended on the UI); back-to-back wedges detect and recover cleanly with per-wedge durations. Zero new wire commands — the honesty rides the existing watchdog verb. Suite: 2563 tests / 291 suites.

## 2026-07-16 — The 985-megabyte ghost: the filed memory leak turns out to be already dead, and now we know exactly what it was
- M18 opens with the scariest filed defect — RSS growing ~10 MB per project cycle under agent-style churn, 114→985 MB over a 90-cycle soak — and closes it without changing a line of code, because the investigation proved the leak died last week. The mechanism, now named with measured evidence: every time a player start raised the "disconnected state" exception that m16-a taught the app to survive, Apple's audio framework abandoned that player's internal scheduled-buffer state (≈0.6× the scheduled bytes, per raise, unreachable from outside — Apple frameworks are not exception-safe). The leak was born the day surviving those raises became possible and died days later when m16-h eliminated the raise class entirely. A bisected A/B against the exact leak-era build proves it: the same storm that gains 17 MB per cycle there is flat on today's build, with zero raises.
- The mandated 90-cycle soak now measures 0.065 MB/cycle steady-state (a one-time warm-up floor, then a flat band with healthy reclamation dips), an independent storm with a different churn shape confirms flat, both m16 audibility gates still pass, and the full suite is green. Total true malloc leakage after a storm plus 21 control connections: 7.4 KB — with a one-line hygiene candidate filed for even that. Sometimes the most valuable fix is proof you don't need one.

## 2026-07-16 — M17 wraps: the docs catch up with the features, and the feedback milestone closes
- Every user-feedback feature from this milestone is now documented where users and agents actually look: FEATURES.md gains rows for the insert-effect editors, space-bar transport, timeline pointer gestures, the free-instruments guide, the generation progress card, and the resize audit — plus two stale counts fixed (Explain coverage is 74 controls, not 46) and one long-stale row corrected (MIDI CC has been shipped since m16-b; the table still said "not yet"). The design language gains the controller-strip labeled-readout rule, the hover ghost-line and refusal-bubble idioms, and the generation card as the canonical violet surface. The architecture doc now records the staging laws that made this milestone's verification honest (settle timing, real-typing semantics, read-only bare seam calls).
- Seven verification gates that proved M17's features were promoted from throwaway session scratch into `scripts/gates/` with their measured laws and known quirks documented in-header, so future regressions can re-run the exact checks. M17 is complete: every feedback item from the 2026-07-15 session shipped and verified (the MLX-native spike stays open by design as a re-check tripwire). No code changes; suite stands at 2545 tests / 289 suites.

## 2026-07-16 — AI generation stops being a black box: one card tells you what's happening, every time
- Every generation job — started from the Sketchpad, by an AI agent over the wire, or through an import — now surfaces in one violet progress card that rides both workspaces: who started it, what stage it's in (real pipeline text like "Generating music (batch size: 2)…"), live percent, elapsed time, and an explicit red FAILED state carrying the worker's reason verbatim. If the generator isn't running, generating simply starts it — the card narrates "starting the AI generator…" and "loading the model…" instead of leaving you staring at nothing. Kill the generator mid-job and the card says so within seconds, plus a notice on the transport. There is deliberately no cancel button: the engine has no abort, and offering a lie is worse than nothing.
- Two long-standing honesty bugs died during verification: live jobs used to read QUEUED for their entire render (the client only recognized a literal stage string the real generator never sends), and a generation that failed while the app was reconnecting left its Sketchpad row spinning forever instead of admitting failure. Both fixed and regression-tested against the real generator's measured output. Suite: 2545 tests / 289 suites; zero wire surface changes (one new Explain topic: the card explains itself).

## 2026-07-16 — The window can be any size now: a resize audit fixes five alignment defects, one of them severe
- A systematic sweep of window sizes (small laptop to ultra-wide), both workspaces, both densities, and stacked side panels found and fixed five defects. The severe one: opening the Sketchpad or the clip-fix panel in a small window could overflow the entire layout — transport bar pushed off-window, blank white voids. Side panels now compress and scroll internally instead of dictating a minimum window size, a rule now written into the design language ("workspace side panels compress, never overflow").
- The rest of the polish: track-header names no longer truncate ("Synt…" → "Synth 10" even at the narrowest sidebar), mixer strips of different kinds (instrument/audio/bus) now align their pan knobs, faders, and section headers on one line rack-wide via a reserved chip slot, the piano roll's controller readout is labeled ("Mod (CC 1) 123" instead of a floating "123"), and instrument chips finally fit their full names. Ruler-to-lanes grid alignment was machine-verified pixel-exact before and after at every size. Suite: 2508 tests / 288 suites; zero wire surface changes.

## 2026-07-16 — Where the free instruments are: a verified guide, and the host proven against real plugins
- New guide `docs/FREE-INSTRUMENTS.md`: eleven verified free AU instruments (what they are, where from, install gotchas), the honest answer to "can I use Logic's instruments?" (no — they're app-internal, and the guide explains what IS shareable), what DAW Pro ships built-in, and a worked example of checking your own machine. Notable finding baked in: Spitfire LABS was folded into Splice INSTRUMENT in late 2025, so the guide points at the living product, not the dead brand.
- The hosting chain was proven against real third-party plugins end-to-end: Surge XT and Dexed were installed (user-level, no admin password — the guide documents the trick), discovered, loaded onto tracks, and rendered audibly (−19/−23 LUFS) entirely through the control plane. Kontakt 8, Reaktor 6, and Splice INSTRUMENT load cleanly too but stay silent until you give them content — expected shell-instrument behavior, now documented. Decision recorded: no VST3 hosting for now (every marquee free instrument ships AU on macOS); SFZ/DecentSampler import filed as a future spike. No code changes; suite stands at 2508 tests / 288 suites.

## 2026-07-16 — Space bar, at last
- Space toggles the transport: stopped plays from the playhead, playing (or recording) stops — the exact same actions as the transport buttons, now on the key every DAW user's thumb expects. The guard rails matter as much as the key: a space typed while renaming a track or marker, or while writing to the AI copilot, inserts a space and never touches the transport — even mid-recording. Key-repeat, modifier chords (⌘Space stays Spotlight's), and floating plugin windows are all ignored. The play button's tooltip now advertises "(space)". Suite: 2508 tests / 288 suites; zero wire surface changes.

## 2026-07-16 — The timeline starts talking back: grab the playhead, click to seek, double-click to split
- The arrange timeline now behaves the way your hands expect. Hover the playhead and the cursor becomes an open hand — grab it and scrub; the transport follows every tick of the drag. Hover empty timeline space and a faint ghost line marks the snapped beat under your pointer; click and the playhead jumps there. Everything follows the SNAP setting, and ⌥ bypasses it for fine placement — the same fine-drag modifier used everywhere else in the app. None of this can steal a clip drag or selection: clips and take lanes always win the pointer.
- Double-clicking a clip to split it now tells the truth when it can't: instead of silently doing nothing, a refusal (like a comp-member clip needing take.setComp or take.flatten first) appears in an amber bubble with the exact same message an AI agent gets over the wire — one vocabulary, human and machine. Splits land as a single undo step, notes fall to the correct halves, and redo re-splits. Suite: 2497 tests / 287 suites; zero wire surface changes.

## 2026-07-16 — The arrange view learns to zoom — and a years-old grid misalignment dies with it
- Zoom in and out of the timeline at last: ⌘+/⌘−/⌘0, trackpad pinch (anchored at the pointer), or the new toolbar cluster next to SNAP — from 25% (whole-song overview, bar labels thinning out automatically) to 1250% (individual beats stretch wide for fine edits). Zooming never loses your place: the playhead (or your pointer) stays pinned to the same pixel while the timeline scales around it. Track rows get S/M/L height steps in the same cluster. Both settings are remembered across launches, are not undo steps, and never touch the project data agents see.
- Fixing the zoom plumbing surfaced and killed a defect that had been in every arrange screenshot since the pinned ruler shipped: the lanes were drawn 6 pt to the right of the ruler, so every gridline sat slightly off its tick. Ruler and lanes are now pixel-coincident at every zoom level (worst measured deviation: 1 px, from line centering). Suite: 2481 tests / 286 suites; zero wire surface changes.

## 2026-07-16 — Click an insert, get knobs: every built-in effect now has an editor panel
- The mixer's insert effects finally open: click any built-in insert (or the slider glyph on its row) and a dark-glass editor card appears with a control for every parameter — proper units (Hz, kHz, ms, dB), logarithmic travel on frequency sliders so the musical range isn't buried, double-click to reset, hold ⌥ for fine control, changed values glow cyan. Adding an insert from the "+" menu opens its editor immediately, one editor is open at a time, and the master chain's inserts are editable the same way — previously master effects could only be adjusted by AI agents over the wire.
- Every slider drives the exact same parameter path AI agents use, so a drag is heard live, lands as a single undo step, and an agent changing a parameter is reflected in an open card immediately. Audio Unit plugins keep their own plugin windows. Suite: 2458 tests / 285 suites; no wire surface changes.

## 2026-07-16 — The control surface stops guessing: typos are taught, discarded recovery is confessed
- Every mutating command an AI agent (or any wire client) sends now rejects unknown parameters with a teaching error that names the bad key and lists the valid ones — ending the class of bug where `track.add {type:"instrument"}` silently created the wrong kind of track. 101 commands are covered (the rest are pure reads); the same strictness now applies at the MCP tool layer, where the SDK's default behavior had been silently stripping unknown keys before the app ever saw them.
- Crash recovery is now honest over the wire: if starting a new project (or opening/saving one) consumes a pending crash-recovery offer, the response says so — `discardedRecovery` with what was lost and when. Recovery timestamps are standard ISO-8601, and a new `project.recoveryBundles` command makes per-session abandoned work discoverable instead of filesystem-only. Verified with a real kill-and-relaunch crash simulation, twice independently. Suite: 2445 tests / 284 suites, npm 118/118; wire surface 126 commands / 129 MCP tools.

## 2026-07-14 — File→New no longer silences the rest of your session
- A serious, long-hidden playback defect is fixed: starting a new project after the engine had ever played (or adding a track after the session's first play) left every subsequently added audio clip permanently silent — honestly flagged with "couldn't play" notices, but silent. The investigation reproduced the cause in a 30-line pure-AVFoundation program: macOS's audio engine never grants start permission to a player attached more than one node deep while the engine is running, even though every public API reports it as connected. Every mixer strip in the app is three nodes deep, so any strip born on a running engine was a dead player host.
- The fix routes every strip birth through the two shapes proven safe: after a new-project rebuild the engine now stays stopped until something actually needs it (first play starts everything together), and adding a track while the engine runs triggers one clean engine rebuild (a 40-track batch add costs exactly one). Verified by a committed regression gate that plays and measures actual audio across five new-project cycles (previously silent from cycle 2, now full level on every cycle), the full teardown-crash test matrix (95 cycles, zero crashes), and byte-identical offline renders. Suite: 2418 tests / 283 suites, npm 118/118; wire surface unchanged.

## 2026-07-13 — Draw your expression: the piano roll gains a controller strip
- The MIDI expression feature is now complete end to end with its editing surface: a collapsible strip under the piano roll's velocity lane shows one controller lane at a time — pitch bend against a center guideline, mod wheel, sustain, or any CC via chips with plain-language names ("Mod (CC 1)", "Sustain (CC 64)") and a "+" menu. Draw with the pencil to insert points, drag a point to move it; each gesture is one undo step, and a strip edit is byte-for-byte the same operation an AI agent makes over the wire. Densely recorded gestures render as a clean stepped line (handles reappear as you zoom in), and arrange-view clip blocks show a faint trace of the first controller lane so expression is visible at a glance.
- Editing lives in the Pro density; the Simple density shows an honest "2 controller lanes" chip so data is never hidden. Clips without controller lanes render pixel-identically to before. Suite: 2411 tests / 283 suites, npm 118/118; wire surface unchanged. This completes the MIDI CC milestone arc (design → playback → live capture → editing surface).

## 2026-07-13 — Play it in: live CC, pitch bend, and sustain now sound through and record into takes
- Expression from a real MIDI controller now works end to end: turning the mod wheel or pressing the sustain pedal is heard immediately (within one audio quantum), and recording a take captures those gestures as controller lanes on the recorded clip — including a sustain pedal pressed during the count-in, which lands as the correct starting value rather than being lost. Captured curves are automatically thinned (duplicates dropped, dense wiggles bounded) so recordings stay light without losing the final value of any gesture.
- Loop recording composes correctly: each cycle's take lane gets the controller values that fall in it, and a pedal or bend held across a cycle boundary is injected into the next cycle's lane at its start — so every take plays back exactly as it sounded. Also fixed along the way: take lanes now preserve their gain envelopes and controller lanes across save/load (envelopes had been silently dropped since the take format landed). Verified by a live end-to-end test with a virtual MIDI keyboard, run twice independently; note-only recordings are proven byte-identical to before. Suite: 2392 tests / 281 suites, npm 118/118; wire surface unchanged.

## 2026-07-13 — MIDI clips learn expression: CC, pitch bend, and channel pressure now play back
- The two-audit-running gap in the MIDI model is closed for playback: a MIDI clip can now carry controller lanes — mod wheel and any other CC, pitch bend, sustain pedal, channel pressure — and they sound, on the built-in instruments (bend actually bends the pitch, sustain actually holds the notes) and on hosted Audio Units (which receive the raw MIDI). Two new commands (`clip.setControllerLane` / `clip.removeControllerLane`, with matching MCP tools) let agents author expression curves; splitting, trimming, duplicating, and arranging clips all carry the lanes correctly, including the value in effect at a cut point.
- The engine "chases" controller state at every playback start, seek, and loop wrap — so a loop never starts with a stuck sustain pedal or a leftover bend from the previous pass, and offline renders match live playback by construction (pinned by a render that measures a 440 Hz note bent to the expected 493.876 Hz). Projects without controller data save byte-identically to before. Suite: 2367 tests / 280 suites, npm 118/118; wire surface 125 commands / 128 MCP tools.

## 2026-07-13 — Timing-compensation buffers get the same seam protection as effect tails
- A theoretical hazard measured by the last audit (structurally real, never once observed in 113 adversarial trials) is now closed for symmetry with the effect-chain fix that shipped earlier: the delay buffers that keep plugin latency compensated could, in a sub-millisecond window at a stop or seek, replay one stale buffer of audio a few milliseconds late. The clearing now uses the same two-pass countdown the effect chains use during live playback, while offline rendering deliberately stays single-pass (proven necessary for byte-identical bounces). A forced-interleaving test reproduces the old behavior permanently as a negative control; the audit's own three capture probes re-ran clean as the regression gate.
- Verification also strengthened an open lead: under an adversarial 41-track rig, a second project-rebuild cycle in one instance skipped every clip with honest "couldn't play" notices (the app stays alive and honest where it used to crash — but the underlying AVFoundation rebuild defect is now filed for a proper investigation of its own). Suite: 2310 tests / 275 suites, npm 106/106; wire surface unchanged.

## 2026-07-13 — "Render my song" now works on MIDI-only projects
- The most natural agent workflow — compose MIDI, then render with default settings — used to dead-end on a false error claiming the project "has no audio clips." The mixdown default now uses the same render window every sibling command already used (through the end of the last clip of any kind, plus a two-second tail), so a MIDI-only project renders on the zero-parameter call. The error now fires only for a genuinely empty render range, and says what to do about it ("add clips or pass an explicit durationSeconds").
- Renders with an explicit duration are proven byte-identical to before (pinned by checksum), the stems command turned out to already default correctly (now pinned so it stays that way), and the stem/bounce equivalence guarantees all held verbatim. Suite: 2306 tests / 275 suites, npm 106/106; wire surface unchanged.

## 2026-07-13 — A missing audio file is no longer a silent mystery
- The last quiet failure in playback honesty is closed: a clip whose audio file has been moved or deleted used to just play as silence with no explanation anywhere. Now it raises a playback notice the moment it's discovered — whether that's when a project opens ("'Bed Vox' will be silent — its audio file is missing… Restore or re-link the file"), when recovery restores a session, or when the engine rebuilds and can't open the file. The notice names the clip, the actual file path, and where it sits in the timeline; agents see the same facts in the project snapshot without having to catch the open response.
- One subtle case surfaced during verification: recovery bundles reference media by absolute path, and those produce no warning in the recover response at all when the file is gone — the new notice is the only signal, which is exactly why it derives from the project's real state rather than echoing warning strings. Suite: 2304 tests / 275 suites, npm 106/106; wire surface unchanged.

## 2026-07-13 — MIDI CC and pitch bend: designed, measured, ready to build
- The most-requested missing capability — continuous controllers (mod wheel, sustain, pitch bend, channel pressure) — now has a complete design: controllers live on MIDI clips as compact stepwise lanes (not mixer automation — different plane, different transport), play back through the same schedule that already survives gapless loops, and always **chase**: starting playback anywhere delivers the correct controller state first, so a sustain pedal or bent note is never stuck from a previous pass. The design round also measured the engine's real event-throughput budget (settling the thinning policy for dense controller recordings) and uncovered two latent bugs the implementation will fix on the way in — including one where a schedule bookkeeping formula silently assumed every MIDI event comes in on/off pairs.
- Implementation lands in three phases (playback, live input + recording, piano-roll editing strip) behind twenty numbered verification conditions, including byte-identical rendering for projects that use no controllers at all. Design: docs/research/design-m16b-midi-cc.md.

## 2026-07-13 — The crash class is dead — and it wasn't what it looked like
- The audit's three crashes looked like a SwiftUI drawing bug; the design round proved otherwise with a deterministic reproduction: the audio engine was raising an Objective-C exception ("player started when in a disconnected state") in the middle of starting playback, and that exception corrupts Swift's main-thread bookkeeping — after which the app either crashes at some unrelated later moment (the drawing code was just the most frequent bystander) or, worse, silently stops responding while looking alive. A crash log from July 6 proved the class long predates last week's changes.
- Three layers of fix landed: playback never hands a disconnected player to the audio system (a clip that can't play is skipped with an honest playback notice instead of an exception); every engine entry point now runs behind an exception barrier that converts a raise into a clear error plus a notice instead of letting it corrupt the app; and all seventeen custom drawing surfaces were hardened so no isolation checks sit in the drawing path at all. The killer recipe that took the app down by the second pass now runs clean indefinitely (verified independently, ten of ten, plus a 15-minute adversarial soak and a ten-round mutation storm — zero crashes, zero hangs), and everything still draws pixel-identically. Suite: 2294 tests / 273 suites, npm 106/106. One new lead filed for the next audit: memory grows under extreme project-rebuild churn — measured, bounded recipe recorded, not yet diagnosed.

## 2026-07-13 — The post-M15 audit: a real crash class found, next milestone planned
- With M15 closed, an audit agent again spent a session driving the app over the control connection like a demanding beta user — and this time caught something serious: the app crashed three times in about 35 minutes of ordinary use, all with the same signature (SwiftUI Canvas drawing closures faulting on a stale captured reference during playback), once on a project with only two tracks. All three crash logs are preserved with reproduction recipes; killing this class is the next milestone's first item. The audit also measured a quieter honesty gap — a clip whose audio file is missing plays as silence with no playback notice (the one case the new notices system doesn't cover) — plus a false error that blocks rendering MIDI-only projects with default settings, a silent crash-recovery discard over the wire, and more silently-ignored-parameter traps than the last survey concluded.
- The good news held up under attack: loop recording, master automation, the arrange commands, multi-meter math, crash recovery fidelity, and a 150-second playback with a live gapless loop wrap (zero audio overruns across 290,000 callbacks) all passed adversarial probing. The previously-filed PDC timing hazard was measured directly — structurally real but never observed in 113 adversarial trials, so it gets a cheap symmetry fix, not an emergency. M16 is now planned: the crash fix first, then MIDI CC lanes (the long-requested headline, behind a design doc), then the honesty round.

## 2026-07-13 — Documentation catch-up: the docs now match the app (M15 complete)
- A documentation pass folded everything the last two milestones shipped into the user-facing docs: gapless looping, loop-take recording, master volume automation (including the stems-stay-fade-free policy), the new arrangement commands, playback notices, and the bypass crossfade all have honest FEATURES entries now; stale rows were corrected (the master effect chain has been shipped since m13-d; MIDI CC honestly doesn't exist yet), all published command/tool counts were brought up to today's reality (123 commands / 126 MCP tools), and the loop-recording semantics are now taught both in the wire protocol's own documentation and the MCP tool descriptions agents read. One long-standing grammar bug in an error message ("a instrument track") is also fixed.
- This closes **M15 — the post-gapless correctness round** end to end: the metronome meter-map bug, loop-cycle take recording, master automation, agent arrangement ergonomics, engine notices, click polish, and docs. Suite: 2286 tests / 270 suites, npm 106/106.

## 2026-07-13 — Two audible clicks hunted down and removed
- Toggling an effect's bypass mid-signal no longer clicks: the hard swap (measured landing between two adjacent samples) is now a 10 ms equal-power crossfade, so switching a compressor or delay in and out during playback is smooth — reverb and delay tails ring out naturally under the falling gain instead of being chopped. Toggling back mid-fade reverses the fade seamlessly rather than restarting it.
- A subtler one from the M14 files is also gone: after an edit during playback, one buffer of pre-edit audio could sneak into a freshly-cleared delay line and come back as a faint one-time echo. The clearing now double-arms during live playback so the first post-edit buffer always renders on a clean line. Both fixes were proven by measurement (before/after captures with stated thresholds, and the old bug kept reproducible in the test suite as a negative control); projects that never touch bypass render byte-identical to before. Suite: 2286 tests / 270 suites, npm 106/106; wire surface unchanged.

## 2026-07-13 — When playback degrades, the app now says so
- Until now, three kinds of quiet trouble — a gain envelope or fades that couldn't be applied this pass, or a clip still being time-stretched that plays as silence — were only ever written to a developer log. They now surface as playback notices: an amber chip appears in the transport bar (in both Simple and Pro modes — a beginner whose fades vanished needs to know more, not less) and opens a card listing each notice in plain language, with a repeat count when the same thing keeps happening. Nothing in the project is ever changed by a notice, and a healthy session shows nothing at all.
- Agents get the same honesty: `project_snapshot` now carries an `engineNotices` field (absent when all is well), coalesced by kind, cleared when a project is created or opened, never saved to disk. Proven live end-to-end: deleting a clip's audio file out from under a scheduled fade produced the honest notice over the wire, repeats coalesced, and a new project cleared it. Suite: 2276 tests / 269 suites, npm 106/106; wire surface unchanged at 123 commands / 126 tools.

## 2026-07-13 — Restructure a whole arrangement in one command
- Three new commands close the gap between what a human can drag and what an agent had to emulate clip-by-clip: `clip.duplicate` copies a clip with everything it carries (notes or audio, gain, fades, envelope, stretch) and lands it cleanly under the no-silent-overlap law; `arrange.insertBars` and `arrange.deleteBars` add or remove whole bars across the entire session — every track, marker, tempo and time-signature change, automation lane, and the loop region move together, meter-aware (a bar in a 6/8 section is honestly six beats), one undo step for the whole restructure. Edge policies are explicit rather than surprising: straddling clips split or trim, a swallowed loop is disabled, and a delete that would knock a time-signature change off its barline is refused with a clear error.
- The audit's silent-typo trap is also dead: misspelling a parameter to `track.setOutput` used to silently re-route the track to master and report success — it (and `input.setDevice`, the one other command with the same shape) now rejects unknown keys with an error that names the typo and lists the valid keys. All proven live over the control connection end-to-end. Wire surface grows deliberately: 123 commands / 126 MCP tools (was 120/123), Copilot catalog 55. Suite: 2253 tests / 264 suites, npm 106/106.

## 2026-07-13 — Fade out the song: master volume automation
- The master bus can now be automated: draw a volume curve on the master strip (Pro mode) or program it through the AI channel with the same automation commands tracks use — "fade out the last eight bars" is a one-command job for an agent now. The fade applies before the master effect chain, so a limiter keeps working the fade the way a mastering chain should, and the timing stays sample-exact even with the limiter's lookahead (proven bit-for-bit). A flat automation lane renders byte-identical to simply setting the master fader.
- One deliberate policy ships with it: stem exports and bounce-in-place stay fade-free — a fade is a performance decision, not material, and baking it into stems would ruin re-mixability. The mastered mixdown gets the fade; stems don't (pinned by a measurement that shows exactly that). Simple mode hides the lane; recording is never colored by a master fade. Suite: 2226 tests / 262 suites, npm 92/92; wire surface unchanged at 120 commands / 123 tools.

## 2026-07-13 — Record a new take on every loop pass
- The classic loop-recording workflow has landed: hit record with a loop enabled and the transport seeks to the loop start, plays the region gaplessly (the M14 machinery), and lands each pass as a new take lane on the same take group — three passes, three comparable takes, newest selected, one undo removes the whole recording. Stopping mid-cycle keeps an honest partial lane; MIDI notes held across the loop seam keep their true length (a bug-in-waiting the design round caught before it shipped); count-in composes cleanly and now has its own small transport-bar stepper. Everything was proven live over the control connection: a real session recorded three lanes with the right notes in the right lanes.
- The audit's honesty bug is dead both ways: recording with a loop no longer silently rolls linear while claiming the loop is active, and editing loop bounds mid-recording is refused with a clear "stop first" error instead of corrupting the take. Recording without a loop is bit-identical to before (pinned by a measured checksum). No new commands — loop state alone decides. Suite: 2197 tests / 258 suites, npm 86/86; wire surface unchanged at 120 commands / 123 tools.

## 2026-07-13 — The metronome now respects time-signature changes
- The audit's top bug is fixed: the live metronome (and the offline renderer, and count-in) built its click grid from a single fixed time signature, so any project with a meter change accented the wrong beats after the change. All three paths now receive the project's real meter map — re-running the audit's measurement probe verbatim shows all 23 captured clicks classified correctly with downbeats exactly where 4/4→3/4 puts them, offline renders match, and a count-in in 3/4 is honestly three beats anchored to the meter at the record position.
- Implementation surfaced a second latent bug the audit hadn't caught: a meter-only change never reached the audio engine at all (only tempo changes pushed), which would have left a playing session's clicks stale — both store funnels now push meter changes too. Projects in a single time signature render byte-identical to before. Suite: 2173 tests / 254 suites, npm 86/86; wire surface unchanged at 120 commands / 123 tools.

## 2026-07-13 — The post-M14 audit: two live-measured bugs found, next milestone planned
- With gapless looping done, an audit agent spent a session using the app the way a beta user (or AI agent) would — driving it entirely over the control connection — and measured two real bugs: the live metronome ignores time-signature changes (with a 4/4→3/4 change, downbeats land on the wrong beats — every click was captured and classified by pitch and level to prove it), and recording with a loop enabled silently records linear from the playhead while claiming the loop is active. It also caught a trap where a typo in one command's parameter silently re-routes a track instead of erroring, and — good news — dismissed a previously-filed concern with code evidence (loop-boundary dragging already commits cleanly once per gesture). Six probe legs including a 53-track session ran crash-free, the first fully clean audit session on record; project-file compatibility and scaling checks came back healthy.
- The findings seed the new M15 milestone, now on the roadmap in priority order: the metronome fix first, then loop-cycle take recording (recording a new take on every loop pass — the payoff M14's fixed anchor makes possible), master-volume automation ("fade out the song" is currently impossible), three agent-ergonomics verbs (duplicate a clip, insert/delete bars project-wide, and the typo-trap hardening), a visible engine-notices surface for degradations that today only reach stderr, two click-polish items, and doc fold-ins. Audit document: docs/research/audit-m15.md; nothing in the product changed today. Suite unchanged: 2168 tests / 253 suites, npm 86/86; wire 120 commands / 123 tools.

## 2026-07-13 — Gapless looping ships: the loop wrap is no longer an event (M14 complete)
- The final phase landed and was proven against the live app over the real control connection: a delay tail rings straight through every loop boundary (measured energy across each seam, zero silent gaps, cycle onsets spaced drift-free to the exact frame — the old ~60 ms hiccup and ~2% per-cycle drag are gone for audio, instruments, automation, and metronome alike). Stopping still silences instantly, and editing the loop bounds mid-play costs exactly one clean seam with no stale audio from the old bounds — both directions proven live.
- Long loop sessions no longer accumulate memory: played-out schedule history is pruned under a new invariant (decided and written into the design doc before a line of code, per the milestone's amendment law), proven by a soak test across multiple pruning events with every note still delivered exactly once and sustained voices unharmed. The architecture doc now records the settled loop contract. One cosmetic finding filed for later: a faint, bounded echo blip can ride inside an *edit* seam (never a wrap). Suite: 2168 tests / 253 suites, npm 86/86; wire surface unchanged at 120 commands / 123 tools.

## 2026-07-12 — The metronome joins gapless looping, and toggling it never touches your audio
- Phase three of gapless looping: metronome clicks are now scheduled across loop cycles ahead of time like everything else, so the click at the loop boundary fires every single cycle (it used to skip one after each wrap) and even a quarter-beat loop at 400 BPM clicks perfectly for 25+ measured cycles. Clicks follow the meter map across the seam — a 4/4→3/4 change inside the loop accents correctly in every cycle.
- Turning the metronome on or off mid-play is now completely isolated to the click player: the headline proof pins every one of 480 000 rendered frames — clip output during a toggle session is byte-identical to a never-toggled run, commanded clicks appear exactly on the grid, and cancelled clicks never sound. The old fallback that restarted playback via a seek just to toggle the click is retired. Suite: 2166 tests / 251 suites; wire surface unchanged at 120 commands / 123 tools.

## 2026-07-12 — Instruments and automation now sail through the loop point too
- Phase two of gapless looping: MIDI notes and automation curves are now unrolled across loop cycles ahead of time, the same way audio clips were in phase one — the per-wrap "flush everything and rebuild" is gone. Synth voices persist through the seam: a sustained note ringing across the loop boundary keeps sounding (measured: the seam that used to render pure silence now carries the note's full energy), note-offs land at their true musical positions even past the loop end, and a note released at the seam pairs correctly with the same pitch re-struck in the next cycle. Automation values step cleanly at the boundary and interpolate exactly within each cycle. Stopping, seeking, or editing still cuts voices immediately, as it should.
- Every event's sample position is pinned to exact arithmetic under multi-segment tempo maps, and the schedule-extension machinery is proven to deliver every note-on and note-off exactly once even when the schedule grows mid-render. Non-looping playback is byte-identical to before. One design-document correction came out of implementation: append-only schedules grow with total cycles played (not bounded by the look-ahead as the design claimed) — recorded as an open decision for the final phase. Suite: 2160 tests / 250 suites; wire surface unchanged at 120 commands / 123 tools.

## 2026-07-12 — The loop hiccup is dying: audio now plays seamlessly through the loop point
- The first implementation phase of gapless looping has landed. Until now, every loop wrap stopped and restarted the audio engine's players — about 60 ms of silence plus a 35 ms overshoot at every pass, and a ~2% per-cycle drift. Audio clips now play straight through the wrap: upcoming loop cycles are queued onto the already-rolling players ahead of time, spliced sample-exactly (verified bit-for-bit across multiple wraps — zero dropped frames, zero silence at the seam), with fades and gain envelopes pre-baked once and reused every cycle. Even the extreme case — a quarter-beat loop at 400 BPM, ~26 wraps per second — sustains indefinitely.
- Implementation surfaced two undocumented macOS audio-player behaviors that the research spike's margins had only just cleared (a fully-drained player queue goes permanently silent; mid-flight queueing needs a minimum head start) — both are now recorded in the design document with the measured numbers, and the scheduling rule that contains them is pinned by tests. MIDI, automation, and the metronome still do their old per-wrap reset for now (their gapless phases are next); recording and non-looping playback are proven byte-identical to before. Suite: 2150 tests / 249 suites; wire surface unchanged at 120 commands / 123 tools.

## 2026-07-12 — The feature guide catches up with the product (M13 complete)
- FEATURES.md had drifted behind three milestones of shipped work: it now teaches multi-segment tempo maps with meter changes (range 20–400 BPM, not the old single-tempo 20–300), the true control surface size (120 commands / 123 MCP tools, up from the documented 108/111), the three newer command namespaces (marker, tempo, instrument), and the fact that AI agents can read live peak/RMS meters for the master and every track straight out of `project.snapshot` — a capability the docs previously undersold. Two older user-facing copy fixes from the beta round were re-verified still in place.
- Documentation-only, proven by a file-timestamp scan (exactly one file changed). With this, **M13 — the correctness & console round — is complete**: teardown crash killed, silent clip overlaps ended, recording guarded, master insert chain, clip gain envelopes (plus their perf fix), gapless-loop blueprint, hidden-surface AU picker and pinned ruler, meter-aware snapping, and these doc fold-ins.

## 2026-07-12 — Pressing play on a long clip with a gain envelope is no longer expensive
- Since gain envelopes landed, any clip carrying one was fully pre-rendered into memory on every play, seek, or loop restart — for a 10-minute stereo clip that meant roughly 190 ms of extra latency and a ~280 MB memory spike each time, even if the envelope only dipped a few bars. The engine now pre-renders only the spans the envelope (or a fade) actually shapes and streams the rest straight off disk: the same clip now schedules in ~41 ms with a ~1 MB envelope footprint. Clips whose envelope genuinely shapes the whole region still pay the honest full cost.
- The sound is untouched — every render is bit-for-bit identical to before, proven by four checksum gates including a real project file (rendered from a copy). Measurement drove the fix: two fancier candidates (math micro-optimization, a bake cache) were rejected because the numbers showed the whole-region read was the real cost. 10 new regression pins. Suite: 2144 tests / 248 suites; wire surface unchanged at 120 commands / 123 tools.

## 2026-07-12 — Dragging snaps to the real bar grid, even after a time-signature change
- Until now, dragging and resizing snapped as if the whole song stayed in its opening time signature — in a piece that switches from 4/4 to 6/8, "snap to bar" would land clips off the real barlines after the change. Every drag surface now consults the project's meter map: clip move/trim/split/stretch, loop-region create/resize/move, marker drag and placement, take-comp painting, and the audio-import landing spot all snap to true barlines on both sides of any meter change, and finer grids follow the local meter. Songs in a single time signature behave exactly as before, pinned by exhaustive property tests against the old math.
- 11 new tests, including a live check that the on-screen drag math and the AI control channel agree exactly on a 4/4→6/8 map. Suite: 2134 tests / 247 suites; wire surface unchanged at 120 commands / 123 tools.

## 2026-07-12 — Every installed effect plugin in the mixer menu, and a ruler that never scrolls away
- The mixer's insert menu used to list only the 9 built-in effects even though the app could already host any installed Audio Unit through its AI channel — now an "Audio Units…" item opens a searchable dark-glass picker of every installed AU effect, and a pick routes through the exact same code path AI agents use, so UI adds and wire adds produce identical results. The master strip honestly hides the option (master inserts are built-ins-only by design, not offer-then-error).
- The bar ruler — together with the loop band, marker lane, tempo lane, and TRACKS header — now stays pinned at the top while you scroll a deep session, and both columns still scroll as one unit so track rows and their lanes can never drift apart. Also: the Pro gain-envelope overlay now ghosts the waveform beneath it so breakpoints stay readable against the audio. Suite at landing: 2123 tests / 247 suites; wire surface unchanged.

## 2026-07-12 — The loop seam has a blueprint: gapless looping is proven possible
- Anyone who builds beats in DAW Pro knows the loop hiccup: every time the loop wraps around, there's a brief stumble before it picks up again. We measured it precisely for the first time — about 35 ms of overrun past the loop end, then 60 ms of silence, and (worse for groove) each cycle runs about 2% long, so a loop slowly drags against any external rhythm. Reverb and delay tails also get chopped at every pass. Today's research spike proves the fix is real: the audio system can splice loop cycles together with zero dropped samples — verified bit-for-bit in a permanent test suite, including the hard case of queueing the next cycle while the current one is still playing.
- The full design is written up with a phased implementation plan (scheduled as the next milestone) and eight pass/fail conditions that gate the work. A pleasant consequence of the chosen approach: effect tails will ring naturally through the loop point, the metronome will toggle on/off mid-playback without a stutter, and loop-cycle take recording (record a new take on every pass) becomes straightforward to build on top. No product code changed today — this was measurement, proof, and planning; the loop behaves exactly as before until the implementation lands. Suite: 2115 tests / 246 suites; wire surface unchanged at 120 commands / 123 tools.

## 2026-07-12 — Shape a clip's loudness over time with gain envelopes
- Audio clips can now carry a gain envelope: click points onto the clip (Pro view) and drag them to ride the level inside the clip itself — duck a breath, swell into a chorus, tail out a phrase — without touching the track fader or writing automation. Points interpolate smoothly in decibels, they multiply with the clip's existing gain and fades rather than replacing them, and the whole gesture of dragging a point is one undo step. The envelope travels with the clip when you move it, splits continuously when you split the clip (no level jump at the seam), survives trims, and is preserved when takes are grouped or comped. Simple view keeps clips clean — envelopes are a Pro-view tool, though they always play back in both views.
- AI agents get the same control through one new command that sets or clears a clip's envelope in a single call, with plain-language rejections for anything malformed (unsorted points, MIDI clips — envelopes are audio-only for now). Rendering honesty was proven hard: an envelope-free project reproduces every historical render byte-for-byte — including after a full save-and-reopen cycle — and rendered ramps were measured against their analytic values over the control wire (−6 dB at the midpoint of a 0-to-−12 ramp, exactly). A mandated engine review confirmed the real-time audio thread is untouched — envelopes are baked offline before playback — and caught two edge-case bugs (take-comping and AI clip-fix could lose or stale-bake an envelope) that were fixed with pinned regression tests before this shipped. Suite: 2111 tests / 245 suites; npm 86/86; wire surface grows to 120 commands / 123 tools; Copilot catalog 52.

## 2026-07-12 — Master your song: an insert chain on the master output
- The master strip finally takes effects. Drop an EQ, limiter, compressor — any of the nine built-in effects — onto the master output and shape the whole mix at once; "make this loud enough for streaming" is now a real workflow (EQ, then limiter, then measure loudness) instead of a dead end. The chain sits after the master fader, the last stop before your speakers, so the fader rides into it exactly the way a mastering chain expects. Everything behaves like track inserts already do: reorder, bypass, tweak parameters live while the song plays (the playhead never hiccups — verified mid-playback and even mid-recording), full undo/redo, and it saves with the project. In Simple view the master strip stays clean fader-and-meters; switch to Pro to see the inserts. The master meter and analysis now honestly read what actually leaves the app — after the chain.
- Stems deliberately stay untouched by the master chain — they're for handing off to another mixer or re-importing, so bouncing stems with a master limiter on still gives you the raw, unsquashed parts, and the parts still sum exactly to the pre-chain mix (verified byte-for-byte). AI agents get the same power through the existing effect commands via the address `"master"`, with plain-language refusals for the two things the master chain won't do in v1: host third-party Audio Unit effects, and take part in sidechain keying (in either direction). The whole feature moved zero bytes in existing audio: every previous render anchor reproduced byte-identically with an empty chain, and a unity-gain chain is bit-transparent. One subtle Apple-engine behavior was caught and designed around along the way: the obvious "pre-fader" wiring is not bit-transparent under a non-unity fader, so the shipped shape is the one that is. Suite: 2090 tests / 243 suites; npm 86/86; wire surface unchanged at 119 commands / 122 tools; Copilot catalog grows to 51 commands.

## 2026-07-12 — Your take is safe: routing changes wait until recording stops
- Recording is now protected from the one class of edit that could silently ruin it. Changing what's routed where — adding or removing sends, switching a track's output bus, deleting a track, or re-keying a sidechain — used to be legal in the middle of a take even though it forces the audio engine to rebuild, cutting the capture short while the record light stayed on. Those operations are now politely refused while recording, each with a plain instruction ("cannot add a send while recording — stop first"), and a refused attempt leaves no trace in undo history. Everything that's safe stays live mid-take: volume and pan rides, send levels, effect knobs and bypass, muting, soloing, clip edits, even adding a fresh track or effect — so a producer (or an AI copilot) can keep mixing while the artist records.
- The rule is principled rather than a verb blacklist: an operation is blocked only if it would actually trigger an engine rebuild, so removing an ordinary effect stays legal while removing a sidechain-keyed one waits, and swapping a synth's waveform stays legal while swapping the instrument on a routed track waits. The AI-agent tool descriptions teach the rule up front. Verified with two independent live recording sessions: takes complete intact to the last note, refused commands name their reason exactly, and the same commands succeed the moment recording stops. Suite: 2066 tests / 239 suites; npm 86/86; wire surface unchanged at 119 commands / 122 tools.

## 2026-07-12 — Clips never silently stack anymore, no matter which tool put them there
- Closed the last four ways a clip could land on top of another and quietly double the audio: extending a clip's edge, stretching it longer, and dropping new audio or MIDI at a specific beat all now trim the clip that was already there — exactly like moving a clip has done since the crossfade release. The worst case was real: placing a full-length audio clip on top of an identical one used to double the volume (+6 dB) with nothing visible in the arrangement; that same operation now measures a 0.0000 dB difference. Every one of these edits stays a single undo step that restores both clips, tiny leftover slivers are cleaned up rather than left behind, and recorded takes still stack intentionally — take lanes are exempt by design.
- The fix is structural, not another patch: all clip-geometry edits now flow through one shared policy point, so a future editing verb can't reintroduce the bug by forgetting the rule. An audit of every geometry-touching operation found and closed one more unlisted gap (growing a MIDI clip by inserting time could overlap its right neighbour) and documented why the rest are safe by construction. Verified live over the control wire on both the original bug recipes and an independent second set of scenarios. Suite: 2060 tests / 239 suites; npm 86/86; wire surface unchanged at 119 commands / 122 tools.

## 2026-07-12 — The teardown crash is dead: engines are rebuilt, never unpicked
- Fixed the most serious stability bug the app has ever had: starting a new project (or removing a track) after playing a session with bus routing could crash the whole app, intermittently, deep inside Apple's audio engine. An instrumented experiment run before any fix code named the exact mechanism: once a node has rendered audio and then sits attached across an engine stop-and-restart, Apple's engine quietly forgets how to detach it safely — the previous fix ("park detaches until the engine restarts") was built on that unsafe operation and crashed in its own machinery. The suspicion that the recent sidechain work caused it was tested and disproven: a rebuilt pre-sidechain binary crashed identically.
- The resolution removes the entire trap by design: the app never surgically unpicks a once-used engine again. Any teardown-class change — new project, opening a project, removing a routed track — now discards the whole audio engine and rebuilds it fresh from the project model in a tenth of a second or less (worst measured: 143 ms at 41 tracks; a mid-play rebuild resumes playback seamlessly with meters live within a quarter second). Effect chains, hosted Audio Unit state, plugin windows, and open projects all survive the rebuild untouched. Proven by a zero-crash campaign that used to be near-deterministic death: 100 consecutive rebuilds (+0.4 MB memory), every historical crash recipe, a 12-way played/routed matrix, 41-track stress runs, and an independent gauntlet of back-to-back project switches, bus removals, and undo storms — plus byte-identical offline renders before and after the change. Suite: 2045 tests / 238 suites; npm 86/86; wire surface unchanged at 119 commands / 122 tools.

## 2026-07-12 — Sidechain everywhere it belongs: one command, one tool, one click
- Sidechaining is now a first-class citizen across every surface. A single control command (and matching AI-agent tool) keys any compressor or gate from another track — or clears it — with the update visible immediately in project snapshots, undoable in one step, and safely refused with a plain-language explanation when a request can't work: keying a reverb, keying from a bus, doubling up keys on one strip, or creating a feedback loop (the error names the exact path, like "Kick → Pad → Kick"). The AI Copilot knows the command too, so "make the pad duck under the kick" is now a one-sentence request. Verified live end-to-end: keying through the real command produced a 24.6× duck on the pad, and independently, a gate chopping a tone dropped its stem by 8.5 dB; re-keying to a different source, clearing by omission, undo/redo, and save→reopen all held up over the wire.
- In the mixer, compressor and gate cards in Pro view now carry a KEY picker: choose a source track and a lit cyan "KEY ▸ Kick" badge appears with a one-click clear (Simple view stays deliberately fader-and-meters only). The Explain assistant can teach sidechaining, and the release-blocking equivalence guarantees are now permanent tests: stems still sum to the mixdown exactly with a sidechain active, and bouncing a keyed track is byte-identical to its stem. Projects that never touch sidechain rendered byte-for-byte identically across the seventh consecutive render-gate generation. Suite: 2042 tests / 238 suites; npm 86/86; wire surface 119 commands / 122 tools; Copilot catalog 47. **This completes milestone M12.**

## 2026-07-12 — Sidechain compression is real: kick-ducks-the-bass, sample-accurate
- Compressors and gates can now listen to a *different* track: point a compressor on your pad at the kick drum and the pad ducks every hit (the classic pumping effect), or key a gate on a sustained tone from a rhythmic part to chop it into that rhythm. The keying is sample-accurate — verified with closed-form math, not tolerances: a keyed compressor's dip depth matched the ratio equation to nine decimal places, and a keyed gate opened on the exact frame the key landed. It's also safe by construction: removing the key source degrades the effect back to normal operation without ever failing playback, feedback loops are refused up front with a message naming the exact path that would loop, and every project that doesn't use sidechaining renders byte-for-byte identically to before (proven across six generations of the render gate). Stems still sum to the mixdown exactly with a sidechain active.
- Independent verification caught and fixed one real bug before it could bite: the effect's key assignment survived undo/redo and played correctly, but the project *file* format silently dropped it — save, reopen, and every sidechain would have been gone. That path is now fixed, regression-pinned, and proven live (save → reopen → key intact), and project snapshots read over the wire now show which track keys which effect. For now this is engine-level (AI-drivable through a staging command); the polished wire command, effect-card KEY picker, and Copilot integration land next. Suite: 2027 tests / 235 suites; npm 86/86; wire surface unchanged at 118 commands / 121 tools.

## 2026-07-12 — The tempo lane arrives: see and shape tempo and meter on the timeline
- The ruler now has a tempo lane: every tempo segment is drawn with its BPM label, meter changes fly small time-signature flags, and in Pro density you edit right there — drag a boundary to move where the tempo changes, scrub a segment's BPM, double-click to add a change, and edit the meter at any barline. A whole drag is one undo step, and everything the lane does goes through the same command the AI uses, so what you see and what an agent reads over the wire can never disagree (verified live: the lane's state and the wire's map matched exactly after every edit). Simple density shows the lane read-only — the information without the sharp edges — and single-tempo projects look exactly as before, with no new chrome to ignore.
- The whole timeline now understands meter: bar numbers stay correct across time-signature changes (a 7/8 section numbers its bars exactly right and hands off cleanly to 4/4), the transport shows your position as bars.beats, and the piano-roll grid follows the clip's meter. Audio clips that span a tempo change carry a small amber "tempo" badge — an honest heads-up that audio doesn't stretch when tempo changes (and why quantizing across that boundary asks you to split first). The Explain assistant can now teach the tempo map, and the codebase-wide lint that forbids raw tempo math outside the map reached its end state: exactly one sanctioned home remains. Suite: 1998 tests / 233 suites; npm 86/86; wire surface unchanged at 118 commands / 121 tools.

## 2026-07-12 — Tempo changes are now real: saved, editable, and undoable
- Tempo maps are no longer a hidden engine capability — you (or an AI agent) can now author them. A new pair of control commands reads and replaces the whole tempo map and time-signature map in one step, so a song can slow into its intro and lift into its drop, and the change is a single undo away. A tempo-lane drag folds into one undo step, editing is refused mid-recording, and asking to set "one tempo" on a song that already has tempo changes is politely refused with a pointer to the map command rather than silently flattening your work. Tempo maps now save and reload with the project (older projects and single-tempo songs are byte-for-byte unchanged on disk), and the AI Copilot gained both commands.
- Under the hood this retires the temporary staging scaffold from the previous phase and routes everything through the real, undoable store mutation; in-flight AI clip-fix jobs detect a tempo change through a cheap revision counter. The real-time audio thread stayed completely untouched (all 17 render-path files byte-identical), and the single-tempo render gate reproduced its exact SHA-256 hash. Suite: 1977 tests / 231 suites; npm 86/86; wire surface 118 commands / 121 tools; Copilot catalog 46. Next: the tempo lane UI and meter-aware ruler.

- Building on the tempo-map foundation, the playback engine is now provably correct when the tempo actually changes mid-song: MIDI notes, audio clips, automation, the metronome, fades, and crossfades all land at their mathematically exact sample positions across a tempo boundary, verified with closed-form expectations (not tolerances) around a 120→90 change — and independently re-verified on a different three-segment map (140→70→105) where note spacing matched the analytic integral to the exact sample. Live behavior holds up too: the playhead advances smoothly through boundaries, looping across two tempo changes wraps at the right musical length, and editing the map mid-playback never makes the playhead jump.
- Two known debts from the foundation phase are settled: fades and crossfades now bake correctly across a boundary (equal-power crossfades stay seamless — 0.017 dB spread at the seam), and audio-quantizing a clip that spans a tempo change is cleanly refused with guidance to split at the boundary first, rather than producing subtly inconsistent timing. Projects that never change tempo render byte-identically to before — the original gate project reproduced every SHA-256 hash on the new engine — and stems still sum to the mixdown exactly, with bounce-in-place byte-identical to its stem even under a multi-segment map. Tempo changes aren't user-authorable quite yet: persistence, the wire commands, and undo arrive next, then the tempo lane UI. Suite: 1958 tests / 228 suites; npm 86/86; wire surface unchanged at 116 commands / 119 tools.

## 2026-07-11 — The tempo map's foundation is in, and the audio is provably unchanged
- Under the hood, every place the app converts between musical beats and clock time — clip lengths, splits, fades, recording placement, the playhead, offline rendering, some fifty-six sites in all — now routes through one new tempo-map engine instead of scattered per-site arithmetic. Nothing sounds different, and that's the point: the whole refactor was gated on rendering the same demanding project (odd 97.3 BPM tempo, MIDI, fades, a crossfade, automation, bus routing) before and after, and every output file — mixdowns, all stems, a bounce — came out SHA-256 byte-identical. The gate was then reproduced a third time from a fresh app session to rule out flukes. The real-time audio thread wasn't touched at all: all seventeen render-path files verified checksum-unchanged.
- A permanent lint test now fails the build if anyone reintroduces raw tempo arithmetic outside the map, so the foundation can't erode. With this in place, the next steps can make tempo actually change mid-song — the map does the math; the app just hasn't been allowed to author more than one segment yet. Suite: 1947 tests / 227 suites; npm 86/86; wire surface unchanged at 116 commands / 119 tools.

## 2026-07-11 — Sidechain gets its green light: the one open question is answered
- The sidechain design (kick-ducks-the-pad pumping) hinged on a single unproven assumption: that the audio engine can feed a second, analysis-only input into an effect. A dedicated engine experiment now answers yes on every count — the second input connects cleanly, delivers the key signal sample-for-sample in the same processing quantum (verified bit-exact over thousands of frames, using a signal designed so silence or cross-wiring couldn't fake a pass), fails with a clean recognizable error when nothing is connected (exactly what the fallback path needs), and survives the full torture sequence of disconnects, reconnects, and node teardown that crashed lesser graph code in the past. Two consecutive offline renders came out byte-identical, which is the property that keeps stem exports and bounces trustworthy once sidechain lands.
- The experiment ships as a permanent test suite so the engine can never quietly regress on it. With condition zero met, both sidechain implementation stages stay on the M12 schedule alongside the tempo map. Suite: 1936 tests / 225 suites; no app code changed.

## 2026-07-11 — Groove preset IDs are now genuinely unique (and M11 wraps)
- A subtle bug found during the quantize-panel work is fixed at the root: the built-in swing presets each get a deterministic ID, but the old derivation accidentally gave every `swing8` preset the *same* one — so anything keying those presets by ID (like a picker list) could show or select the wrong swing. The IDs are now derived collision-free, all 44 resolvable presets verified pairwise distinct, with a pinned regression test so the derivation can never silently change again. Good news uncovered along the way: the actual quantize engine always resolved built-ins by name, so no project or agent workflow ever quantized with the wrong groove — the bug was confined to the listed IDs themselves. Built-in IDs changed once with this fix; they're derived, never saved in projects, so nothing on disk is affected.
- This closes out the M11 milestone: quantize & groove UI, the visible undo-history panel, session markers, honest overlaps + crossfades, bounce-in-place, the tempo-map and sidechain design blueprints, and this fix. Suite: 1931 tests / 224 suites; wire surface unchanged at 116 commands / 119 tools.

## 2026-07-11 — Two big features get their blueprints: tempo changes and sidechain
- No new buttons today — instead, the two most-requested "pro" features that touch the deepest machinery got full engineering designs before a line of code is written. A tempo track (speed the song up at the drop, slow it for the outro) turns out to be safe to build: an audit of all 78 places the app converts between musical beats and clock time found that the real-time audio thread never does that math at all, so the change stays out of the most fragile code entirely. The design's first gate: with no tempo changes authored, the app must produce byte-for-byte identical audio to today — provably nothing regresses.
- Sidechain routing (the classic kick-ducks-the-pad pumping effect) got a design that keeps every honesty guarantee this app has earned: stems still sum exactly to the mixdown, and bounces stay byte-identical, even with a compressor keyed from another track. One open question gates the whole feature — a half-day engine experiment — and if it fails, the feature is parked rather than shipped compromised. Both designs land as reviewable documents in docs/research/, with implementation slated for the next milestone.

## 2026-07-11 — Bounce in Place: commit any track to audio in one step
- Right-click a track header and choose "Bounce in Place": the track renders offline — through its whole effects chain, exactly as it sounds in the mix — and lands as a new audio track right below it, with the original muted so the print takes its place. It's one undo step (undo brings the original back un-muted and removes the print; the rendered file stays on disk for redo), works on buses too, and never touches your levels: the mix before and after measures identical to the thousandth of a decibel. Perfect for freeing CPU from a heavy synth, committing a sound you've settled on, or prepping a stem to send to a collaborator.
- The print is bit-exact honest: the bounced file is byte-identical to what `render.stems` produces for the same track — verified twice with SHA-256 comparisons on independent scenarios (an instrument playing a MIDI phrase through an insert, and an audio track). Agents get the same power via `track.bounceInPlace` / `track_bounce_in_place`, with `muteSource` and `name` knobs and plain-language rejections (a bus-routed track tells you its signal already lives in that bus's stem). Suite: 1927 tests / 224 suites; wire surface 116 commands / 119 tools; Explain catalog: 63.

## 2026-07-11 — Overlapping clips stop lying to your ears, and crossfades arrive
- A real bug from the beta audit is gone: dragging one clip on top of another used to leave both silently playing — the overlap doubled in volume with no warning, no visual hint, nothing. Now a move that lands on another clip trims away the covered part (swallow a clip entirely and it's removed), all inside the same single undo step as the move itself, and importing audio onto an occupied lane follows the same rule. Measured, not assumed: the old behavior showed +6 dB in the overlapped span; after the fix the same span measures identical to a single clip, to two hundredths of a decibel.
- And when you *want* two clips to blend, that's now a first-class move: right-click an audio clip and choose "Crossfade with Next" (¼ to 2 beats) — the first clip fades out exactly as the next fades in, using equal-power curves that keep the loudness seamless through the join (measured spread across the seam: 0.03 dB). A little bowtie badge marks every crossfaded seam, undo removes the blend in one step, and agents get the same tool over the wire (`clip.crossfade`, plus `clip.move` now honestly reports anything it trimmed). Asking for a longer crossfade than the recordings can support gets a plain-language explanation instead of silence. Suite: 1908 tests / 222 suites; wire surface 115 commands / 118 tools; Explain catalog: 62.

## 2026-07-11 — Session markers: your song gets named places
- Songs have sections, and now DAW Pro knows their names. Drag on the empty ruler strip to drop a marker — Intro, Chorus, Drop, anything — then drag its flag to move it, double-click to rename it, and click it to jump the playhead straight there. Markers save with the project, undo like every other edit (a long drag counts as one step, not forty), and older projects open exactly as before. The flags live in their own lane under the loop bar, so loop dragging keeps working untouched.
- This one is squarely for the AI side of the house too: "drop at the second chorus" is now a two-call workflow — agents list the markers by name and beat, then seek to one directly by name or id (`transport.seek` accepts a marker now). Five new wire commands and MCP tools cover add, move, rename, remove, and list; the Copilot can use all of them; and asking for a marker that doesn't exist gets a helpful error, not a shrug. Verified live twice with independent scenarios, including proof that undoing a drag lands back exactly where the marker started. Suite: 1889 tests / 220 suites; wire surface 114 commands / 117 tools; Explain catalog: 61.

## 2026-07-11 — Your whole edit history, visible and walkable
- The app has always remembered your last hundred edits by name — but you could only ever see the next one, through the Undo menu item. A new HISTORY chip in the arrange toolbar opens a panel showing the entire list: everything you can still rewind below a cyan "YOU ARE HERE" marker, everything you've undone (and can replay) dimmed above it. Click any entry and the project walks there one honest step at a time through the same undo machinery ⌘Z uses — no shortcuts, no new ways to mutate your project, so nothing this panel does can ever corrupt an edit. Rapid knob scrubs still collapse into a single entry, so the list reads like a story, not a seismograph.
- Agents get the same superpower over the wire: a new `edit.history` command (and `edit_history` MCP tool) returns both labeled stacks in one call, newest-first, so an AI can see exactly what it — or you — just did and step anywhere in that history with plain undo/redo. Proven live twice over with independent scenarios: list order, scrub-coalescing, click-jumping three steps back with the project state verified to match. Suite: 1853 tests / 217 suites; wire surface 109 commands / 112 tools; the panel ships with its own "Explain this" card (catalog: 60).

## 2026-07-11 — The groove engine gets a face: quantize arrives in the app
- Until now, tightening a loosely-played part was something only an agent could do for you over the wire. A new QUANTIZE panel — reachable from a chip in the piano-roll header or by right-clicking a MIDI clip in the arrangement — brings it in-app: pick how fine the timing grid is (musical names like 1/8 and 1/16, triplets included), choose how strongly to pull the notes toward it, and apply. In Simple mode that's the whole story, deliberately. Pro mode adds swing, snapping note ends, and the groove picker: eight built-in MPC-style swing feels, any groove you've saved, and an "Extract from clip" button that lifts the timing feel out of one part so you can stamp it onto another. One press of Apply is one undo step, no matter how much you fiddled first.
- The panel is honest about who's in charge: choosing a groove takes over the grid and the swing, so the panel locks those controls and says so plainly ("set by the groove", "groove sets the feel") instead of letting you drag sliders that would do nothing. Six new "Explain this" cards teach the whole area in beginner language. And the guarantee that matters for an AI-native DAW held: the panel drives the exact same code path agents use, proven twice over — once by the implementing engineer and once independently with different settings, where the panel's result and the wire command's result came out identical to the last digit, on both a plain-grid quantize and a 1/16-swing groove. Suite: 1829 tests / 214 suites. One bug found along the way (two built-in swings sharing an internal id) is worked around in the panel, pinned by a test, and queued for a proper engine fix.

## 2026-07-11 — No more frozen launches: the app stops reading your Keychain before it even has a window
- Since the beta began, one launch in a while — especially right after an update — would hang forever with no window: the app was reading your stored API key from the Keychain during startup, and if macOS decided to ask permission first, the whole app sat behind a dialog that had nowhere to appear. Startup now touches the Keychain not at all: the window comes up, the agent connection comes up (measured: under a second, in the exact scenario that used to hang indefinitely), and the Settings panel then checks your keys in the background using a metadata-only peek that can never trigger a permission prompt.
- If a stored key does need macOS's one-time permission, Settings now says so honestly — "Key stored — macOS will ask for access the first time it's used" — and the prompt appears only when a feature actually uses the key, with the app fully visible behind it. Agents asking over the wire get the same honesty via a new `consentRequired` flag on the provider status. Fifteen new tests pin the rule that startup performs zero Keychain access. Suite: 1814 tests / 213 suites; MCP suite 84/84 — now run, for the first time, with no key-related workarounds at all.

## 2026-07-11 — The recovery prompt learns to take a hint
- The "Restore unsaved work?" prompt that appears after a crash had one blind spot: it only listened to its own two buttons. If the offer got settled any other way — an AI agent resolving it over the connection, or you simply starting a new project — the prompt stayed on screen anyway, offering work that was already dealt with. It now watches the actual state of the offer and dismisses itself the moment that offer is resolved from anywhere, with the same gentle fade the buttons use.
- Proven against the real thing: a genuine mid-session kill, relaunch, prompt up — resolved over the wire, prompt gone; same again with a new project. Six new tests pin the rule that the offer's availability can only ever arm at launch and drops at every path that consumes it. Suite: 1799 tests / 213 suites.

## 2026-07-11 — An honest look in the mirror: the pro-parity audit, plus two rough edges smoothed
- We audited DAW Pro against current Logic Pro and Ableton Live, feature by feature, grounding every claim in the actual code — the result is a ranked list of what a professional would miss first (docs/research/audit-m10q-pro-parity.md). Headliners: the groove engine is fully built but has no UI to reach it; the undo system already remembers a labeled history that no panel shows; and session markers don't exist yet, which matters double here because AI agents want named song sections to navigate by. The audit also caught a real bug nobody had reported: dragging two clips into overlap on the same track silently doubles the volume with no crossfade and no warning — now documented and queued.
- Two long-standing rough edges got fixed on the spot. The Sketchpad's "generator not running" banner used to tell you to "call ai.sidecarStart" — instructions meant for a machine; it now says, like a person would, "press Start to launch it" (agents on the wire still get the technical message, which is right for them). And asking for a plugin window on a sound-bank instrument no longer gets a confusing "built-in soundBank" refusal — it now explains that sound banks browse programs through the instrument picker instead. Suite: 1793 tests / 213 suites.

## 2026-07-11 — The AI clients grow up: official Anthropic and OpenAI SDKs replace hand-rolled HTTP
- The MCP server's lyrics and image generation now go through the official `@anthropic-ai/sdk` and `openai` packages instead of hand-written HTTP calls and JSON parsing — the standard-SDK directive, applied. Nothing changes from the outside: the same tools, the same anthropic-first key preference, the same error messages when keys are missing, and deliberately zero retries (pinned to match the old behavior exactly rather than silently inheriting the SDKs' retry policy). Suno is the honest exception: no official SDK exists, so that placeholder stays hand-rolled and its comment now says so.
- The real win is what came with the migration: the provider layer had no tests at all, and now it has twelve — including a regression pin for the subtle bug this project already met once, where a model's thinking blocks arrive before its text and a naive parser reads the wrong block. Error paths are proven to surface the provider's status and detail without ever leaking a key. MCP suite: 84/84. One environment note: the machine's npm config points at an unreachable corporate registry, so the two new packages were installed from the public registry and the lockfile now references it.

## 2026-07-11 — The instrument picker lands: browse a real library instead of memorizing program numbers
- Click the instrument chip on any track header or mixer strip and a picker opens with the whole library laid out: the built-in synths, the sound banks (the General MIDI bank drills into all 128 named programs organized by 16 categories, drum kit included, with the exact bank numbers shown for the curious), and every Audio Unit instrument on the Mac — all searchable. In Simple mode the same picker speaks beginner: the GM categories become "Instrument Sets" cards with examples ("Brass — e.g. Trumpet"), and the built-in list trims to the two easiest choices. Adding your own SoundFont is a button inside the picker, right where you'd look for it. Everything the picker does goes through the exact same code path agents use over the wire, so what you pick is always what an agent would see.
- Three new "Explain this" cards cover the picker, and the design holds its rules: cyan only on active states, violet nowhere (this is a library, not an AI feature), and a sound-bank instrument never grows a plugin-window button it couldn't honor — that button is structurally reserved for real Audio Units. The track-header chip stays deliberately tiny (a glyph; the full instrument name lives in its tooltip and on the mixer strip) so long track names keep their space. Verified with a nine-screenshot pixel review, including cross-checking the chip against the live project state over the WebSocket. Suite: 1793 tests / 213 suites; Explain catalog 53. With this, the instrument library milestone is complete end to end: engine, wire, and now the UI.

## 2026-07-11 — Real instruments arrive: the General MIDI bank plays out of the box, and SoundFonts are welcome
- MIDI tracks are no longer stuck on the built-in synths. The engine now hosts Apple's sampler and loads sound banks into it — starting with the General MIDI bank that ships inside every Mac: 128 named instruments from Acoustic Grand Piano to Gunshot, plus a drum kit, zero downloads, zero setup. Agents get the full flow today (list banks → browse named programs by category → set a track to "Trumpet — General MIDI"), your own .sf2/.dls files import into a central library with their preset names read straight out of the file, and everything persists in the project. The in-app picker UI is the next piece landing.
- The engineering held the line where it counts: not one line of new code runs on the audio render thread (bank loading happens off to the side, before an instrument is ever published to the graph), a missing or broken bank honestly reports failure and stays silent instead of quietly substituting a built-in, and the proof is spectral — the same MIDI phrase rendered through the built-in synth, the GM piano, and the GM trumpet measures as three genuinely different timbres, verified again live over the wire with a −21.8 LUFS trumpet mixdown. One trap was caught exactly where the design predicted it might hide: a sample-rate change silently wiped the sampler's loaded bank (degrading it to a test tone), and the fix reloads the bank inside the same guarded window every time. Suite: 1772 tests / 212 suites; MCP suite 72/72; 108 commands / 111 tools.

## 2026-07-11 — The Copilot's leash is yours now: choose how many rounds one reply may take
- The in-app Copilot works in rounds — read the project, think, make a batch of changes — and until now every reply was silently capped at eight of them. That cap is now a setting: Settings → Copilot explains the concept in plain words and takes any budget from 1 to 32, applying to the very next reply with no restart. Prefer tight, predictable answers? Set it low. Asking for a whole arrangement? Give it room. Out-of-range values are politely refused in the field, and even a corrupted stored value can only ever load as a safe in-range budget.
- Agents driving the DAW get the same dial per turn: `ai.copilotSend` accepts an optional `maxRounds` override (bounding only that reply — a caller limiting its own budget harms no one), and `ai.copilotState` now reports the effective limits so an agent can see its budget before spending it. The engine reads the budget once at the start of each turn, so changing the setting mid-reply can never tear a turn in half. Proven across three live launches: the default, a persisted choice surviving relaunch, and an out-of-range stored value clamping safely. Suite: 1714 tests / 206 suites; MCP suite 41/41.

## 2026-07-11 — The agent hookup comes out of the terminal: see, copy, and configure your connection in Settings
- Connecting an AI agent no longer requires knowing magic strings: Settings → Agent Connection now shows the live WebSocket address the app is actually listening on, with a one-click Copy button, and a port field that persists your choice (taking effect at next launch — changing it never yanks the connection out from under an agent mid-session). If the port came from the DAW_CONTROL_PORT environment variable, the panel says so honestly instead of looking broken, and the environment always outranks the in-app setting so scripted setups keep working unchanged.
- Agents get the mirror image: a read-only `app.connectionInfo` command (and matching MCP tool, the surface's third growth this milestone — 105 commands, 108 tools) reporting the bound URL, port, and which source chose it — useful for confirming which app instance a session is actually bridged to. Deliberately absent: changing the port over the wire, since config that can sever the caller's own connection is a human decision. Proven live both ways: one launch under the environment override, one launch genuinely binding a persisted port chosen in Settings. Suite: 1695 tests / 204 suites; MCP suite 29/29.

## 2026-07-11 — Bring your own sound: import audio from the File menu or drop it straight onto the arrange
- The DAW finally accepts your files the way every other app does: File → Import Audio… (⌘I) opens a multi-select picker, and dragging audio from Finder onto the arrange shows a cyan lane highlight with a snapped drop-line right where the clip will land. Drop one file on an audio lane and it joins that track; drop it anywhere else — or drop several files at once — and each becomes its own new audio track, named after its file ("Kick Drum.wav" → a track called "Kick Drum"), all starting at the same snapped beat so stems line up by construction. A multi-file import is exactly one undo step, and a corrupt file in the batch reports its own error without sinking the rest.
- Both entry points funnel through one shared, headless-tested pipeline (25 new tests; suite now 1673 in 202 suites), and the live gate proved the full story end-to-end: a three-stem drop fanned out to three correctly-named tracks with waveforms drawing at bar 2, one undo removed all three, and a garbage file imported alongside a good one hurt only itself. One honest note: the open panel and real pointer drags can't be driven over the wire, so the gate drives the identical execution path through a staging command — the thin panel/drop glue was verified by review.

## 2026-07-11 — The window learns its limits: a measured size floor and an arrange view that scrolls instead of shoving
- The window now refuses to shrink past the point where its controls stop fitting (a floor measured from the actual chrome, not guessed), and the track area — sidebar and timeline together, as one pixel-locked unit — scrolls vertically when tracks outgrow the space. The old failure where tall rows times many tracks would shove the transport bar or title row offscreen is structurally gone: verified at the exact floor with eight maximum-height tracks, every control visible, the overflow neatly contained in the scrolling region.
- This closes the layout debts earlier items deliberately parked: the adjustable-panels overflow edge, and the crowded take-group rows at the narrowest sidebar (their automation toggle now folds into the right-click menu below 300 pt, keeping names readable; the toggle relocates, never disappears). One honest note: the bar-number ruler scrolls with deep content rather than staying pinned — pinning it safely needs a fragile scroll-sync we chose not to build this round. Suite: 1648 tests / 200 suites.

## 2026-07-11 — Track headers grow up: names that never vanish, double-click rename, and an ADD button that says so
- Track names now win the fight for space: at any sidebar width the name stays readable — the level meter compresses to a slim floor, the clip-count badge folds into the hover tooltip on narrow sidebars instead of crowding the title, and long names truncate with the full text a hover away. Double-click any track name (or right-click → Rename Track) to edit it inline — Return commits, Escape cancels, empty input safely does nothing, and a real change is exactly one undo step. The lone `+` became a labeled `+ ADD` menu offering Instrument, Audio, or Bus tracks, and an empty project now shows a proper ADD TRACK button — answering the beta question "or is it AI-only?" for good.
- The first cut of this fix guaranteed the name a hard minimum width — and the verification captures caught it re-inflating the window's minimum size at the narrow extreme, the same trap the adjustable-panels work hit and measured its way out of. Round two made the name soft (layout priority instead of a floor), so the row can never push the window around; the width budget is headless-tested. Suite: 1641 tests / 199 suites.

## 2026-07-11 — Remove a measure and the music closes ranks: delete/insert bars lands everywhere at once
- The piano roll's header grows a small BAR cluster: press − to remove the bar under the playhead (everything after slides left to close the gap), + to insert an empty one (everything after makes room). The note surgery underneath is precise and documented — notes reaching into a cut keep the parts that survive it, notes starting inside it are removed, and a note sustaining across an insertion point simply keeps sounding through it. Each operation is exactly one undo step that restores the previous state note-for-note, the delete button refuses to hollow a clip below one bar, and the whole cluster shows in Simple mode too — removing a measure is not an expert move.
- This is the first M10 item to grow the control surface: agents get the same primitive via `clip.deleteTimeRange` / `clip.insertTimeRange` (and matching MCP tools), general to any beat range, with the wire deliberately more permissive than the UI (a full-length delete clamps the clip to its floor rather than erroring). Proven live twice over: an orchestrator gate asserting the exact surviving note set through delete → undo → redo → re-insert (nothing resurrected), and a second independent round trip through the compiled MCP server. Swift suite: 1633 tests / 197 suites; MCP suite grows to 24.

## 2026-07-11 — The ruler learns to loop: drag a cycle region right where the bars live
- The arrange ruler — previously a purely decorative strip — is now the loop's home: drag across it to sketch a cycle region (snapped to the bar in Simple, to your picked grid in Pro), drag either edge to resize, drag the middle to slide the whole region, click inside to toggle looping on and off, and click anywhere else on the ruler to jump the playhead there. The region draws as a slim cyan band above the bar numbers — glowing when looping is live, a faint outline when parked — with the transport bar's LOOP chip staying in perfect sync, and every affordance advertising itself through the hover-cursor system.
- All the drag math lives in a headless, fully tested model (leftward drags produce valid regions, edges clamp rather than flip at their opposite edge, moves clamp at zero preserving length — 19 new tests, suite now 1604 in 194 suites), and agents get the same picture humans do: setting or moving the loop over the wire relocates the band instantly, verified live with the region landing exactly on its predicted bar lines. A small honesty note: a fresh project shows the default 0→16 region as a faint outline rather than nothing, because that region is real state — it's what the LOOP button would loop.

## 2026-07-11 — Clips show their sound: every MIDI clip draws its notes, audio never reads blank
- The beta complaint "clips look blank" is closed. Every MIDI clip in the arrange now draws a mini note map — pitch-mapped pills, higher notes toward the top, each pill at its exact beat position and clamped to the clip's edge — so you can see where the melody sits without opening the editor. It works in both Simple and Pro (seeing your content isn't an edit feature), scales across the full adjustable row-height range, and AI-generated clips stay violet automatically. Take lanes now share the identical renderer, so a clip and its takes can never drift apart visually.
- Audio clips already drew waveforms; the fix there is honesty at the margins — while a file's peaks are still loading (or the file can't be read), the clip shows a dim center line instead of nothing. Verified deterministically over the wire: four known notes landed exactly at their predicted pixel rectangles (including the edge-clamp case), and a real mixdown dropped onto an audio track rendered its waveform live. Suite: 1585 tests / 193 suites.

## 2026-07-11 — The melody editor gets its playhead: see the transport, grab it, scrub it
- The piano roll now shows the same glowing cyan playhead as the arrange timeline, mapped into the edited clip's own beats and drawn straight through the note grid and velocity lane — and only while the transport is actually inside that clip, so its absence tells you something true. Click or drag in the strip along the editor's top edge to jump or scrub the transport freely (unsnapped, the pro default), while stopped or during playback, with the resize cursor advertising the gesture.
- Built as a pure rendering of existing transport state (no new commands — agents already have `transport.seek`), with the beat mapping and visibility rules headless-tested, and the note grid restructured so transport ticks move only the playhead line rather than redrawing the grid every frame. Verified deterministically: seeks over the wire put the line exactly at the left edge of a note known to start at that beat, and a seek past the clip removes it. Suite: 1574 tests / 192 suites.

## 2026-07-11 — The workspace becomes yours to shape: draggable splitters, resizable track rows, and it all persists
- Three layout dimensions are now mouse-adjustable and remembered across launches: the track sidebar width (drag the splitter between headers and timeline), the editor height (drag the piano roll's top edge), and the track row height (drag the bottom edge of any track header — every row and its timeline lane scale together, verified pixel-aligned even at the 64-point maximum). Splitters are hairlines that glow cyan only when your pointer finds them, and every one carries the correct resize cursor from the pointer-affordance work.
- The allowed ranges are honest by measurement, not guesswork: the first cut permitted layouts that pushed the app header and transport bar clean off the window, so the sidebar minimum was re-derived from the track row's actual intrinsic width (measured 242–267 pt → floor 250) and the editor capped at 55% — verified by a full capture matrix at the extremes. Remaining edge (many tall rows can still nudge the title bar) is owned by the upcoming small-window adaptivity item. The gate also flushed out two unrelated bugs now filed: the crash-recovery sheet doesn't dismiss when an agent resolves the offer over the wire, and app startup can hang invisibly on a Keychain consent prompt before the window exists. Suite: 1569 tests / 191 suites.

## 2026-07-11 — The pointer now tells you what you can grab: hover cursors land on every drag surface
- Every existing interactive surface advertises its controllability the moment you hover it: clip bodies show a grab hand (closing while you drag), trim edges and fade grips show horizontal resize arrows, the clip gain chip and every fader/velocity stem show vertical resize, piano-roll notes grab and their right-edge resize handles show arrows, automation breakpoints grab with a crosshair over empty lane space, and take lanes show the paint crosshair. The cursor holds correctly for the whole drag even when the pointer leaves the control, and the implementation (a hit-test-transparent tracking overlay that only ever sets, never stacks) makes the classic stuck-cursor bug structurally impossible.
- The cursor-per-affordance conventions are now written into the design language ("Pointer affordances") so every future control follows them, with the decision logic headless-tested (suite grows to 1557 tests in 190 suites). One deliberate non-change: track headers got no grab cursor because they aren't draggable yet — that arrives with the adjustable-layout item (m10-d) rather than advertising an interaction that doesn't exist.

## 2026-07-11 — The sidecar Start button now tells the truth: live progress, honest status, and a second root cause fixed
- The beta bug had a second layer beyond the launcher fix: once `ai.sidecarStart`'s 30-second window expired, the app forgot it had ever started the sidecar — every status poll then claimed "installed but not running" while models were still legitimately loading. The manager now tracks the boot for its whole lifetime (surviving even an app relaunch mid-boot via the pidfile), keeps reporting a truthful "starting" with elapsed seconds and a human phase hint read from the sidecar's own log ("preparing environment…", "loading models…", "starting server"), and distinguishes a genuinely dead boot ("boot likely failed — check the log") from one that's merely slow. A real spawned-process regression test pins the exact beta scenario; the suite grows to 1545 tests in 189 suites.
- The Sketchpad banner now shows a cyan spinner with "Starting — loading models (42s)"-style live progress and an in-progress STARTING… button instead of a dead control, polling faster while the boot is underway. Verified end to end with a real cold boot watched from a second connection — every in-flight poll reported "starting" (never the old false "not running"), and thanks to yesterday's launcher fix the boot reached healthy in 3.7 seconds. Both banner states pixel-reviewed. With this, both halves of the beta sidecar bug are closed.

## 2026-07-11 — Explain→Copilot hand-off proves out live: hover any control, ask the AI about it, get a real answer
- The last piece of the "Explain this" feature passed its live gate: the exact question the explain card's "Ask the Copilot →" button prefills ("Explain Punch Recording — what should I do with it here?") went through the rail against the live Anthropic API and came back as a genuinely useful beginner answer — what punch-in/punch-out recording is, how to prep the session for it (loop range, count-in, pre-roll), and the honest boundary that hitting record stays a human action in the app. The copilot made zero tool calls and the project state was verified untouched before/after; it even described the current project's tracks accurately purely from its built-in per-round context, with no key material anywhere.
- With ex-c closed, the "Explain this" parent item completes. M8 now has only the OpenAI-key-blocked image-asset item (glass-b) remaining, so development moves to the M10 beta-feedback backlog next. One tooling lesson banked for future gates: the control protocol's JSON key order isn't stable between calls, so state-identity assertions must compare canonicalized structure, not raw bytes.

## 2026-07-11 — The Copilot passes its real-conversation gate: M6, the AI suite, is complete
- The in-app Copilot held its first real conversation against the live Anthropic API and drove actual project edits end-to-end (the rail-e gate, run twice over the wire on the staging port): "Add an instrument track named Neon Bass, and set the project tempo to 100 BPM" produced exactly `track.add` + `transport.setTempo` — verified in the project overview, one track, tempo 100, nothing else touched. The second turn, "Now mute that track," proved genuine agency: the copilot re-oriented itself with `project.snapshot`, resolved the pronoun from conversation history to the correct track UUID, and issued `track.setMute`. Twelve of twelve checks passed, with zero key material anywhere in the transcript.
- With this, the Copilot rail parent item closes and **M6 — the AI suite — is fully complete** (generation, import, stems, vocal repaint, take alignment, lyrics workshop, and the copilot rail, all real-gated; the Suno cloud fallback stays dormant by design). One cosmetic model quirk recorded honestly: the first turn's closing message imagined a pre-existing duplicate track — the edits themselves were exact. Next up: the explain→copilot live hand-off gate (ex-c).

## 2026-07-11 — AI provider parsing fixed at the root — and the first REAL AI lyrics land through the Keychain key
- Fixed the beta-reported "could not parse provider response: missing content[0].text" failure across every Swift provider client. The root cause: the Anthropic parser assumed the first content block is text, but modern models (the default `claude-sonnet-5` included) emit `thinking`/`tool_use` blocks first — and API error envelopes hit the same guard, masking real errors (rate limits, overload) behind the same misleading message. Now ALL content blocks are parsed (every text block collected, thinking/tool-use tolerated), vendor error envelopes surface their own `type: message` verbatim, and the OpenAI client handles null/array-of-parts content plus refusals. Ten new regression fixtures pin every shape — suite grows to 1530 tests in 186 suites. (No official Anthropic/OpenAI Swift SDK exists, so schema-complete parsing IS the standard here; the TypeScript mcp-server already parsed correctly, and migrating it to the official SDKs is filed as m10-o.)
- Proven against the live API, not just stubs: with the beta user's Anthropic key in the Keychain, a real `ai.writeLyrics` round-trip returned well-formed bracketed [verse]/[chorus] synthwave lyrics in 5.3 s (7/7 gate checks) — which also satisfies the M6 Lyrics-workshop real-key gate verbatim, closing that milestone box. The Copilot rail (rail-e) and explain-handoff (ex-c) live gates are now unblocked next. Note for the beta user: the installed app must be rebuilt (`scripts/bundle.sh`) and relaunched to pick up the fix — the running instance predates it.

## 2026-07-11 — Beta feedback round 1 begins: user guide + feature matrix land, and the sidecar start bug is fixed
- The first real beta session produced a full feedback round, now triaged as roadmap milestone M10 (18 items). First deliverables: `docs/USER-GUIDE.md` — a beginner-readable walkthrough of the whole app including how to hook up an AI agent over MCP (WebSocket URL, port override, server registration) — and `docs/FEATURES.md`, a ~200-entry status matrix that is honest about what's still wire-only (track rename, loop region) or not yet built (MIDI CC, master FX chain).
- Fixed the "sidecar did not report healthy within 30s" failure at its root: the launcher re-resolved Python dependencies on every start, and a TLS-intercepted `flash-attn` metadata fetch could kill the boot before the server existed. `run.sh` now runs `uv run --no-sync` whenever the installed environment is present — verified by a live offline boot to a green `/health`. Log audit found no other real issues (the MPS flash-attention and bitsandbytes warnings are benign fallbacks).

## 2026-07-10 — Autosave hygiene: untitled-recovery bundles now age out instead of accumulating forever
- Root cause corrected along the way: the `Untitled-*.dawproj` pile-up in the Autosave folder (114 bundles) was never the retired legacy autosave writer — it's the still-live, intentional `flushForTransition()` data-safety path, which writes one recovery bundle per dirty untitled session abandoned via new/open but only ever cleaned up its own slug. New `ProjectStore.pruneUntitledRecoveryBundles(keep: 5)` runs at every app launch: newest-by-modification-date retention, matches only true `Untitled-*.dawproj` bundles (decoys untouched), never deletes the live session's own bundle, and tolerates missing directories and bundles held open elsewhere.
- Two regression tests pin the retention policy and its edges — suite grows to 1520 tests in 184 suites, zero warnings. Verified live on the staging port: four seeded over-cap fakes were pruned at launch with exactly the newest five real bundles surviving, and the one-time backlog sweep took the real folder from 114 bundles to 5 (crash-detection `session.lock` preserved). This was the last unblocked work item — everything now remaining on the roadmap waits on API keys or Apple Developer credentials.

## 2026-07-10 — M3 (vi-b-2): plugin windows show the real plugin — the vendor-view ladder lands, and M3 is complete
- Plugin windows now resolve the actual vendor UI instead of always falling back to the system parameter list: a never-failing three-step ladder tries the modern `requestViewController` (raced against a 5-second once-gate timeout so a broken extension can never wedge the app), then the classic v2 Cocoa view protocol via a new headless-testable `AUViewProbe` in the engine, then the generic parameter view as the guaranteed floor. Proven live on both branches with system units: AUDelay and DLSMusicDevice open their real custom views — Apple Delay's tap-graph editor rendering inside our glass chrome at the vendor's own preferred size — while AUMatrixReverb (which ships no custom view) cleanly falls back to generic. Windows now follow vendor self-resizing with a reentrancy guard and stay clamped on-screen.
- Verified end to end: suite grew to 1518 tests in 184 suites (probe tests pin the CF memory contract against real units), npm stays 19/19 with the command/tool surface unchanged at 102/105, and the live gate passed on both the bare dev binary and the installed-style `dist/DAWPro.app` bundle identity. One honest gap recorded rather than papered over: no AUv3 exists on this machine, so the out-of-process AUv3 leg is skipped by necessity — the ladder's design guarantees graceful degradation if one ever misbehaves. With this, **M3 (MIDI & instruments) is fully complete**; every milestone M0–M9 is now done except items blocked on API keys or Apple Developer credentials.

## 2026-07-10 — M3 (vi-b-1): plugin windows are real — AU instruments and effects open in floating glass-chrome windows, driven from the UI or the wire
- The live, sounding `AUAudioUnit` instance now reaches a floating window: narrow main-actor accessors on the concrete engine (a documented one-off exception to the no-AudioToolbox-on-the-surface rule), a registry release callback as the single window-invalidation authority, and an `NSPanel` layer with dark-glass chrome (title, "Track · Manufacturer" subtitle, cyan key-accent — never violet) wrapping Apple's generic parameter view. Windows close themselves the moment their plugin leaves the model — effect removed, instrument switched, project opened — and deliberately survive engine crash-recovery, which never touches the plugin registry. This cycle ships the always-works generic body; vendor custom views (requestViewController / v2 Cocoa UI) are the next cycle.
- Fully agent-drivable: `plugin.openUI` (pin a window at exact screen coordinates, get the actual frame back for captures), `plugin.closeUI` (idempotent), `plugin.listOpenUIs` (honest `available:false` when headless) — 102 commands, 105 MCP tools. Suite grew to 1515 tests in 183 suites, including pins that the accessor returns the identical sounding instance and that recovery fires zero release callbacks. Both the implementing agent's gate (17698) and the orchestrator's independent gate (17695, 15/15) proved the full lifecycle live against DLSMusicDevice and AUDelay, including the auto-close-on-`fx.remove` proof with no close command issued. One real bug found during the gate and fixed: the transparent-titlebar panel's safe-area inset pushed the chrome's subtitle row out of its 34-point band — the header now ignores the safe area.

## 2026-07-10 — M9 (beta): one button turns a bug report into evidence — the beta feedback loop closes out M9's unblocked work
- A headless `DiagnosticsReporter` (DAWCore, injected directories + clock like the autosave manager) writes a single local folder — never a zip, never a network call — containing everything a bug report needs: app/OS/hardware manifest, the current engine watchdog + performance snapshots (the M9 telemetry paying off as evidence), a counts-only project overview, and copies of recent `DAWApp` crash logs (14-day window, newest 10). The full project bundle is included only on explicit opt-in, and nothing anywhere near the bundle reads key material — verified by scan on a live bundle. Reachable three ways: `app.feedbackBundle` on the wire (99 commands), `app_feedback_bundle` over MCP (102 tools — with guidance telling agents to ask before sharing project content), and a cyan "Beta Feedback" row in Settings that saves and reveals the folder in Finder.
- New `docs/BETA.md` tells testers how to install the DMG, what to expect on first launch (fresh prefs domain, mic permission, sidecar env var for installed copies), what's knowingly missing, how to report, and the privacy stance: everything stays on the Mac. Suite grew to 1492 tests in 180 suites; npm 19/19 at the new pins; the live gate created both bundle variants over the wire and inspected every file on disk. With this, every M9 item that can proceed without Apple Developer credentials is done.

## 2026-07-10 — M9 (pkg-d): DAW Pro ships as a disk image — scripts/dmg.sh builds the drag-to-install DMG
- One script on top of the bundle: `scripts/dmg.sh` rebuilds the app (idempotent), stages it beside an `/Applications` symlink in the standard drag-to-install layout, and produces a compressed `dist/DAWPro-0.1.0.dmg` with its SHA-256 printed for release notes. The version is read from the built bundle's own Info.plist, so bundle.sh stays the single source of truth.
- Verified as a real install, not just a file: mounted the image, copied the app out, confirmed the ad-hoc signature still verifies on the copy, launched the installed copy with the full control surface round-tripping, and quit it cleanly by name with the crash-recovery session lock removed. The gate also pinned a subtlety into the packaging docs: the song-generation sidecar's directory walk-up resolves from the process working directory too, so only a true Finder launch shows the pure installed-copy behavior. Cross-machine distribution still carries the Gatekeeper right-click-open caveat until real signing lands (credential-blocked pkg-b/c).

## 2026-07-10 — M9 (pkg-a): DAW Pro is a real Mac app now — scripts/bundle.sh builds an ad-hoc-signed, LaunchServices-registered DAWPro.app
- One script turns the release build into `dist/DAWPro.app`: proper Info.plist (bundle id `dev.dawpro.app`, version 0.1.0, minimum macOS 14, the microphone-permission string a bundled app needs for recording, music app category), ad-hoc code signature that verifies cleanly, and LaunchServices registration. The executable inside keeps its `DAWApp` name so every existing process-management and gate script keeps working, and the bundled binary still honors `DAW_CONTROL_PORT` — the full control surface (including the new crash-recovery and watchdog commands) round-trips through the bundle unchanged.
- The registration pays off immediately: `quit app "DAW Pro"` by name now drives a genuine AppKit termination — verified live, the crash-b session lock is removed on quit — giving orchestrated sessions their first clean programmatic exit (previously only SIGKILL/SIGTERM were scriptable, both of which correctly read as crashes). Known and documented rather than papered over: no icon yet (asset generation is key-blocked), Finder launches use a fresh preferences domain, a copied bundle needs `DAWPRO_ACESTEP_DIR` to find the song-generation sidecar, and Gatekeeper on other machines wants right-click-open until real signing (pkg-b/c, credential-blocked) lands. New docs/PACKAGING.md carries the details; Developer ID signing, notarization, and auto-update are recorded under ## Blocked with their exact unblock path.

## 2026-07-10 — M9 (crash-c): the engine can no longer die silently — a heartbeat watchdog detects render-side stalls and drives the proven recovery path
- A tick-driven watchdog now watches the render heartbeat (the lifetime callback counter from the performance telemetry — read with a single atomic load, never touching the render thread). If the heartbeat freezes for two consecutive 2-second checks while the engine claims to be running, the watchdog declares a stall and restarts the engine through the exact same recovery routine the system's configuration-change path has always used — extracted verbatim, not copied — so the playhead resumes where it was, the crash-a pending-detach bin still flushes, and the mix settings come back. Three consecutive failed recoveries put it in a sticky `failed` state rather than retry-thrashing; the next successful engine start re-arms it. One subtle catch during implementation improved the design: the watchdog only arms when the graph actually has strips producing telemetry — an empty running session has no heartbeat by physics, and would otherwise have restart-looped forever.
- The state is readable anytime as `engine.watchdogStatus` / `engine_watchdog_status` (98 commands / 101 tools): `ok` with an advancing heartbeat means healthy, `restartCount > 0` means the engine died and healed itself, `failed` means manual attention. The live gate showed the whole story on the wire: idle and zeroed before the engine exists, `ok` with the heartbeat climbing during playback, and still climbing after transport stop — the live-thru law, now visible to any MCP agent. Suite grew to 1479 tests in 178 suites, including a device-gated end-to-end restart test that ran live.

## 2026-07-10 — M9 (crash-b): the app can no longer lose work to a crash — rolling autosave, crash detection, and a recovery offer in-app and over the wire
- A headless `AutosaveManager` (DAWCore, injected directory + clock) keeps one rolling `autosave.dawproject` snapshot plus a manifest, written on a 30-second tick only when a new journaled edit has landed — encode on the main actor, file write off it, zero added latency on the edit path, and never touching the user's own file. A `session.lock` written at launch and removed only by a genuine in-app quit makes crash detection honest: SIGKILL and real crashes leave the lock, and the next launch offers recovery — in-app as a neutral-glass cyan sheet ("Restore unsaved work?"), and over the wire as `project.recoveryStatus` / `project.recover {accept}` with matching MCP tools (97 commands / 100 tools). Accepting restores the crashed content under its original IDs, kept dirty, with the source path preserved so the next save lands on the right file; declining, saving, opening, or starting a new project permanently retires the offer.
- The independent live gate (real 30-second timer, real SIGKILL, real relaunches) proved the happy paths — and caught two real bugs plus one false belief, all fixed with regression tests before close (suite 1458/174). The bugs: an unresolved offer could be silently overwritten by the live session's own next autosave (wire edits bypass the launch sheet; the writer now parks until the offer is resolved), and a resolved offer could re-arm later in the session once a fresh autosave landed (resolving now spends the crash-detection latch). The false belief: SIGTERM/pkill does *not* route through AppKit termination — it dies like a crash, which is in fact the safer reading, since nothing saves on the way down; the docs now state the verified behavior and orchestrator sessions quit via the quit Apple event or normalize stale offers at start.

## 2026-07-10 — M9 (crash-a): the teardown crash is dead — root-caused with a six-experiment live matrix, fixed with a pending-detach bin
- The long-parked killer (play a big routed session, open a new project, add a track → hard crash inside AVFoundation's graph bookkeeping) is fixed, and the root cause was proven rather than guessed: AVFoundation only completes a node detach's internal bookkeeping when it can synchronize with a running engine. Detach a node that has ever rendered while the engine is stopped and a stale raw pointer stays behind in the engine's internal node list — surviving reset and restart, immune to disconnect-first — until the next live connect walks it into freed memory. Our project-new teardown hit exactly that: the routing-safety hook stops the engine at the first strip with bus wiring, so the mass detach of a routed session ran against a stopped engine. The pivotal experiment inverted the original theory — stopping *before* all detaches (the by-the-book reading of the old discipline) still crashed, while running the entire 28-strip teardown against a live engine was clean. The discipline's stop, safe for rewires, was the poison for detaches.
- The fix is a pending-detach bin mirroring the codebase's retire-bin philosophy: teardown detaches now execute only against a running engine; requests arriving while stopped park the node — still attached, still strongly held, so no freed-memory window can exist — and flush in order right after the engine next starts. Offline renders and headless tests are byte-identical (their engines never ran). The same seam quietly covers three latent windows of the same class that a spot fix would have missed, and the architecture docs now carry the lifetime rule as law.
- Proven dead twice over: the implementing agent ran the full 41-track repro three times on the fixed build (previously crashed every time; five fresh crash reports were banked during diagnosis), and an independent gate ran three consecutive teardown cycles in a single process plus post-churn playback and undo checks — five for five, zero new crash reports. Suite grew to 1437 tests in 172 suites with four deterministic ordering pins standing guard where the live crash itself can't be reproduced headless.

## 2026-07-10 — M9 (perf-d): the performance counters are now exact under concurrency — and the fix turned the telemetry into a glitch detector
- The render-load counters switched from read-then-write increments to true atomic fetch-adds (plus a bounded compare-and-swap maximum for the peak-callback cell) — still lock-free, still allocation-free, still a single instruction on Apple Silicon, and now provably exact no matter how many threads feed them. The regression test spawns eight threads hammering 160,000 recordings and demands bit-exact totals; the implementing agent went further and temporarily reverted the fix to show the old code drops 45% of counts under that load, then restored it. The invariants section in ARCHITECTURE.md now blesses "multi-producer accumulator" as the third sanctioned pattern for crossing data out of the render thread.
- The fix promptly earned its keep by correcting our own story: re-running the 16-track debug-build experiment with trustworthy counters produced the same "low" callback rate as before — meaning those missing callbacks were never counting errors but real dropped audio cycles (a debug build genuinely can't render 16 dense synths inside the hardware deadline, and CoreAudio skips late cycles). Pure live playback turns out to be single-threaded after all; the real concurrency the counters needed to survive is a live graph and an offline bounce running at once, which the earlier profiling had directly observed. Both research docs were corrected accordingly.
- Net effect: comparing the measured callback rate against blocks × device rate is now an honest, wire-visible saturation detector — if it reads low, the engine is audibly glitching, full stop. Release builds pass that check at every scale tested. Suite grew to 1433 tests; the release build re-profiled identically after the change (no cost to the hot path); MCP surface untouched.

## 2026-07-10 — M9 (perf-c): the load-profiling pass — the engine has massive headroom, and the measurement found two real bugs anyway
- The verdict from driving a 41-track synthetic monster over the wire (37 dense saw synths with full FX-preset chains, three FX buses fed by sends from every track, and 128 automation points per synth): on a release build the whole engine uses about 14% of one CPU core, the slowest single render callback stayed under 1% of its real-time budget, not one budget overrun fired, and a 30-second offline mixdown rendered in 1.3 seconds — nearly 23× faster than realtime. There is no DSP hotspot to optimize at this scale; these numbers are now the documented regression baseline. The sharpest practical lesson: the same session on a debug build reads ~28× slower per block and bounces at a third of realtime — all future performance measurement happens on release builds, no exceptions.
- The pass earned its keep by finding two real defects, neither in the audio math. First, the brand-new telemetry undercounts under load: AVAudioEngine renders independent tracks on a thread pool, so the counter design's single-writer assumption loses increments when callbacks overlap — provable on debug at 16 tracks, where the counters reported 43% of the true callback rate while the vibe-meter analysis proved every track was sounding. That fix (a proper atomic fetch-add) is split out as its own roadmap item. Second, the long-parked teardown crash finally reproduced with a complete symbolicated stack: play a big routed session, open a new project, add a track — crash inside AVFoundation's graph bookkeeping on a stale node pointer. The exact wire repro and analysis leads are written up for the crash-safety work.
- Also documented for every future harness: the expected-callback-rate arithmetic that catches undercounting (blocks × the output device's pull rate — the device's 44.1 kHz, not the graph's 48), the fact that instrument tracks render their FX chains inline (one telemetry block per synth track), and that offline renders pull 4096-frame slices. Docs-only change to the repo; verified by the campaign itself (three harness scripts, both build configurations, cross-checked against the tap-based master analysis, which is immune to the counter race).

## 2026-07-10 — M9 (perf-b): the engine can now report its own render load — telemetry lands as `engine.performanceStats`
- Every render callback in both of the engine's real-time workhorses — the instrument source nodes and the per-strip effect-chain hosts — now stamps its wall-clock cost into a preallocated block of lock-free atomic counters, giving the DAW (and any AI agent over MCP) a live answer to "how hard is the audio engine working": callback and frame counts, accumulated and peak render time, budget-overrun count, an average load over the window, and a ~1-second "load right now" figure. The chain-host stamp starts only after upstream audio has been pulled, so nested renders are never double-counted, and offline bounces feed the same counters — headless profiling works without ever opening the app.
- The instrumentation is the first new engine code written under the RT-safety invariants that (perf-a) codified, and it conforms exactly: one heap allocation, integer-only math on the render thread (plus a single guarded floating-point smoothing step), release/acquire publishing, and no allocation, locks, or trapping division anywhere in the hot path. One new sanctioned exception was added to the invariants list for its single-writer counter pattern. Reset is windowed for profiling: asking for stats with reset returns the closing window and starts a fresh one, and the two windows tile exactly — the seam (perf-c)'s load-profiling pass will read before and after every experiment.
- Surfaced end to end as the first `engine.*` control command plus a matching `engine_performance_stats` MCP tool, with sixteen new tests including a headless end-to-end proof (a one-second offline render produces exactly the expected callback and frame counts). Verified independently: build clean, suite grew to 1432 tests in 171 suites, MCP tests all green at 95 commands / 98 tools, and a live wire session watched real playback push the counters — about 7% average load on an eight-track pop session — then exercised reset windowing and confirmed sane behavior after stopping. Next: (perf-c) — drive a deliberately heavy session over the wire and use this telemetry to find and fix the hotspots.

## 2026-07-10 — M9 (perf-a): the render thread comes back clean — 47 sites audited, zero violations
- M9 opens with proof of the discipline the engine was built under: a line-level audit of every site that executes on or feeds the real-time audio path — render callbacks for all five instruments and nine built-in effects, AU hosting adapters, the PDC ring, automation, every tap closure, the CoreMIDI receive path, the vibe meter's analyzer, stretch bridging, the recording writer, and all seven atomics patterns. Verdict: zero violations. Nothing on the render thread allocates, locks, hops actors, or touches files; the atomics carry correct memory orderings throughout.
- The audit leaves two durable artifacts: a findings document with a per-site verdict table (including six "watch" items that are sound today but fragile if copied carelessly — one is a dead graph-teardown function that would recreate an old segfault class if ever wired live), and a new RT-safety invariants section in ARCHITECTURE.md codifying the two-tier rules, the two sanctioned patterns for crossing state into the render thread, and the complete four-item exception list. Future engine work gets reviewed against that section. It also recorded a concrete lead for the parked teardown crash (a deinit ordering that leans entirely on an AVFoundation guarantee) for the upcoming crash-safety work.
- Docs-only change: build clean, suite holds at exactly 1416 tests in 168 suites, and the findings were spot-checked against code from earlier cycles. Next: (perf-b) — RT-safe render-load and xrun telemetry surfaced as an engine.performanceStats command and MCP tool, the measurement seam the actual profiling passes will read.

## 2026-07-10 — M8 (ob-c): the first-song gate passes for real — onboarding is COMPLETE
- The whole promise, proven live on a fresh profile with zero staged shortcuts on the task steps: the tour offered itself on first launch, the local ACE-Step engine cold-booted and generated a real 30-second lo-fi song from the tour's own suggested prompt, the import advanced the tour, and then playing, nudging the tempo, moving a fader, and bouncing the finished mix each advanced exactly their own step — ending with an 11.8 MB WAV on disk and a "completed" state that survived killing and relaunching the app without re-offering the tour. Sixteen of sixteen checks passed, on the full generation path (the template fallback was never needed).
- That closes the "Onboarding: first-song-in-10-minutes guided flow" roadmap item — design, headless model, guided UI, and live gate all landed and independently verified. M8 is now complete except its two key-blocked gates (GPT-Image assets and the explain-to-copilot live conversation), which wait on API keys alongside the other parked items. Next: M9 — performance, stability, and release engineering.

## 2026-07-10 — M8 (ob-b): the guided tour is on screen — coach-mark cards, real-deed detection, and two new buttons
- The first-song tour now greets you: on a fresh profile a centered glass card offers "Your First Song," and each task step then anchors beside the actual control it teaches — a glowing cyan ring around Play, around a fader, around the Sketchpad — flipping out of the way near screen edges and never covering what it points at. The chrome is deliberately non-violet (this is product guidance, not AI; cyan is the only accent), progress reads as seven dots plus a plain count, and Skip step / Skip tour are always one quiet click away. Finished or dismissed tours never nag again; Settings gains a "Replay tour" row.
- The tour advances on real accomplishments, detected app-side by an observing adapter rather than scattered button hooks: the store now publishes a tiny edit event (with the undo journal's own label and key) and a render-completion counter, and a tested classifier sorts edits so a fader move reads as mixing while a mute, clip drag, or tempo nudge reads as shaping — the two steps can never collapse into each other. Because the adapter watches the store, actions arriving over the control wire count exactly like clicks, which the verification proved by walking the entire tour over WebSocket with zero staged signals: template applied, play pressed, tempo nudged, fader moved, one-second bounce rendered — each advancing its own step and nothing else's.
- Two controls the flow needed now exist: an EXPORT button in the transport bar (save panel, then a real bounce — present in both Simple and Pro, with the readout anchor and PUNCH untouched) and a neutral "USE A TEMPLATE" button under the Sketchpad's GENERATE for the instant, keyless path. Both ship with Explain cards (catalog now 46). Verified independently: build clean, suite grew to 1416 tests in 168 suites, all six captures pixel-reviewed, the staging command stays off the public wire, and sixteen of sixteen wire checks passed. Next: (ob-c) the live first-song gate on a fresh profile — then M8 is done except its key-blocked gates.

## 2026-07-10 — M8 (ob-a): the first-song tour gets its brain — onboarding flow designed, modeled, and tested
- The "first song in ten minutes" guided tour now exists as a complete design plus a fully tested headless state machine. The script is seven steps — welcome, generate, listen, shape, mix, export, done — walking a brand-new user from an empty project to a bounced song, and it works without any cloud API key: the generative step rides the local ACE-Step Sketchpad with an instant song-template fallback for the impatient or the offline.
- The tour advances itself by listening for real accomplishments, not clicks: the app will emit typed signals (project gained content, playback started, an edit landed, the mixer moved, a render finished) and the model advances only when the active step's expected signal arrives — with manual advance and skip always available so a missed signal never traps anyone. Progress persists across relaunch, finished or dismissed tours never nag again, and a Settings replay seam is built in. The design doc pins the exact file-and-line wiring sites for every signal, including the rule that keeps the shape and mix steps from collapsing into each other, and honestly flags the two controls that don't exist yet (an export button and a template button — next cycle's work).
- Verified independently: build clean, suite grew to 1401 tests in 166 suites (34 new tests cover the full walk-through, every no-op guard, persistence round-trips, and the same copy style rules the explain cards obey), zero engine/control/MCP surface changes, and the wiring map's claims spot-checked against the real code. One catch during review: the listen step's copy pointed users at the top of the screen for the Vibe Meter, which lives in the bottom transport bar — fixed. Next: (ob-b) the guided UI itself — glass step cards, coach-mark anchoring, signal wiring, and the two missing buttons.

## 2026-07-10 — M8 (vm-b): the glowing instrument — the session vibe meter is alive in the transport bar
- The signature visualization has landed: a small glowing ember orb now lives left of the master cluster, and its shape IS the mix. The 24 analysis bands from vm-a become the orb's silhouette — a bass-heavy mix bulges warm and low, a bright mix flares cool and high — while the spectral centroid slides its color along a warm-amber-to-cyan ramp, the mix level drives how hard the core glows, and spectral flux sets how much it shimmers. Silence is a dim ember, not a black hole. It renders on a 60 fps Canvas, shows in both Simple and Pro transport modes (it's information, not an edit control), and by construction never turns violet — that color stays reserved for AI, and a test sweeps the entire color ramp to prove it.
- All the perceptual mapping lives in a headless, tested model: log-frequency hue placement, dB-to-brightness curves, and asymmetric attack/release smoothing (fast in, slow out) so the orb breathes with the music instead of jittering. Twelve new tests pin dormancy at exact floors, mid-spectrum hue at 1 kHz, curve monotonicity, and the no-violet invariant. A debug-tier seed command stages deterministic captures without touching the engine, and the meter ships with its own "Explain this" card — hover it in explain mode and the app tells you what the glow means.
- Verified independently: build clean, suite grew to 1367 tests in 165 suites, six captures pixel-reviewed (four unmistakably distinct states including real playback rendering a green-teal mid-spectrum orb), four live wire checks on the seed command including its error path, and isolation checks confirming the engine, control protocol, and MCP surface are untouched. With both halves landed, the Session vibe meter roadmap item is COMPLETE. Next: the onboarding first-song-in-10-minutes guided flow — the last unchecked non-key-blocked M8 item.

## 2026-07-10 — M8 (vm-a): the vibe meter gets its ears — real-time spectral analysis of the master mix, on the wire
- The session vibe meter's data source is live: a DSP analyzer now rides the master bus tap, computing 24 log-spaced spectral bands (40 Hz to 16 kHz), short-term level, held peak, spectral centroid (how bright the mix is), and spectral flux (how much the energy is moving) at roughly 46 snapshots a second. It analyzes post-master-fader — what you hear is what it measures — and it is real-time-disciplined throughout: FFT buffers, windows, and band tables are preallocated at init, and the audio-adjacent tap path allocates nothing but the published snapshot value.
- Everything is finite by contract. Silence and stopped transports decay smoothly to an exact −80 dB floor (the peak takes ~5 seconds by design, releasing at −20 dB/s), poisoned input frames are skipped whole, and the wire never sees a NaN. Agents get the same view humans will: a new `mixer.masterAnalysis` command and `mixer_master_analysis` MCP tool return the snapshot on demand — an AI can now ask whether the mix is bright, dense, or peaking without rendering a file. Real LUFS measurement stays with `render.measureLoudness`; this is the fast, always-on view.
- Verified independently: build clean, suite grew to 1355 tests in 164 suites (thirteen DSP tests pin the analyzer against known signals — a 1 kHz sine lands in the right band with the right centroid and RMS — plus chunk-size invariance and stereo down-mix parity), npm audit green at 94 commands / 97 tools, and a live wire pass watched the centroid track an arpeggio in real time before decaying back to exact floors. Next: (vm-b) — the glowing instrument itself, the signature visualization this data feeds.

## 2026-07-10 — M8 (ex-b): "Explain this" goes app-wide — 43 curated cards across every surface, anchored per-instance
- The explain catalog doubled from 21 to 43 entries and the violet "?" mode now covers the whole app: every mixer strip (channels, buses, and the master), the piano roll's grid, velocity lane, and snap, the arrange sidebar's track rows and add-track button, clips in the timeline, all three AI panels (Sketchpad with its Lyrics workshop, the Copilot rail, FIX WITH AI), and Settings — where the API-key card explains what a key unlocks and that it lives in the Mac's Keychain, without ever showing a key value.
- The load-bearing fix was per-instance anchoring: ex-a could only tag the first mixer strip because repeated controls sharing one ID collided on a single stored frame. Now a hovered control reports its own frame at hover time, so sliding from one strip's fader to the next re-anchors the card on the strip under the pointer; the old ID-keyed frame table survives only as capture staging, where a new instance selector on the debug command lets a capture prove the card lands on strip three, not strip one. Shared controls got shared copy — one "Simple / Pro" entry now serves the density chip on all four panels.
- Four labeled deviations, all reviewed sound: the shared density ID rename, the debug-tier instance selector (pre-authorized), one honest-scope entry each for Canvas-internal clip and note-grid affordances rather than fake per-grip tags, and hoisting the explain scope so cards float above the Settings modal. Verified independently: build clean, suite grew to 1339 tests in 162 suites with a count-floor test pinning the catalog against silent shrink, all five captures pixel-reviewed (violet exclusive to AI affordances throughout), and eleven wire checks passed including the renamed ID correctly erroring. Next: the parent item waits only on (ex-c), the key-blocked live hand-off gate; the cycle after picks up the session vibe meter.

## 2026-07-10 — M8 (ex-a): "Explain this" lands — a violet ? chip that makes every control self-describing, with a hand-off to the Copilot
- A violet EXPLAIN chip now sits in the app header beside COPILOT and SKETCHPAD. Toggle it and the app enters explain mode: hover any registered control and a violet-edged glass card appears with plain-language curated copy — what the control does and when you'd reach for it — plus an "Ask the Copilot →" button that closes explain mode, opens the rail, and prefills a question about that control as a draft (never auto-sent, so it works with or without an API key; the live conversation gate is ex-c, key-blocked). Explain mode is an overlay, not a lockout — the controls underneath keep working — and Esc exits, with the Esc handler mounted only while the mode is active.
- The copy lives in a headless 21-entry catalog in DAWAppKit covering the two reference surfaces (all twelve transport-bar controls and a mixer strip's nine), with tested style rules: titles cap at 24 characters, bodies run 40–280 characters ending in real punctuation, and no dB/Hz jargon appears without a plain-language gloss. Two labeled deviations, both verified sound: the hand-off routes through an AppModel draft property because the copilot engine deliberately has no draft API (its turn loop is untouched), and only the first mixer strip is tagged since identical IDs on every strip would collide frames — the ex-b rollout generalizes that.
- Verified independently: build clean, suite grew to 1338 tests in 162 suites (+10 catalog/state tests), all four captures pixel-reviewed (violet stays exclusive to the AI affordances per the design language's Rule 3), the debug staging command round-tripped live on the staging port — six checks including the unknown-focus error path — and grep confirms the explain surface exists nowhere in the control protocol or MCP server, exactly as designed. Next: ex-b rolls `.explainable` coverage across every remaining surface.

## 2026-07-10 — M8 (sp-d): Simple ↔ Pro rollout COMPLETE — the transport splits, and every panel now has an honest density story
- The last conversion is deliberately the smallest: in Simple, the transport bar hides exactly two things — the PUNCH chip (an advanced record window) and the test-tone verify button (a diagnostic) — while play, loop, click, tempo, the readouts, and the master all stay. One geometric subtlety got a labeled deviation: the leading control group is pinned to a fixed width so the Position/Time/Tempo readouts (the bar's visual anchor) sit at pixel-identical x in both modes while the chip row still closes up naturally. The agent caught its own first attempt truncating PUNCH at a narrower pin and re-captured at the right width.
- With sp-d, the parent roadmap item closes: density coverage is uniform across the app. Four surfaces carry live SIMPLE/PRO chips (piano roll, mixer, arrange, transport); the other nine were audited as already-Simple and are now formally documented as coincident-exempt — with the design language codifying the principle that a panel whose modes coincide must never grow a do-nothing toggle, because a toggle that changes nothing is worse than none.
- Verified independently: build 0 warnings, suite 1328/161 held, capture pair pixel-reviewed (readout anchor confirmed by overlay comparison), and UserDefaults now carries four independent panel keys with mixed values — the per-panel model working exactly as designed. Next: M8's "Explain this" AI affordance on hover.

## 2026-07-10 — M8 (sp-c): the arrange workspace learns Simple mode — move clips on a bar grid, nothing sharp to grab
- In Simple, arranging is exactly three verbs: see clips, drag them (on a grid locked to whole bars), play. The snap picker, edge-trim strips, corner fade grips, per-clip gain chip, double-click split, and ⌥ time-stretch all belong to Pro now — and the suppression is honest at the gesture layer, not just cosmetic: SwiftUI gesture masks drop the Pro recognizers, and the drag-zone classifier collapses every press to "body" in Simple, so grabbing a clip's edge moves it instead of dead-air no-oping where a trim strip used to be. The context menu follows suit (clip edits Pro-only; take-group entries stay in both modes, since take lanes keep their own verdict).
- Read-only status stays visible in both modes by design — a stretched clip's ratio badge, the render shimmer, error dots: a beginner should see what state a clip is in even when they can't initiate the edit. The Bar-lock is a tested DAWAppKit unit (`ClipSnap.effective`) that never mutates the picked resolution, so flipping back to Pro restores your snap choice — the same courtesy the piano roll established.
- Verified independently: build 0 warnings, suite grew to 1328/161, all three captures pixel-reviewed (the same selected clip reads as a plain block in Simple and shows its fade wedges and −3.5 dB chip in Pro), every gated gesture entry point code-reviewed, and UserDefaults now holds three independent panel keys — arrange, mixer, and piano roll each remembering their own density. Next: sp-d closes the Simple↔Pro rollout (the minor transport split + documenting the nine modes-coincide verdicts).

## 2026-07-10 — M8 (sp-b): the mixer console learns Simple mode — level, pan, mute/solo, and a longer fader
- The densest surface in the app now honors the beginner rule. In Simple mode every channel strip reduces to what a newcomer actually reaches for — name and kind badge, pan, the fader beside its meter and dB readout, and Mute/Solo/Arm — while Pro reveals the signal-flow sections: inserts, sends, and output routing. The vertical space freed in Simple flows into a visibly longer fader throw, so the beginner mode isn't just fewer controls, it's finer level control. Bus strips gate the same three sections and keep their per-kind differences; the master strip is exempt (it was already its own Simple mode) and renders pixel-identically in both.
- The whole console is one panel on the sp-a foundation: the shared SIMPLE/PRO chip sits in the Mix toolbar's top-right (the position SNAP occupies in Arrange), bound to panel ID "mixer" on the same sticky store. No new commands, no new tests needed — the gating is a pure view-conditional over the already-tested store, and sp-a's `debug.panelDensity` staged every capture.
- Verified independently: build 0 warnings, suite 1327/161 held, three captures pixel-reviewed (a staged session with real inserts, a send, and a bus so Pro had content to hide), and the piano-roll regression shot doubled as a live independence proof — mixer at Pro and piano roll at Simple simultaneously, each persisted under its own key. Next: sp-c, the arrange workspace's Simple mode.

## 2026-07-10 — M8 (sp-a): Simple ↔ Pro gets a real foundation — 13-surface inventory, per-panel density store, one shared toggle
- The "every panel" mandate now rests on evidence instead of vibes: a 13-surface inventory (`docs/research/simple-pro-inventory.md`) classified the app — the piano roll already carries the pattern; the mixer channel strip, the arrange workspace, and (minorly) the transport genuinely need modes; and nine surfaces already ARE their Simple mode (master strip, track rows, automation, takes, clip-fix, sketchpad, lyrics, copilot, settings), so they get documented as coincident rather than burdened with a do-nothing toggle. The rollout is split accordingly: sp-b mixer, sp-c arrange, sp-d transport + the coincide verdicts.
- The mechanism is shared and headless: `PanelDensity`/`PanelDensityStore` in DAWAppKit (@Observable, per-panel — a beginner may want a Pro piano roll but a Simple mixer; persistence through an injected backing seam, with a UserDefaults adapter keying `panelDensity.<panelID>`, nine hermetic tests), and a `SimpleProToggle` chip component extracted verbatim from the piano roll's toggle. Density is an app-side sticky preference — it survives relaunch and is never written into the project file — now codified in DESIGN-LANGUAGE.md.
- The piano roll was refit onto the shared pieces with exactly one behavior change: the mode now sticks across reopen and relaunch. A `debug.panelDensity` staging command (debug tier — off allCommands, no MCP tool) lets captures and E2E stage either mode over the wire. Verified independently: build 0 warnings, suite grew 1318/160 → 1327/161, both mode captures pixel-reviewed (the Simple↔Pro delta is exactly the snap picker and velocity lane), wire round-trip of both happy and both error paths, and an on-disk persistence proof. Next: sp-b, the mixer console's Simple mode.

## 2026-07-10 — M8 (glass-c): the audit's follow-ups land — measured contrast, honest accents, one grid
- The three deferred findings from the glass-a audit are done. The create "+" affordances (add-track, add-insert, add-send) dropped cyan for neutral chrome — Rule 3 reserves cyan for playback/activity, and the design language now codifies the principle: an accent is earned by state, not by inviting a click. The Sketchpad's ± length stepper keeps its cyan, correctly, as a numeric-readout control.
- The contrast pass was measured, not eyeballed: WCAG relative luminance with `.opacity()` blends alpha-composited over the actual surfaces (math kept in scratchpad/contrast.py). Plain `textDim` proved already compliant (5.51–6.30:1) and was left untouched; the real offenders were nine ad-hoc opacity blends, now retargeted to two new tokens — `textSecondary` (real labels, "No inserts"/"No sends" went 3.39→6.71:1) and `textFaint` (placeholders/decorative, worst case 2.84→4.18:1 against a 3.0 floor). The four-tier text hierarchy is codified in DESIGN-LANGUAGE.md with a ban on dimming real labels below 4.5:1 via ad-hoc opacity.
- Three near-duplicate grid-emphasis literals collapsed into `DAWTheme.gridEmphasis` (white @ 0.14) — the piano roll and keyboard sidebar shifted by 0.02 each and all grids now read at the timeline's strength. Verified independently: build 0 warnings, suite 1318/160 held, before/after captures reviewed at the pixel level. M8 next: Simple ↔ Pro progressive disclosure on every panel.

## 2026-07-10 — M8 begins: the glass-cockpit compliance audit — the design language holds, two breaks fixed
- First M8 item (glass-a): an evidence-based sweep of all ten shipped surfaces against DESIGN-LANGUAGE.md — full code sweep of the view layer plus eleven headless captures (app driven over the control wire on port 17695), each viewed by the auditor. Verdict: the cockpit is real — essentially all color routes through `DAWTheme`, every numeric readout is SF Mono, glow encodes state only, and violet stays strictly AI. Findings archived at `docs/research/design-audit-glass-a.md` with per-surface verdicts and file:line evidence.
- Two hard rule breaks found and fixed: the arrange sidebar's Mute chip lit amber (colliding with the Arm chip and mis-signalling "record" — the doc mandates Mute = red, and the mixer already complied), now red; and the piano-roll keyboard drew from the view layer's last raw hex literals, now the `DAWTheme.keyBlack`/`keyWhite` tokens (zero visual change). Three restyle-sized follow-ups (cyan "+" affordance semantics, an app-wide dim-text contrast pass, grid-hairline token unification) were deferred honestly as (glass-c) rather than half-fixed.
- Verified independently: build 0 warnings, suite 1318/160 held exactly, before/after captures reviewed at the pixel level. The GPT-Image asset half (glass-b) is parked under ## Blocked on the absent OPENAI_API_KEY. Next: Simple ↔ Pro progressive disclosure on every panel.

## 2026-07-10 — M7 COMPLETE: the MCP integration suite drives the real wire — and fixes what the demo found
- `mcp-server/test/integration.test.ts` (12 tests, now part of `npm test` alongside the 7-check audit) exercises the REAL transport end-to-end: it spawns the actual DAWApp binary headless on port 17690 and a real MCP SDK client over stdio, so every assertion crosses client → stdio → mcp-server → control WebSocket → app. Coverage includes the composition macros' first real-MCP exercise (skeleton scaffold, preset chain, seeded humanize determinism), the one-`edit_undo` scaffold revert, `project_overview`'s size bound, verbatim error surfaces, and a re-measured `render_bounce`. Missing app binary skips the file with an actionable message — never a silent pass; teardown is SIGTERM→SIGKILL in try/finally, and `pgrep DAWApp` stays empty after every outcome.
- The suite opened by fixing the two live mcp-server bugs yesterday's E2E demo exposed, each pinned by a regression test: void-result tools (`track_set_volume`, `transport_play`, …) now return the literal `"ok"` instead of an invalid `JSON.stringify(undefined)` content item that made clients reject with `-32602` despite the command executing; and the bridge now gives render-family commands a 180 s per-command timeout (`LONG_RUNNING_COMMANDS`) instead of the flat 5 s that silently discarded the loudness report of any full-length render (the regression proves a 6.2 s measure that used to die now survives).
- Verified independently: `npm test` **19/19 in ~11.4 s** (audit intact at 7/7), Swift baseline untouched at **1318 tests / 160 suites**, both fixes surgical single-site diffs, no stray processes. Notably the suite passed 19/19 on its very first run — the implementing agent spent its time reading the real tool schemas and Swift handlers instead of debugging afterward. **With this, every M7 item is done: the MCP surface is enforced-complete (96 tools), agent-ergonomic (overview + macros), demo-proven (a real agent shipped a track over it), and now regression-guarded on the real wire. Next milestone: M8 — design & simplicity polish.**

## 2026-07-10 — M7: the E2E demo — an AI agent composed, arranged, and mixed a track entirely over MCP, zero clicks
- The milestone's proof-of-concept is real: a delegated Claude agent, given only the `mcp__daw-pro__*` tool surface, produced a 24-bar moody synthwave piece at 104 BPM (Am–F–C–G, 464 notes across Bass/Chords/Lead/Pulse polySynth tracks) with a genuine arrangement (Chords enter bar 5, Lead exists only bars 9–20, Pulse sits out the outro), a deliberate mix (staged volumes/pans, compressor on Bass, chorus on Chords, a "Space" reverb bus fed by post-fader sends from Chords + Lead, and a 4-point volume-automation fade over the outro), live-meter playback proof, and a −14 LUFS bounce — ≈52 MCP tool calls, zero UI clicks, zero files written by the agent. Artifacts: `~/Library/Application Support/DAWPro/Generations/demo-m7-agent-e2e/` (demo-track.wav 57.4 s + demo-track.dawproj).
- Verified independently by the orchestrator: saved project structure matches the brief on every axis; the WAV's sample peak is exactly −1.000 dBFS (the true-peak ceiling clamp landing precisely where the render_bounce contract says); a fresh wire measurement reproduced the agent's main-section loudness verbatim (−19.19 LUFS / −6.04 dBTP, exact match); an independent play + snapshot showed the intro metering with Lead correctly silent.
- The demo doubled as a live audit of the MCP surface and found two real mcp-server bugs, queued for the MCP-integration-suite cycle: void-result tools (track_set_volume, transport_play, …) serialize `JSON.stringify(undefined)` into an invalid content item (client sees `-32602` though the command executed), and the bridge's flat 5 s request timeout eats render_bounce/measureLoudness replies on full-length renders (~25 s) even though the file lands. Also noted: the session ran against a stale MCP server process predating the macros — the agent composed everything the long way, which arguably strengthens the demo.

## 2026-07-10 — M7: the composition-macro trio completes — macro.songSkeleton scaffolds a session in one call
- `macro.songSkeleton` (MCP: `macro_song_skeleton`, tool #96) turns "start a pop song at 120" into a working session: tempo set, a genre-appropriate track roster added with mixer presets pre-applied (bass-tight on Bass, vocal-presence on Vocals, warm-keys where it fits — macro-b composed into macro-c, with a catalog-integrity test validating every cross-reference), the song's sections laid out as contiguous named empty MIDI clips on an "Arrangement" guide track, and the loop region set over the whole arrangement. Five genres ship (pop, house, hip-hop, rock, ballad), each with sensible default tempo and section plan; custom tempo and sections override cleanly. Additive by design — it never wipes the current project.
- The item's hardest guarantee — the entire scaffold as exactly ONE undo step — produced a documented store finding: `performEdit` journals one entry per call and only coalesces same-key entries within 800 ms, so composing store methods naively would fragment undo. The scaffold instead folds every mutation into a single performEdit body using the no-edit helper pattern (`applyTempoChange`, new `applyLoopRegion`), proven in both the DAWCore suite (undo-stack depth) and through the wire (one `edit.undo` restores the prior project exactly).
- Verified independently: build 0 warnings, **1318 tests in 160 suites** (+22, +2); parity audit 7/7 with the bijection at 93 commands + 3 = 96 tools; live app round-trip **10/10** — scaffolded pop onto a non-empty project (additive confirmed), the bass-tight chain landed on Bass, eight empty guide clips with Outro at beat 192 and loop to 208, one undo left exactly the pre-existing track, custom sections overrode defaults, and both error contracts held. With all three macros done, the composition-macros roadmap item closes; next M7 item: the end-to-end agent demo.

## 2026-07-10 — M7: one command to a mixed strip — mixer.applyPreset lands with a six-preset catalog
- `mixer.applyPreset` (MCP: `mixer_apply_preset`, tool #95) applies a named preset from the static, versioned `MixerPresetCatalog.v1` to any strip — audio, instrument, or bus. The preset's chain replaces the strip's inserts wholesale as one undoable edit (undo restores the exact prior chain, ids and order included); volume, pan, and sends stay untouched because presets are tone, not balance. Six presets ship, built only from the built-in FX pack: drum-bus-glue, vocal-presence, bass-tight, master-glue (compressor into limiter with a −1 dB ceiling), warm-keys, and clean-boost (+3 dB gain). Each apply mints fresh effect ids so two strips holding the same preset stay independently addressable. One documented mapping note: the built-in EQ has no dedicated high-pass, so "rumble trim" intents use a negative low-shelf — the closest available shape.
- Discoverability is structural: the MCP tool's `preset` param is an enum with every option described, and the unknown-preset error lists all six valid names. Catalog fidelity is tested by applying every preset and asserting the resulting params exactly — presets are pinned contracts, not vibes.
- Verified independently: build 0 warnings, **1296 tests in 158 suites** (+18, +2); parity audit 7/7 with the bijection at 92 commands + 3 = 95 tools; live app round-trip **8/8** — vocal-presence replaced a pre-existing gain effect with EQ→compressor at exact catalog values, undo brought the old chain back, clean-boost's linear gain matched 10^(3/20) to nine decimals, and master-glue landed compressor→limiter on a bus. Next: (macro-c) macro.songSkeleton completes the composition-macro trio.

## 2026-07-10 — M7: the first composition macro — clip.humanize gives MIDI a reproducible human feel
- `clip.humanize` (MCP: `clip_humanize`, tool #94) applies seeded, deterministic jitter to a MIDI clip: each note's onset shifts by an independent uniform amount within ±`timingBeats` (clamped strictly inside the clip) and each velocity within ±`velocityRange` (clamped 1–127), with lengths, ids, and order untouched — one undoable "Humanize" step. The response merges `seedUsed` into the clip payload: replay it to get the identical take, omit `seed` to re-roll. Drawn seeds stay under 2^53 so they round-trip the JSON wire exactly. Determinism comes from a small splitmix64 generator in DAWCore, since Swift's system RNG can't be seeded.
- Review caught a real gap before close: the agent's first pass skipped the `requireNotCompMember` guard that protects every other note-mutation site (comp members are store-managed — quantize rejects them explicitly). The premise was verified in the store code, the deviation bounced, and the guard + a regression test (comp member → `clipInTakeGroup`, notes byte-identical after) landed the same cycle. One behavior note for agents: a zero-jitter call changes nothing and therefore journals nothing (the app-wide performEdit convention) — don't pair it with an undo.
- Verified independently: build 0 warnings, **1278 tests in 156 suites** (+15, +2); parity audit 7/7 with the bijection at 91 commands + 3 = 94 tools; and a 10/10 live app round-trip — seed 42 echoed and reproduced identical notes through the wire twice, velocities pinned to both rails under max range, onsets stayed in bounds, the no-op round-tripped bit-identically, and out-of-range params rejected by field name. Next: (macro-b) mixer.applyPreset.

## 2026-07-10 — M7: agents get a cheap map of the session — project.overview lands
- `project.overview` (MCP: `project_overview`, tool #93) answers "what's in this session and what ids do I act on" in a fraction of `project.snapshot`'s tokens: a `ProjectOverview` Codable projection in DAWCore surfaces transport, master, and per-track state (routing, sends, fx names, clips, automation) with full actionable UUIDs — but counts instead of lists wherever a list can grow unbounded. MIDI clips report `noteCount`, automation lanes report `pointCount`, and file paths never appear. Optional fields are omitted rather than null; instrument tracks resolve a nil instrument to the default synth's display name the same way project.snapshot always has.
- Token efficiency is a tested contract, not an intention: a DAWCore test builds a dense synthetic project (8 tracks, 24 clips, 64-note MIDI clips, 60-point automation lanes) and asserts the overview encodes under 8 KB and at least 5× smaller than the full snapshot — measured 6,537 vs 84,731 bytes, a 12.96× reduction. One disclosed v0 seam: `sends[].preFader` is a documented constant `false` because the send model is post-fader-only today; the field exists so the shape stays stable when pre-fader sends land.
- Verified independently: build 0 warnings, **1263 tests in 154 suites** (+6, +1); the iteration-79 parity audit passed 7/7 with the bijection auto-adjusting to 90 commands + 3 = 93 tools — the enforcement carried this item's MCP correctness for free, exactly as designed; and a live app round-trip scored 8/8 (tempo/mute surfaced, noteCount with zero note leakage, the track id from track.add comes back verbatim and actionable, no path leaks, and the overview is smaller than the snapshot even on a 3-track session). Next M7 item: composition macros.

## 2026-07-10 — M7 opens: MCP↔command parity and schema richness are now machine-enforced
- The first M7 box closes with a twist: the scoping inventory showed every one of the 89 control commands already had an MCP tool (the "gaps" were naming-convention artifacts — six generation tools historically drop the `ai_` prefix, and three tools are direct-API by design). What was missing was enforcement, so that's what shipped: `mcp-server/test/audit-tools.test.ts` boots the real server on an in-memory transport, lists tools the same way a client would, parses `Command.allCommands` straight out of `Commands.swift`, and asserts the bijection (both exception tables explicit) plus richness — every tool titled with a beginner-readable ≥40-char description and every input property recursively described. `npm test` runs it cold; no new dependencies.
- Enabling refactor: `src/index.ts` shrank from 3870 to 30 lines (stdio entry only) and all 92 `registerTool` calls moved verbatim to a new exported `src/server.ts`, so tests import the server without side effects. The audit immediately earned its keep, catching a sub-bar `track_rename` description and four undescribed discriminator literals in `automation_add_lane`'s target schema — both fixed. The /mcp-verify skill's manual parity step now just runs the audit.
- Verified independently: cold `npm test` 7/7; a real stdio `initialize` → `tools/list` against `dist/index.js` returns exactly 92 tools; and a planted regression (shortened description) makes exactly the richness assertion fail, restore returns 7/7 — the enforcement provably bites. Swift surface untouched. Next M7 item: the agent-facing project snapshot.

## 2026-07-10 — M6 (rail-d): The copilot gets its face — a violet chat rail docked into the cockpit
- `CopilotRailView` + `CopilotTranscriptEntryView` (new `Sources/DAWApp/Copilot/`): a right-docked 360 pt violet-edged glass rail, mounted app-level at full workspace height in both Arrange and Mix — the copilot is a workspace companion, not a selection-gated panel. Header carries the glowing violet identity dot, AI credit, reset ↺ and close; a first-use hint card teaches the feature in plain language with three example prompts. The transcript renders every entry kind from the rail-c wire contract distinctly — user bubbles right-aligned, assistant text in violet glass, tool calls as violet chips showing the dotted command + params, tool results as green-ok/red-error chips, failures as a red strip with the actionable message — with a WORKING shimmer row and auto-scroll while a turn runs (input disabled, red cancel replaces send).
- Chip summaries are compacted by `CopilotSummaryFormat` in DAWAppKit so the rendering contract is headless-tested; the engine gained a `seedForCapture` hook driven by debug-tier `ui.showCopilot`/`debug.copilotSeed`/`debug.copilotState` (off allCommands, off MCP — capture/E2E only). DESIGN-LANGUAGE.md gains the "Copilot rail" component entry.
- Verified independently: build 0 warnings, **1257 tests in 153 suites** (+10, +2), MCP surface untouched at **92**, and all three live-app captures personally reviewed against the design language (idle hint card; full entry-kind variety in one conversation including an error tool-result and the shimmer; failure strip with input re-enabled). Remaining: rail-e proves the whole rail on a real key — blocked until one lands.

## 2026-07-10 — M6 (rail-c): The copilot engine is wired — an AI can now converse its way through the same commands as every other client
- `CopilotEngine` (DAWControl, @MainActor @Observable) runs the full tool-use turn loop: user message → provider call → up to 8 tool rounds executed against the identical `CommandRouter.handle` the WebSocket uses → final text. Session context rebuilds every round (8-char id prefixes with engine-side expansion), command errors flow back as error tool-results so the model can react, and hard caps (8 rounds, 4k results, 8k context, 20-message history, one turn at a time) bound every conversation. The 36-command `CopilotToolCatalog` carries transliterated JSON schemas with a test-asserted denylist — project.new/open/save, track.remove, and the copilot's own commands can never be called by the model.
- Wire surface: `ai.copilotSend` / `ai.copilotState` (poll, transcript with user/assistant/toolCall/toolResult/failure entries) / `ai.copilotReset`, mirrored as three MCP tools (**92** total). The engine is constructed key-less at app startup; the provider resolves per turn, so adding a key in Settings ⌘, works without a restart.
- Verified independently: build 0 warnings, **1247 tests in 151 suites** (+32, +3 — catalog exhaustiveness, a FakeCopilotProvider suite driving the real router through scripted multi-round tool sequences, command wire tests), npm clean, and a 7/7 live app round-trip (validation, the actionable no-key error with the engine confirmed wired, unknown-turnId poller semantics, reset, zero key material in any response). Remaining: rail-d gives this a violet chat rail; rail-e proves it on a real key.

## 2026-07-10 — M6 (rail-b): Copilot provider client lands — Anthropic tool-use speaking, OpenAI fallback, fully pinned without a key
- `Sources/AIServices/CopilotProvider.swift` implements the rail design's §2 seam exactly: value types for tool specs, content blocks (text / tool_use / tool_result), turn requests and replies, behind a `CopilotProviding` protocol that speaks pre-encoded JSON `Data` so AIServices never imports DAWControl. `AnthropicCopilotProvider` pins the Messages tool-use wire shape (tools with input_schema, tool_use/tool_result pairing by id, stop_reason mapping); `OpenAICopilotProvider` mirrors it over chat-completions function calling; `resolveCopilotProvider` follows the anthropic-first Keychain/env chain with the actionable no-key error naming Settings ⌘,.
- Thirteen stub-HTTP tests (reusing the LyricsWriter local-server helper) pin both providers' request shapes and parsing — including multiple tool_use blocks in one reply and the tool_result-rides-in-user-message contract — plus the resolver chain order and a no-key error that provably contains zero key material.
- Verified independently: build 0 warnings, **1215 tests in 148 suites** (+13, +3), MCP surface untouched at 89 tools, no logging primitives in the client, key-leak grep clean. Next: rail-c wires the engine, catalog, and ai.copilot* commands so this client starts driving the DAW.

## 2026-07-10 — M6 (rail-a): Copilot rail architecture settled — the chat copilot will drive the same command surface as every other client
- The copilot rail v1 design is closed and archived (`docs/research/design-rail-a-copilot.md`, 11 sections): a hand-curated 36-command tool catalog in DAWControl (schemas transliterated from the MCP server, with a name-bijection exhaustiveness test), in-process execution through the identical `CommandRouter.handle` the WebSocket uses, per-round session context with 8-char id prefixes, and an Anthropic-first/OpenAI-fallback provider seam that speaks pre-encoded JSON `Data` so module boundaries stay clean. Non-streaming v1; provider re-resolved each turn so adding a key in Settings takes effect without restart.
- Notable placement decision: `CopilotEngine` lives in DAWControl (AIServices would need DAWControl types — a dependency cycle), and the app observes the engine directly instead of a DAWAppKit mirror model. Safety rails are structural: a positive allow-list excludes project.new/open/save, track.remove, recording/arm, and the copilot's own commands (recursion impossible by construction), with 8-round and payload caps; every mutation stays individually undoable.
- Split shipped alongside the design: rail-b (provider client) → rail-c (engine + wire + MCP, 89→92 tools) → rail-d (violet rail UI) → rail-e (real-key gate, blocked like the lyrics workshop). ~41 tests planned across 4 suites, all runnable key-less via a fake provider driving the real command router. No code this cycle — design only; baselines hold at 1202/145, 89 tools.

## 2026-07-10 — M6 (v-d): Onset auto-align lands — AI takes snap to the original performance with one command
- New `take.autoAlign` command + `take_auto_align` MCP tool (89 total): measures the micro-offset between a take lane and the group's reference lane by matching their detected onsets (same spectral-flux detector the audio-quantize path uses), then moves the take so its phrasing locks to the original — one undoable "Align Take" edit. `apply:false` gives a pure dry-run preview; `searchWindowMs` (10–500, default 150) bounds the hunt. The aligner recovers a planted 80 ms shift to within a tenth of a picosecond through the real detector, and refuses to guess: fewer than 2 matched onsets throws `alignmentInconclusive` with counts and advice.
- The orchestrator's live closed-loop round-trip caught a real bug the 1199-test suite missed: applying at beat 0 with no headroom silently clamped to a no-op while reporting `applied:true`. Fixed same cycle — an apply that would push the take before the timeline start now throws `alignmentWouldCrossTimelineStart` naming the required move, the available headroom, and the `take.move` remedy; `applied:true` now strictly means the take sits aligned. Three regression tests pin it.
- Verified independently: build 0 warnings, **1202 tests in 145 suites** (+31, +4), tsc clean at 89 tools, and a 9/9 live wire round-trip (preview ±80 ms recovery, preview purity, apply→residual <3 ms, all three error surfaces, undo restore). The M6 vocals path — repaint core, clip-fix loop, real-hardware gate, and now micro-alignment — is complete end to end.

## 2026-07-10 — M6 (v-c): Real repaint gate PASSES — the vocal-fix loop is proven on live hardware, sample-exact at the seams
- Ran the full clip-fix loop against the real ACE-Step sidecar (turbo, MLX native) on the archived 30s vocal stem: wire-scaffolded project → `ai.fixClipRegion` on beats 16–24 (±10s context → 22s window, repaint 8–12s in-file) → status polls → import as the violet "AI Fix 1" lane → comped audition bounce. About 70 seconds wall end-to-end including model load; the submit was accepted first try and the three "installed but not running" polls during the model-load GIL stall were absorbed by the designed tolerance.
- Continuity analysis PASS, stronger than the design demanded: the context outside the repaint window came back at peak lag **0 samples with correlation 1.0000** on both sides — upstream splices the source audio back verbatim outside the window, so alignment is sample-exact, while the fix region itself is genuinely new material (correlation 0.16). Both comp-splice seams are click-free in the rendered bounce, and the comp is exactly [original 0–16 | fix 16–24 | original 24–60].
- Nine artifacts archived for audition under `~/Library/Application Support/DAWPro/Generations/gate-vc-repaint/` (dry window bounce, returned repaint, comped bounce, analysis.json, wire-response JSONs). No code changed — this was a verification gate; baselines stay 1171 tests / 141 suites, 88 tools.

## 2026-07-10 — M6 (v-b-2): FIX WITH AI panel lands — region vocal fixes are now a two-click flow in the app
- Select an audio clip and a violet FIX WITH AI chip appears in the arrange header, opening a docked glass panel: region beats prefilled from the clip (cyan SF Mono, editable), a "what to fix" prompt, optional bracketed lyrics, and a SUBTLE/BALANCED/BOLD strength picker (mapping to the repaint modes) above a violet-glow FIX THIS REGION button. Below it, an AI FIXES strip tracks every job: violet shimmer + step/percent while generating, green READY with one-click IMPORT, an IMPORTED → "AI Fix N" badge once the take lands, red failures with the upstream message. The panel persists across selection changes — jobs keep polling while the composer collapses to a hint.
- Under the hood: headless `DAWAppKit.ClipFixModel` over the v-b-1 store methods with the Sketchpad resilience rules — a failed poll marks a card transiently stale but never kills it; `clipFixStale` is terminal amber, `clipFixJobNotFound` terminal red, and any other import error stays retryable. Debug-tier seed commands (off the agent surface) drive captures and E2E.
- Verified independently: build 0 warnings, **1171 tests in 141 suites** (+19, +1); MCP surface untouched (88 tools); all three captures personally reviewed (filled composer on "Lead Vocal", the three-state jobs strip, the imported badge). The full vocal-fix loop — select, describe, generate, import, comp — is now usable both from the app and over MCP.

## 2026-07-10 — M6 (v-b-1): Clip vocal-fix flow lands — "fix this region" becomes a comping decision, not a destructive edit
- New agent-plane vertical: `ai.fixClipRegion {trackId, clipId, startBeat, endBeat, prompt?, lyrics?, mode?, strength?, seed?, contextSeconds?, model?}` bounces the target dry (as-heard: stretch/gain baked, track FX/sends stripped, plain-clip fades stripped to match post-grouping playback) over the region ± 10 s of context, submits an ACE-Step repaint of exactly that window, and — after the caller polls `ai.generationStatus` — `ai.importClipFix {jobId}` lands the result as a violet "AI Fix N" take lane comped in over exactly the requested region. Original audio is never replaced: the M5 take-group machinery holds both, one undo step restores everything, and the user comps between original and fixes with the existing take tools.
- Two engineering guarantees from the daw-architect design: outside-window audio from the repaint (a VAE reconstruction, not the original samples) can never reach the mix — the comp splice selects the fix lane only inside the region; and a minutes-long job survives project edits honestly — pure moves rebase by delta, anything geometry-breaking (trim/stretch/gain/tempo) fails with an actionable `clipFixStale` naming what changed. Pending fixes are in-memory v0 (documented: they don't survive relaunch; `clipFixJobNotFound` says to resubmit).
- Verified independently: build 0 warnings, **1152 tests in 140 suites** (+34, +3 — pure planner window/splice cases, dry-bounce assertions incl. zeroed fades and no render tail, move-rebase/stale matrix, two-fixes-compose-into-one-group, registry lifecycle); npm clean at **88 tools**; live app round-trip ALL PASS (7 checks — field-named validation, ghost-track translation, exact `clipFixJobNotFound` contract wording). Design archived at `docs/research/design-v-b-clip-fix.md`; real-sidecar seam-continuity verification is the upcoming (v-c) gate.

## 2026-07-10 — M6 (v-a): Repaint core lands — surgical AI audio fixes over the wire, retake = fresh seed
- `ACEStepClient` learns `repaintAudio`: regenerate a time window (`start`/`end` seconds) of an existing audio file, guided by optional prompt/lyrics, with `mode` conservative/balanced/aggressive, `strength` (balanced only), waveform-crossfade control, and deterministic-or-random seed. The upstream surface was read from sidecar source first: repaint is supported by BOTH turbo and sft, so unlike stems there's no sft ensure-load — one raw job id polls through the ordinary `ai.generationStatus` path. Source audio stages into the shared temp-dir allowlist; `audio_format:"wav"` always (the mp3-default trap, pinned again in tests).
- No invented "retake" command: upstream has no retake task type — a retake is the same repaint window with a fresh random seed, so the command/tool docs say "call again without `seed`" instead of growing a second surface.
- Wire + agent plane: `ai.repaintAudio` with field-named validation (missing/nonexistent `sourcePath`, negative `start`, `end` ≤ `start`, unknown `mode`, out-of-range `strength`) and the `ai_repaint_audio` MCP tool (**85→86**).
- Verified independently: build 0 warnings, **1118 tests in 137 suites** (+19, +2 — wire-shape suite pins every repaint field incl. seed-both-ways and confirms no model-inventory/init calls; command suite covers every validation branch); npm clean at 86 tools; live app round-trip ALL PASS — four field-named validation errors over the wire plus the actionable sidecar-unreachable translation on a well-formed submit. Real repaint generation is deliberately deferred to the (v-c) gate.

## 2026-07-10 — M6: Lyrics Workshop lands stub-complete — project-aware AI lyric writing awaiting its first real key
- The Sketchpad grows a violet WRITE-WITH-AI disclosure: theme + style + structure chips (verse/chorus/bridge/outro, add/remove/reset) → a provider-written draft in ACE-Step's bracketed format, with REWRITE, instruction-driven REFINE, and one-click APPLY TO LYRICS into the composer. Backed by the headless `DAWAppKit.LyricsWorkshopModel` (idle/writing/failed states; injected writer factory so the no-key case surfaces as an in-panel message at write time, not at launch).
- `LyricsGenerating` gains `writeLyrics(LyricsWriteRequest)` (default-bridged for minimal conformers); `AnthropicClient`/`OpenAIClient` implement it through a shared `LyricsPromptBuilder` that teaches both providers the identical bracket-format + singability system prompt and weaves in project context — omitted `tempoBPM`/`timeSignature` default from the live transport, so a bare call still carries the session's tempo/meter. Provider selection is anthropic-first via the Keychain/env `resolveKey` chain; no key yields an actionable, key-value-free error naming Settings (⌘,) and `ai.providerStatus`.
- Control + agent plane: `ai.writeLyrics` (`prompt` required; `style`/`structure`/`context`/`existingLyrics`+`instruction` optional — providing `existingLyrics` switches to refine mode) and the mirroring `ai_write_lyrics` MCP tool (**84→85**), deliberately distinct from the env-key legacy `generate_lyrics`: this one uses the app's keys and live project context.
- Verified independently: build 0 warnings, **1099 tests in 135 suites** (+37, +5 — both providers' exact request shapes pinned against stub HTTP servers, workshop state machine, command round-trip); npm clean at 85 tools; all three captures personally reviewed (filled composer, "via anthropic" draft with REWRITE/REFINE/APPLY, bracketed lyrics landed in the editor); live no-key wire round-trip ALL PASS (actionable error, zero key material, field-named validation). **Stub-verified only — the roadmap box stays unchecked until a real key is supplied (Settings ⌘, or `.env`) and one real generation is exercised; see ## Blocked in ROADMAP.**

## 2026-07-10 — M6: API key management lands — Keychain storage, glass Settings panel, and a wire that can't leak
- The AI provider stack is now fully configurable in-app: a Settings overlay (header gear chip or ⌘,) with per-provider rows — Anthropic, OpenAI, Suno (dormant), and a keyless ACE-Step row — backed by `KeychainKeyStore` (SecItem generic-password, service `com.dawpro.api-keys`). Environment variables keep precedence and show as LOCKED rows pointing at the var name; Keychain-saved keys show only a session-scoped `•••• last4` mask (stored plaintext is never read back for display). Neutral chrome by design — violet stays reserved for AI-generated content.
- The security boundary is structural, not conventional: there is NO set-key command on the control protocol or MCP — key values cannot transit the agent plane, period. The wire gets `ai.providerStatus` (+ `ai_provider_status` MCP tool, 83→84) returning strictly `{provider, configured, source}`; a test scans the full response JSON for key material and another asserts no set-key command exists. Resolution is a shared env-first chain (`resolveKey`) wired additively through `AIConfig.fromEnvironment(keyStore:)` — behavior with env vars present is byte-identical to before.
- Verified independently: build 0 warnings, **1062 tests in 130 suites** (+27, +3 — including a live headless macOS Keychain round-trip in an isolated namespace), npm clean at 84 tools; both captures personally reviewed (empty state, and the env-locked + keychain-configured mix); and a fresh live wire round-trip with an injected fake env key — the response reported only `configured/source`, with zero key material in the raw JSON.

## 2026-07-10 — M6 (iii-c-real) COMPLETE: genuine SFT stem separation, log-proven — the stems epic closes
- The gate that matters passed: `ai.extractStems` with NO model specified now defaults to `acestep-v15-xl-sft`, ensure-loads it into sidecar slot 2, and the sidecar log shows **every extract sub-job routing "Using second model: acestep-v15-xl-sft"** — zero silent substitution. The stems that came back are genuine, distinct PCM separations (different md5s, RIFF/WAVE 16-bit 48 kHz, 5.5 MB each, archived to ~/Library/Application Support/DAWPro/Generations for audition), imported as two violet AI tracks and removed by one undo. Full gate 10/10; slot-2 load + extraction in 164 s.
- What shipped: run.sh exports `ACESTEP_CONFIG_PATH2=acestep-v15-xl-sft` (slot 2 constructed at startup); `ACEStepClient.defaultStemsModel` + `ensureStemsModelLoaded` (`GET /v1/model_inventory` is_loaded check → `POST /v1/init {model, slot:2}`, 600 s configurable timeout, per-instance ensured cache, actionable `modelSlotUnavailable` error when an old sidecar lacks the env var); explicit `model` still wins. +4 tests (1035/127), tools steady at 83, command/tool descriptions teach the auto-load behavior.
- Two MORE findings only the real server could produce (now five total for this epic): `/v1/models` is SHADOWED by an OpenAI-compat route returning `{"object":"list","data":[]}` — the correct envelope lives at upstream's internal `/v1/model_inventory` (which also confirmed on live data that ONLY the sft checkpoint advertises extract/lego/complete); and the slot-2 model load briefly stalls the sidecar's event loop (GIL) so even executor-backed init windows can bounce wire submits with the misleading "installed but not running" — transient-tolerant submit retry is now standing guidance, and the "loading" sidecar state distinction has earned its third strike as a polish item.
- With this, the M6 (iii) generation epic — import pipeline, Sketchpad UI, stems extract/Lego, and the real-model gate — is fully landed.

## 2026-07-10 — M6 (iii-c-real) partial: first REAL stems run — wire proven 10/10, one bug fixed, one upstream trap exposed
- The whole stems path ran against the real sidecar for the first time: `ai.sidecarStart` from the wire (healthy in 5–7 s), a real 30 s lofi source generated in 50 s (turbo), `ai.extractStems` on that WAV, two named stems back, `ai.importGeneratedStems` landing violet `AI: Vocals`/`AI: Drums` tracks, single undo — 10/10 gate checks on the re-run.
- Real bug the stub hid (again): the stems submit path omitted `audio_format: "wav"`, so upstream returned 128 kbps MP3 bytes in `.wav`-named files (caught by the gate's RIFF assertion — both "stems" were byte-identical 0.48 MB sizes). One-line `ACEStepClient` fix + regression assertions pinning `audio_format` in both extract and Lego wire tests; re-gated on the real sidecar: genuine RIFF/WAVE PCM 16-bit 48 kHz stems, 5.76 MB each.
- Upstream trap, still open (why the box stays unchecked): passing `model: "acestep-v15-xl-sft"` does NOT load it — the sidecar logs `Model 'acestep-v15-xl-sft' not found in ['acestep-v15-xl-turbo'], using primary` and SILENTLY runs the extract on turbo, which officially doesn't support the task type (upstream doesn't reject it either). So separation quality is unproven until the sidecar serve config actually loads the SFT checkpoint — that config work + a genuine SFT re-gate is the remaining (iii-c-real) scope. Also learned: a fresh sidecar's FIRST /release_task blocks its event loop for the lazy model load, so wire submits (not just status polls) need transient tolerance — the flagged "loading" sidecar state polish item now has two bites.
- Suite 1031/127 green with the fix, 0 warnings; MCP untouched at 83.

## 2026-07-10 — M6 (iii-c): stems — extract and Lego land as multi-track violet imports
- The DAW can now split audio into stems and grow arrangements track-by-track: `ai.extractStems` (source file + stem names) and `ai.legoGenerate` (source file + global_caption + per-track local prompts) fan out one upstream `/release_task` per track under a composite `"stems:<uuid>"` job id, polled through the SAME `ai.generationStatus` surface (aggregated progress; one failing sub-job fails the composite naming the track) with the results riding an additive `stems: [{trackName, audioPath, bpm?, durationSeconds?}]` field. `ai.importGeneratedStems` mirrors the iii-a import fanned out: all-or-nothing stem staging into the project's Generations home, then ONE performEdit appending N violet AI tracks (title-cased from track_name) each with a clip at the same beat, tempo adoption by the iii-a rule from the first bpm-bearing stem — a single undo removes every track and restores the tempo. 3 new MCP tools (80→83) teach the healthy-sidecar → submit → poll → N-violet-tracks flow.
- Reading upstream source (not the scout summary) changed the design: extract AND lego are single-track-per-job and BOTH require `src_audio_path` — Lego is conditioned-on-context generation, not from-scratch; and the source-audio "upload" is upstream's temp-dir allowlist (`release_task_audio_paths.py` accepts only paths that realpath into the sidecar's own system temp), so the client stages a COPY under the shared `$TMPDIR` before submitting. Biggest catch: `TASK_TYPES_TURBO` EXCLUDES extract/lego — the turbo config our sidecar boots with won't serve them until the (already-installed) base/SFT model is loaded into a handler slot. `model` is exposed on both requests; a real-sidecar stems gate is now an explicit roadmap item (iii-c-real) rather than a silent gap.
- Verified independently: build 0 warnings, **1031 tests in 127 suites** (+29, +2), npm clean at 83 tools, and the stub-sidecar E2E — which drives the REAL app binary over the REAL control WebSocket and asserts the actual wire shapes (staged src path under $TMPDIR per sub-job, task_type/track_name/global_caption/local prompt) — re-run by the orchestrator: **27/27**, including 2-stem import + tempo 96 adoption + single-undo-removes-both, the Lego 1-track path, and verbatim still-running/unknown-job/empty-trackNames errors.

## 2026-07-10 — M6 (iii-b): AI Sketchpad — song generation gets a face
- The generation stack is now a first-class panel: a 340 pt violet-edged Sketchpad docks right of the Arrange timeline (header SKETCHPAD chip toggles it), with style-prompt + lyrics editors, one-tap `[verse]/[chorus]/[bridge]/[outro]` section chips, a 15–240 s length stepper, and a candidates list where each generation lives as a card — shimmer + step/percent progress while running, BPM/length metadata + cyan PREVIEW (off-engine AVAudioPlayer, one at a time) + glowing IMPORT when succeeded, a readable red reason when failed, and an IMPORTED→track-name seal after landing. Import rides the existing iii-a pipeline (`store.importGeneration`), so the panel and the control wire agree on job state via a shared `ACEStepClient`/`SidecarManager`; a sidecar-down banner offers inline START.
- All panel state lives in headless `DAWAppKit.SketchpadModel` (`@MainActor @Observable`, zero AppKit/SwiftUI): candidate lifecycle queued→running→succeeded/failed→imported, poll-only-active refresh loop that tolerates thrown polls (stale badge, keep trying), injected import closure, sidecar gating of `canGenerate`. Debug-only `ui.showSketchpad` + `debug.sketchpad*` seed/drive commands stay off `allCommands`/MCP — the agent-facing surface is unchanged (80 tools), so no ARCHITECTURE delta.
- Verified independently: build 0 warnings, **1002 tests in 125 suites** (+21, +1 — scripted-fake SongGenerating covering every transition), MCP steady at 80; four window captures personally reviewed — empty state (GENERATE correctly dim on blank prompt), succeeded card (92 BPM 30s, armed GENERATE), the full import round-trip in one frame (seal badge + violet AI track + clip at bar 1 + tempo adopted 92.0), and the demo spread (STEP 3/8 40% glowing bar over a failed card). Agent fixed two real defects mid-task: runloop-spin awaits silently not completing (→ fire-and-forget Tasks + state polling) and the view's poller amber-flagging a fake demo job id.

## 2026-07-10 — M6 (iii-a): generation→project import — a finished job becomes music in the arrangement
- One command turns a succeeded ACE-Step job into project material: `ai.importGeneration` (+ `import_generation` MCP tool, 80 total) copies the WAV out of the volatile sidecar cache into `~/Library/Application Support/DAWPro/Generations/` (the recording-take model — planMedia folds it into the .dawproj bundle on save), reads the authoritative on-disk duration, and in ONE `performEdit("Import Generation")` appends a violet AI-flagged track + clip at the target beat with tempo adoption — project tempo ← the generation's `metas.bpm`, by default only on an empty project, forceable either way. Single undo removes the track AND restores the tempo. Rejections are actionable and verbatim: still-running points at `ai.generationStatus`; unknown/expired jobs surface the client's own wording.
- The result `metas` (bpm/duration/genres/keyscale/timesignature) and echoed prompt now ride `SongGenerationStatus` as additive omit-when-nil fields, and DAWCore reaches audio+metas through a new `GenerationImporting` seam (injected `generationSource`, adapted in DAWControl over the router's existing `SongGenerating`) — DAWCore stays AI/network-free, and the seam is literally the status re-poll since succeeded status already carries the fetched-once audio path.
- Verified independently: build 0 warnings, 981 tests in 124 suites (+20, +1), npm clean at 80 tools, stub-sidecar E2E re-run **32/32** — generate → poll to succeeded (bpm 92) → import → snapshot shows AI track+clip+tempo 92 → undo restores both → second import with `setProjectTempo:false` leaves tempo untouched → error surfaces verbatim. Real-sidecar generation was proven at the M6 (ii) gate; the import path composes on top of it unchanged.

## 2026-07-06 — M6 (i)+(ii) REAL GATE PASS: first AI-generated audio out of DAW Pro
- The full local generation stack is live end-to-end: 55 GB of ACE-Step-1.5 weights installed (XL-turbo + XL-sft DiT, 4B LM), the sidecar starts from the control wire and reports healthy in under a minute, and a real generation — lofi prompt + bracketed verse/chorus lyrics, 60 seconds — rendered in ~52 s wall on the M5 Max (LM planning at 51 tok/s, tiled VAE decode) and landed as a valid 10.99 MB 48 kHz WAV fetched through `ai.generationStatus`. Both M6 boxes checked.
- The real gate earned its keep by flushing out three bugs no stub could see: (1) install.sh's weights sanity check only knew single-file layouts — the first SHARDED repo (XL-turbo, 4×5 GB) could never pass despite downloading perfectly; (2) upstream's serve-time generation path builds `project_root/checkpoints` explicitly, BYPASSING the documented `ACESTEP_CHECKPOINTS_DIR` — without exporting `ACESTEP_PROJECT_ROOT` the first generation re-downloads the entire model bundle into the wrong directory (run.sh now exports it, plus a defensive symlink); (3) `ACEStepClient` re-wrapped upstream's pre-built `/v1/audio?path=…` result URL, double-encoding it into a 403 — fixed to request it verbatim, with a regression test pinning the exact request target the server receives (961 tests / 123 suites, 0 warnings).
- Operational notes: the sidecar's single event loop blocks during lazy model load, so status polls transiently fail — the wire clients tolerate it, and a "loading" state distinction is a flagged polish item. Session-restart cleanup wiped the old scratchpad, taking the stretch-listen audition WAVs (regenerable on request) — durable artifacts now belong in the repo or ~/Library, not the scratchpad.

## 2026-07-06 — M6 (ii) generation layer: ACEStepClient + generate_song (awaiting real-generation gate)
- The DAW can now ask for songs: `SongGenerating` reshaped to the async submit/poll pattern local generation actually needs (`generateSong` → submission, `generationStatus` → state/progress/audio; SunoClient minimally adapted, still the dormant fallback), and `ACEStepClient` (actor) implements it against the sidecar's REAL routes, read from the upstream source: `POST /release_task`, `POST /query_result` (numeric status map + a JSON-encoded nested result payload), `GET /v1/audio` streaming, the `{data,code,error}` envelope — and a verified fact: upstream has NO cancel route, so we ship none. Finished audio is fetched once to a temp WAV (`audio_format` deliberately "wav", not upstream's mp3 default) and cached per job.
- Wire: `ai.generateSong` / `ai.generationStatus` with field-named validation; a sidecar-unreachable error re-probes SidecarManager so the agent gets the precise actionable message ("call ai.sidecarStart"). MCP: `generate_song` + `generation_status` (79 tools) teaching the healthy-sidecar-first, submit→poll→import flow and the bracketed-lyric format.
- Verified independently: build 0 warnings, 960 tests in 123 suites (+19, +2 — multi-route stub server, no weights needed), npm clean at 79, live stub E2E re-run ALL PASS (submit→running-with-progress→succeeded→valid RIFF/WAVE on disk, fetch-once caching, unknown-job and no-sidecar errors verbatim). **Both M6 (i) and (ii) boxes stay unchecked pending the real gate**: weights ~23 GB downloaded at last check; once complete — real sidecar health check closes (i), first real generation closes (ii).

## 2026-07-06 — M6 (i) management layer: ACE-Step sidecar install/run/lifecycle (weights downloading)
- The AI-suite milestone opens: `scripts/ace-step/install.sh` (idempotent — uv-managed Python 3.12 venv sidestepping the system 3.14 vs ACE-Step's <3.13 pin, shallow upstream clone, `acestep-download` for the LARGEST official tier per the standing directive: XL-turbo + XL-sft DiT + 4B LM, ~55–70 GB, size-sanity + import self-check, success marker) and `run.sh` (loopback-only FastAPI on 127.0.0.1:8001, MLX LM backend + MPS fallback, exec + pidfile so signals reach the server). Research-doc deviation documented: the doc's "-diffusers" bf16 repos don't exist in the live downloader registry — raw FP32 repos via the real CLI instead (disk is no constraint). No auth gate: ACE-Step-1.5 is MIT/unauthenticated on HF, confirmed live.
- `SidecarManager` actor in AIServices: `/health` probe (verified against upstream's actual route shape) mapping to notInstalled / installedNotRunning / starting / healthy / error with version+model info; `start()` spawns run.sh with startup-timeout poll, pidfile, and logs to ~/Library/Logs/DAWPro/ace-step.log; `stop()` SIGTERM→SIGKILL. `ai.sidecarStatus/Start/Stop` commands + 3 MCP tools (77 total) teaching the install-first flow. Two real install-script bugs found by actually running it (bash-3.2 `set -u` empty-array crash, unconditional `uv venv`) — fixed and re-verified idempotent.
- Verified independently: build 0 warnings, 941 tests in 121 suites (+21, +4 — stub-HTTP health-mapping suite needs no weights), npm clean at 77 tools, live E2E re-run ALL PASS (real dir honestly `notInstalled` mid-download; stub sidecar proves the full status→start→idempotent-start→stop→no-op-stop cycle over the wire). **Roadmap box stays unchecked until the ~55–70 GB download completes and the real sidecar passes its health check** — install running in background, ~1 GB in at last check.

## 2026-07-06 — M4 (i) RESOLVED: mid-play send activation — stale render clock, one-flag fix
- The defect two fix rounds bounced off is closed, and the instrumented diagnosis showed why those rounds couldn't work: the new send was NEVER miswired (the post-resume connection dump proved the full leg connected and its tap firing — carrying silence). The real mechanism: after the rewire's stop→reset→start engine bounce, `outputNode.lastRenderTime` still reports the PREVIOUS render session's sample clock, so `startPlayers`' `derivedBeats()` anchor froze the playhead at the resume beat for the length of the prior session — everything downstream was correctly playing a stopped transport. Arithmetic confirmation: predicted wrap-revival +4.19 s vs observed +4.17 s. Fix: `startPlayers(renderClockTrusted: false)` on the rewire-resume path forces the host-clock anchor branch (host time is monotonic across the bounce); one flag, no other behavior change, instrumentation removed.
- Verified independently: build 0 warnings, 920/117 exact baseline, and BOTH live repros re-run by the orchestrator — the original 19-check bus E2E ALL PASS including the historically failing "send signal meters on FX bus" (0.0724 RMS), and the audio-clip variant metering 0.1000 on the destination bus 252 ms after a mid-play addSend with existing playback untouched. The MIDI variant's revival lands at the loop wrap by design (documented no-chase v0 contract — a sustained pad has no note-on between resume and wrap).
- Discovered en route, parked properly (no-thrash): `project.new` after a PLAYED send/bus session corrupts the AVAudioEngine graph — the next `track.add` crashes in `UpdateGraphAfterReconfig` (two different surface stacks across runs = heap corruption; never-played sessions don't crash; proven independent of this fix). Recorded under `## Blocked` with repro `crash-teardown.mjs`. **M4 is now fully complete except that parked teardown crash.**

## 2026-07-06 — M5 (iv-d): render wire + MCP — M5 COMPLETE
- The loudness/stem surface goes on the wire: `render.measureLoudness` (measure, write nothing), `render.bounce` (optional −70…0 `lufsTarget`, −20…0 `truePeakCeilingDb`, honest clamp reporting), `render.stems` (per-track selection, `includeMixdown`) — field-named validation, store rejections verbatim, responses threading the model's own Codable. Three MCP tools (74 total) whose descriptions teach an AI mixing agent the −14 streaming / −23 EBU R128 conventions, the clamp-not-limiter semantics with the bus-limiter-then-re-bounce escape hatch, and the Σ stems ≡ mixdown invariant. `render.mixdown` untouched; ARCHITECTURE gains the `render.*` paragraph.
- Live-E2E-discovered crash fixed in iv-a's short-term loop: a render with exactly 30 hops (any clean 3.0 s at 48 kHz) crashed `Loudness.measure` on an invalid range (`1...(hopCount − hopsPerShortTerm)`); one-line guard, suite re-verified. Found because the E2E drove the REAL app — the fake-engine tests couldn't see it.
- Verified independently: build 0 warnings, 920 tests in 117 suites (+17, +1), npm clean at 74 tools, live E2E re-run ALL PASS — measured −14.906 LUFS/−12.361 dBTP on the 2-track+bus session; bounce to −16 → −16.0000 LUFS with the written file's Node-read peak matching the report exactly (−13.4545); hot-material clamp → `limitedByCeiling` true, −1.0000 dBTP, honestly short of target; stems 01 T1/02 Bus vs 00 Mixdown residual 0.0000e+0 over the wire; both error surfaces verbatim.
- **M5 — Editing depth is COMPLETE**: waveform editor, time-stretch, take comping + MIDI/audio quantize + grooves, stem export + LUFS bounce. 920 tests, 74 MCP tools, zero render-thread regressions across the milestone.

## 2026-07-06 — M5 (iv-c): stem plan + export — Σ stems ≡ mix, proven
- `StemPlan.swift` (pure DAWCore) partitions the session at the master input: one dry stem per direct-to-master track (sends stripped), one stem per bus carrying every send contribution routed to it — the only partition where nonlinear bus FX keep the sum identity. Bus-routed track requests reject verbatim; bus passes park foreign direct-outs on a silent dummy bus so the missing-bus→master fallback can't leak; `NN Name.wav` sanitize with case-insensitive collision suffixes. `renderStems` probes the full-session PDC plan ONCE and forces it on all N sequential passes, measures each stem (never normalizes), and streams one buffer in flight; `includeMixdown` writes `00 Mixdown.wav` under the same plan.
- The epic's crown-jewel invariant holds: Σ stems vs mixdown residual is 5.4e-20 on a flat project and BIT-EXACT (0.0) on both the bus-FX (250 ms delay) and PDC (240-sample lookahead limiter) projects — against a normative bar of 1e-4. The negative control renders one stem under its subset auto-plan instead and combs at 0.25 residual, proving the forced-plan machinery is load-bearing. Send tails demonstrably live in the destination bus stem (dry stem RMS 0.0 vs bus 0.108 in the tail window).
- Verified independently: build 0 warnings, 903 tests in 116 suites (+17, +2), MCP untouched (71 — wire lands at iv-d). Assumptions flagged: NN prefix numbers the filtered selection (no gaps); empty selection throws `nothingToRender`.

## 2026-07-06 — M5 (iv-b): buffer-render seam + measured/normalized bounce
- The engine gains three additive offline primitives on `AudioEngineControlling` (`renderOffline` buffer render with forcible PDC targets, `offlineCompensationTargets` full-session plan probe, `writeAudioFile`), with protocol-extension defaults keeping every fake green; `renderMixdown` is now literally renderOffline + writeAudioFile — proven bit-identical (max diff 0.0) with the WYSIWYG stretch-await preserved. The PDC probe builds the manual-rendering graph and reads the plan without rendering a frame, and matches `PDCPlan.compute` by test.
- `ProjectStore+Render.swift` lands `measureLoudness` (render → measure, nothing written) and `renderBounce`: static gain `target − integrated`, true-peak ceiling clamp `G = ceiling − TP` with honest `limitedByCeiling`, gain applied in place, output RE-measured post-gain, written Float32 WAV. Measured: −16 target → −16.00000051 LUFS re-read from disk; clamp case gets exactly `ceiling − TP` (+1.0 dB where +6 was asked) with the report showing the real achieved loudness; `bounceSilent` verbatim when a target is asked of gated silence.
- Verified independently: build 0 warnings, 886 tests in 114 suites (+15, +2), MCP untouched (71 tools — wire lands at iv-d). Flagged: param range validation deliberately deferred to the wire layer per spec; store defaults throw `engineUnavailable`.

## 2026-07-06 — M5 (iv-a): loudness core — BS.1770-4 in pure DAWCore
- `Loudness.swift` lands the measurement engine for the stem/bounce epic: K-weighting biquads re-derived at any sample rate from the analog-prototype constants (48 kHz published-table pin ≤ 1e-6), 400 ms / 75 %-overlap gated integrated loudness (−70 LUFS absolute → −10 LU relative gate), max momentary + short-term from the same energy series, and 4× polyphase Annex-2 true peak (129-tap Kaiser-β6 sinc, phase 0 bit-transparent, passband flat within 0.0093 dB at 48 k). Pure scalar Swift, no Accelerate — DAWCore stays engine-free; `LoudnessMeasurement` Codable IS the future wire shape (nil fields for gated silence, digital silence encodes as `{}`). `RenderedAudio` moved DAWEngine→DAWCore with in-place `applyGain(linear:)`; engine behavior frozen.
- Measured vs analytic: 997 Hz −23 dBFS → −22.99998 LUFS; left-only channel-weight case −26.0103 vs −26.0; gate-drop −23.0310; EBU 3341 fs/4+45° true peak +0.0982 dBTP (genuine band-limited overshoot at the abrupt fixture start, bounds (−0.4, +0.2)); burst short-term −27.6852 vs analytic −27.6845; 44.1 k calibration −22.9972.
- Verified independently: build 0 warnings, 871 tests in 112 suites (+21, +7). No wire/MCP change this sub-item (71 tools) — commands land at iv-d. Assumptions flagged: momentary/short-term stay ungated per §3.2 (finite on sub-gate programs while integrated is nil); TP interpolator design is implementer's-choice per spec.

## 2026-07-06 — M5 (iii-g): groove templates — the epic closes
- Grooves are now a project-level palette: `GrooveTemplate` is a pure per-slot timing-offset table (`{gridBeats, cycleBeats, offsets}`, offsets clamped to ±grid/2) extracted from real performances — a MIDI clip's note onsets or an audio clip's detected transients, both through the same pure `extract` (nearest-slot snap, per-folded-slot average, empty slots stay straight). Eight built-in MPC swings (`swing8/16 × 54|58|62|66`, any 54–75 resolvable) compute on demand and are never persisted. `groove.extract/list/remove` commands + 3 MCP tools (71 total), and both `clip.quantize` and `clip.quantizeAudio` take a `groove` param (builtin name → template id → template name) — applied BY VALUE through the single `QuantizeTarget.slotOffset` branch, so groove wins over swing, both quantize paths inherit it unchanged, and deleting a template never dangles. Persistence is additive and omit-when-empty: pre-groove project files re-save byte-identical; undo covers extract and remove.
- Verified independently: build 0 warnings, 850 tests in 105 suites (+25, +6), MCP clean, live E2E re-run ALL PASS — swung-MIDI extraction returns offsets [0, 0.16] exact vs analytic swing-66; applying the saved groove to a straight MIDI clip lands every onset dead on target (dev 0.000000); builtin swing8:66 through the AUDIO path (quantizeAudio → offline bounce → re-detect transients on the rendered file) puts all onsets on groove targets at max 0.0013 beat; list/remove/undo/unknown-ref all verbatim. **M5 (iii) take comping + quantize + grooves epic COMPLETE** — 7 sub-items, zero render-thread changes, one engine addition (transient analysis) total.
- Flagged assumptions: extraction is clip-relative (grooves are position-independent); offset clamp is the closed ±grid/2 bound so swing-75 round-trips exactly; cycleBeats defaults to 4 (no meter model yet — revisit with meter work).

## 2026-07-06 — M5 (iii-f): audio quantize v0 — slice, nudge, crossfade
- Audio clips now quantize destructively: `clip.quantizeAudio` (+ `clip_quantize_audio` MCP tool, 68 total) detects transients (iii-e), slices the clip at onsets, and nudges each slice to the grid through the SAME pure `QuantizeTarget.nearest` evaluator as MIDI quantize — grid, strength lerp, MPC swing — then replaces the clip with its slices in one `performEdit("Quantize Audio")`, so undo restores the single original clip (same id). Monotone clamp guarantees slices never reorder; comp members, MIDI clips, non-identity-stretch clips, and <2-transient clips reject with dedicated verbatim errors.
- Deliberate deviation from the settled spec, caught by honest measurement: the spec's source-continuation gap-fill (extend a slice to reach its neighbour's new start) replays the NEXT onset's attack when a slice moves late — the bounce analysis showed full-energy doubled transients at 0.90/2.80/4.80 beats. Shipped instead: natural-length slices (each reads only its own `[onsetᵢ, onsetᵢ₊₁)` span) with equal-power crossfades at compressed joins and clean silence at expanded gaps — the classic Recycle behavior, and what makes onsets land exactly on grid. Elastic (per-slice stretch) stays the flagged v1.
- Verified independently: build 0 warnings, 825 tests in 99 suites (+23, +5), MCP clean, live E2E re-run ALL PASS — off-grid click clip (max deviation 0.1013 beat) → quantize → offline bounce → re-detect onsets on the RENDERED audio: 6/6 dead on grid, max deviation 0.0000 beat, no ghost transients; undo→1 original clip, redo→7 slices, rejections verbatim.

## 2026-07-06 — M5 (iii-e): transient detection — the epic's one engine addition
- Audio clips can now report their onsets: `clip.detectTransients` (+ `clip_detect_transients` MCP tool, 67 total) runs a pure vDSP spectral-flux analyzer — mono mix, 1024-sample Hann frames at 256 hop, half-wave-rectified flux against a 0.35 s moving-median adaptive threshold with a 1%-of-peak floor (empirically needed: spectral leakage on a decaying pad otherwise sneaks past), 30 ms minimum onset gap, energy-rise refinement. Markers are source-file seconds plus a 0–1 strength, geometry-free by construction — trims, splits, moves, and stretches never invalidate the analysis. Results cache as JSON sidecars keyed like stretch renders (content hash + sensitivity quantized to 0.05 + analyzer version), atomic-rename committed, corrupt-self-healing. Strictly off the render thread.
- Measured: click-train onset error max 0.67 ms against a 5 ms bar (with a noise bed); a decaying pad yields exactly its one attack and zero tail onsets; determinism is bit-identical across relaunch and re-render. The marker API feeds iii-f (audio quantize consumes `timeSeconds`) and iii-g (groove extraction gets strengths for free).
- Verified independently: build 0 warnings, 802 tests in 94 suites (+21, +2), MCP clean, live E2E re-run ALL PASS (5 onsets found on a staccato mixdown at 12 ms max error — synth attack ramp, 0 spurious — cache rerun identical, MIDI rejection and sensitivity-range errors verbatim).

## 2026-07-06 — M5 (iii-d): MIDI quantize — grid, strength, MPC swing
- MIDI clips can now be quantized: `clip.quantize` (+ the `clip_quantize` MCP tool, 66 total) moves note onsets toward a target grid with a 0–1 strength lerp and MPC-convention swing (50 straight … 75 max, offbeat slots delayed by `(2·swing/100−1)·grid` before the lerp). Note lengths are preserved unless `quantizeEnds`; results are re-canonicalized, deterministic, and idempotent at full strength. Destructive with snapshot undo under the house coalescing key; audio clips are rejected with a message pointing at the future `clip.quantizeAudio`, comp members by the shared take-group guard.
- The math lives in pure `DAWCore/Quantize.swift` with the groove seam pre-built: iii-g adds an additive `groove` field and flips one branch in `slotOffset` — the wire shape and tool schema stay fixed. iii-f's audio quantize will reuse `QuantizeTarget.nearest` verbatim. One process note: the implementing agent caught a 2× discrepancy between the briefing's swing wording and the spec's formula and correctly followed the spec.
- Verified independently: build 0 warnings, 781 tests in 92 suites (+17, +4), MCP clean, and the live E2E re-run ALL PASS — exact grid at strength 1, exactly-halfway onsets at 0.5, swing 66 landing offbeats at 1.32/3.32, verbatim audio rejection, undo restoring the original onsets.

## 2026-07-06 — M5 (iii-c): take lane UI — comp painting in the arrange view
- Take comping is now a direct-manipulation workflow: tracks with take groups grow a signal-green stacked-layers glyph that expands a takes section above the automation row — one dim sub-row per take lane (mini waveform or MIDI pills), with the comp rendered as glowing highlights over the selected ranges and the newest lane accented. Click-drag on a lane paints it into the comp for the dragged range (snapped, per-tick commits riding the `take.comp:<id>` undo coalescing, exactly like automation drags); a plain click selects the whole take. Member clips in the main lane wear a "name · N" group badge and glowing splice hairlines at comp boundaries, with a take-focused context menu (Select Take N / Flatten Group); the sidebar gets a height-matched group panel with per-take select dots and a FLATTEN chip.
- All geometry and gesture math is headless in `DAWAppKit.TakeLaneModel` — including a normalize step that keeps every paintable comp provably inside what `setCompSegments` accepts, cross-checked against the real store in tests (20 new, 2 suites). A `ui.showTakes` debug command (the `ui.showAutomation` pattern) makes the section captureable headless. The optional crossfade control was deliberately skipped for v0.
- Verified independently: build 0 warnings, 764 tests in 88 suites (+20, +2), and captures re-viewed — the 3-segment painted comp shows each lane glowing over exactly its painted range with three rebuilt member clips, badges, and splice lines; post-flatten returns ordinary clips with all chrome gone.

## 2026-07-06 — M5 (iii-b): take comping on the wire + recording auto-group
- The comping model is now fully AI/E2E-drivable: seven `take.*` commands (`group`, `setComp`, `select`, `removeLane`, `flatten`, `move`, `setCrossfade`) with comp-segment arrays round-tripped through the model's own Codable (per-index parse errors, store rejections verbatim), and seven matching MCP tools (65 total) whose descriptions teach an agent the comping model — lanes hold takes, the comp is an ordered segment list, members reject normal edits until flattened. Snapshots carry `takeGroups`/`takeGroupID` for free via the iii-a Codable.
- Recording now auto-comps: when a finished audio take overlaps existing material on the track, it lands as a new lane in a take group (existing group extends; plain clips get grouped; disjoint stays plain) with the newest take winning the default comp — the classic loop-booth workflow. One deliberate behavior change: re-recording over the same range forms a 2-lane group instead of stacking overlap-summing clips (the old test updated to match). MIDI recording is untouched; loop-cycle multi-take recording stays deferred.
- Verified independently: build 0 warnings, 744 tests in 86 suites (+23, +2), MCP `tsc` clean at 65 tools, and the live 34/34 E2E re-run — group → member-edit rejection (verbatim message naming the escape hatch) → 2-segment comp → select → flatten → members freed → full undo/redo round-trip including group restoration. Honest note: the wire key is `takeGroupID` (Swift-synthesized), diverging from the lowercase-`d` id convention elsewhere.

## 2026-07-06 — M5 (iii-a): take/comp domain — take lanes, comping, flatten-on-edit
- The take-comping foundation (from the settled M5 (iii) design): tracks own `takeGroups`, each holding take lanes (full Clips — audio or MIDI — so nothing about a take is second-class) and an ordered comp-segment list. The pure `CompFlattener` rebuilds ordinary track clips from the comp — joins become representational equal-power crossfades exactly like manual M5 (i) crossfades, so the playback engine needed zero changes. Comp-member clips are protected: all nine clip-edit operations reject them with a message naming `take.flatten` as the escape hatch; tempo changes re-flatten every group inside the same undo step. Persistence is additive (old projects byte-identical), and `planMedia` now walks lane media so un-comped takes survive a save.
- Seven store ops (`groupTakes`, `setCompSegments`, `selectTake`, `removeTakeLane`, `flattenTakeGroup`, `moveTakeGroup`, `setTakeCrossfade`) with house undo-coalescing keys; overlap grouping uses connected-cluster semantics. 27 new tests across 4 suites: flattener determinism, crossfade join correctness, all rejection paths, persistence round-trips including old-project compatibility, lane-media planning, undo/redo.
- Verified independently: build 0 warnings, 721 tests in 84 suites (+27, +4). Control commands + MCP tools land in iii-b (the split defers the wire layer, matching the vii-a/vii-d pattern).

## 2026-07-06 — M5 (ii-e): stretch UI + listening spike — M5 (ii) time-stretch complete
- Stretching is now a direct-manipulation gesture: ⌥-drag a clip's right edge to time-stretch (snapped, live "6.0 beats · 1.50×" readout, "≈" grip cue when hovering with option held) — it routes through the store's window-invariant `stretchClip(toLengthBeats:)`, so the source window never shifts. Non-identity clips wear a persistent SF Mono ratio/pitch badge; outside the 0.75–1.5× quality band the border and badge glow amber; while the background render is pending an animated shimmer sweeps the clip (a 10 Hz bounded-window poll over the engine's pull-based status, kicked on any stretch edit so both gesture- and MCP-driven changes shimmer); failures get a red border + error dot. All gesture math lives headless in `DAWAppKit.ClipStretchModel`, whose preview is cross-checked against the real store — including the subtle ratio-clamp→length re-derivation. Patterns recorded in DESIGN-LANGUAGE.md.
- The listening spike (ACE-Step not yet installed, so the app synthesized its own material: an 8-beat polySynth phrase with chords and staccato transients, rendered→imported→stretched→bounced through the live app) produced 36 grid cells across {0.75, 0.9, 1.25, 1.5}× × {−5, −2, +3, +7} st × formant on/off. Every cell length-exact; true peaks −7.67…−1.69 dBTP with zero cells over 0 dBFS — the ii-b +4.9 dB sine overshoot did not reproduce on musical material (chordal peaks aren't phase-aligned). Headroom decision: no hidden per-clip compensation gain — Float32 end-to-end means nothing clips on disk, the amber hint surfaces the risk, and inter-sample taming belongs at a future master-bus true-peak stage. **signalsmith-stretch stamped provisional-final; no Rubber Band escalation** — final sign-off awaits human audition (grid + notes in the session scratchpad's stretch-listen/).
- Verified independently: build 0 warnings, 694 tests in 80 suites (+14, +1 suite), captures re-viewed (badges, amber tint, shimmer frames mid-render).

## 2026-07-05 — M5 (ii-d): stretch engine wire — clips actually play stretched
- The engine now honors the ii-c stretch fields end to end. `StretchRenderCache` renders full source files through the OfflineStretcher into content-keyed Float32 CAFs (`~/Library/Caches/DAWPro/StretchRenders/`; SHA256 over path/size/mtime/param bit patterns/engine version — geometry-free, so trim/split/move/tempo edits never invalidate), with a 250 ms debounce, per-clip latest-wins cancellation, same-key single-flight, and unique partial files committed by atomic rename. At schedule time a `StretchResolution` resolver seam swaps the rendered CAF in as the clip's source with `startOffsetSeconds × ratio` offset mapping — the fade bake runs unchanged on the stretched timeline; pending renders schedule silence (never wrong-speed audio); identity clips never touch the resolver, an exact structural bypass. Render completion invalidates the clip schedule and restarts through the existing `tracksDidChange` seam; `render.mixdown` awaits pending renders so bounces are WYSIWYG; snapshots surface transient `stretchRendering` / sticky `stretchError` per clip (omit-when-default).
- Verified independently: 680 tests in 79 suites (+8, +1 suite), 0 warnings, full E2E re-run ALL 16 checks. Measured: identity null test max diff 0.0 with zero resolver invocations; offset mapping bit-exact at frame 48 000 (caught by an amplitude-ramped fixture — a pure sine is period-aligned at 0.5 s and hid wrong offsets); stretched fades 0.0 vs reference; live bounce audible in the 2.1–2.9 s window that only exists stretched (RMS 0.0642 = full source level) and silent after; mid-play re-stretch keeps the transport playing through the restart seam (playhead 5.46 → 6.42 beats). Deferred: cache LRU eviction sweep; failed renders retry only on param re-edit.

## 2026-07-05 — M5 (ii-c): stretch domain + full wire surface
- Clips carry their stretch intent: `stretchRatio` (0.25–4), `pitchShiftSemitones` (±24), `formantPreserve` — additive omit-when-default Codable with the ClipDocument mirror, so pre-stretch projects stay byte-identical. Pure helpers codify the contracts: `sourceWindowSeconds(tempoBPM:)` (the derived source window — lengthBeats stays the timeline authority) and `isStretchIdentity` (the exact-bypass predicate ii-d consumes). Store ops: `setClipStretch` (nil-keeps-current per-field, MIDI clips rejected with a clear message, undo-coalesced) and the compound `stretchClip(toLengthBeats:)` — sets the new length AND scales the ratio so the source window stays constant, with the subtle case handled: if the ratio clamps, the length re-derives so window invariance survives. Split copies stretch params to both halves (the full-file cache makes junctions seamless); trim/move preserve them untouched (geometry-free keys).
- Wire surface: `clip.setStretch` / `clip.stretchToLength` commands and two MCP tools (58 total) teaching agents the absolute-ratio semantics, the 0.75–1.5× quality sweet spot, and that rendering is async once ii-d lands. The engine deliberately ignores the fields this slice.
- Verified: 672 tests in 78 suites (+20, +4 suites), 0 warnings, mcp-server clean, independent build + suite run, and a live wire smoke: ratio 99 clamps to 4 with pitch preserved, the compound op turned 2 beats into 8 with ratio 4, MIDI rejection surfaced verbatim, and both clips' snapshots round-tripped all fields.

## 2026-07-05 — M5 (ii-a, ii-b): stretch seam settled + signalsmith vendored with the OfflineStretcher facade
- The integration seam is settled (ARCHITECTURE entry): three additive clip fields with absolute tempo-independent ratios in v0; full-source-file content-keyed CAF renders cached OUTSIDE `.dawproj` (geometry-free keys — trim/split/move/tempo edits never invalidate, split points seamless because both halves read the same phase-vocoder output); at schedule time the stretched file simply replaces the clip's source with `startOffsetSeconds × ratio` mapping, so the fade bake runs unchanged; debounced latest-wins async rendering with silence-while-pending; identity is an exact structural bypass.
- ii-b lands the foundation: signalsmith-stretch v1.3.2 and signalsmith-linear vendored verbatim with licenses and pinned commits, compiled through a new `CSignalsmithStretch` flat-C shim target on Apple Accelerate (one C++ translation unit; package-wide C++17 caused no conflicts). The Swift `OfflineStretcher` facade uses upstream's own exact-length recipe (output-seek pre-roll → chunked process → flush), needs no post-trim, checks cancellation between blocks, and passes a FIXED RNG seed — making output deterministic, which is what makes ii-d's content-keyed cache coherent.
- Verified: 652 tests in 74 suites (+8, +1 suite), 0 warnings, independent build + suite run. Measured: stretched lengths land EXACT (144 000/72 000/96 000 frames); pitch preserved at 440.00 Hz through a 1.5× stretch; +7 semitones measures 659.00 Hz vs 659.26 analytic; cancellation fires at poll 2 of ~36; two runs bit-identical. One honest flag for the listening spike: 0.75× compression shows overlap-add overshoot (~+4.9 dB inter-sample); Float32 CAFs don't clip on disk, but ii-e should make a headroom call.

## 2026-07-05 — M5 (ii): time-stretch library decided — signalsmith-stretch (MIT)
- The M5 (ii) library gate is decided after a full evaluation (docs/research/2026-07-05-time-stretch-library-evaluation.md): **signalsmith-stretch** — MIT header-only C++11, the cleanest commercial-shipping license possible, a block buffer API that matches the proven bake-at-schedule-time pattern, explicit formant controls for ACE-Step vocal material, and credible quality evidence (a direct forum A/B preferring it over Rubber Band; production use inside Qt/FFmpeg and audiomentations). Integration shape: vendored with its signalsmith-linear FFT sibling (optionally on Apple Accelerate) behind a flat-C shim per the CAtomics precedent, wrapped in a Swift `OfflineStretcher` facade.
- Named fallback if vocal listening tests disappoint: Rubber Band's commercial Standard license (£590 attribution / £1,490 non-attribution under 10 employees — verified pricing; its GPL track is explicitly unusable for proprietary shipping). SoundTouch rejected on quality, Bungee OSS noted as a bake-off second opinion but vendor-capped below its paid tier, Apple's TimePitch units reserved for the future real-time preview path via the existing AU-hosting plumbing.
- The daw-architect is settling the integration seam next: stretch-render cache location/key/invalidation (including project-tempo changes), stretch-before-fade-bake ordering with post-stretch beat remapping, an async render job model (the AU-prepare precedent), and the preview boundary. Sub-item split follows the design.

## 2026-07-05 — M5 (i-d): waveform editor UI — M5 (i) complete
- Clips are now directly editable in the arrange view: drag a clip body to move it (snapped, with a beat readout), grab the ~6-point edge zones to trim, double-click or use the context menu to split (including at the playhead), pull the corner fade grips to draw translucent fade shading (bowed for equal-power, straight for linear; curve toggle in the context menu), and drag the cyan dB chip vertically for clip gain — seamless mid-play by the i-b design. A SNAP control in the arrange header offers Off/Bar/Beat/1/2/1/4, with Bar following the project meter (a new `ClipSnap` type — the piano roll's snap hardcodes a 4-beat bar). Audio clips render a cached peak-outline waveform computed off the main actor, windowed by `startOffsetSeconds` so trims and splits show the true source region.
- All snap math, hit classification, and edit-preview clamping live headless in `DAWAppKit.ClipEditModel` (mirroring the store's rules; 14 tests), and every mutation routes through the five i-a store methods so undo and drag-coalescing come free. The clip-editing pattern is codified in DESIGN-LANGUAGE.md.
- Verified: 644 tests in 73 suites (+14, +1 suite), 0 warnings, independent build + suite run, and the capture inspected independently: split visible as two clips with the waveform continuous across the boundary, equal-power fade shading on the outer corners, −6.0 dB chips on both halves, SNAP: Bar in the header. **M5 (i) — the waveform editor — is complete** (domain, engine, wire, UI; 44 new tests across the four sub-items). Next: M5 (ii) time-stretch & pitch-shift, starting with the library decision.

## 2026-07-05 — M5 (i-b, i-c): clip gain/fades render + full edit surface on the wire
- Fades and gain are now audible, per the settled design with zero new render-thread code. `ClipFadeBake` computes fade-in/middle/fade-out frame windows (contiguity guaranteed by construction for any playhead or fade shape) and multiplies the normalized envelope — evaluated per frame from the domain's own `Clip.envelopeGain` — into buffer copies of only the fade windows, reading through a bake-owned second file handle (the player's streaming instance has stateful read position; sharing would race). `scheduleAll` schedules faded clips as three contiguous pieces on the clip's existing player; unfaded clips take the pre-existing path byte-for-byte. `startOffsetSeconds` is now honored (split/trim are audible, bit-exact against reference). Gain rides `player.volume` with an in-place `clipGainChanged` path — mid-play gain edits never restart; fade/offset edits are schedule-affecting and correctly re-bake through the existing restart seam.
- The wire surface: `clip.split|trim|move|setGain|setFades` (split returns both resulting clips; fade-curve parse errors name the offending field; store rejections surface verbatim) plus five MCP tools (56 total) teaching AI agents arrangement editing, crossfade-by-overlap with the equal-power recommendation, and dB gain staging.
- Verified: 630 tests in 72 suites (+26 over i-a's 604: 12 engine + 14 control), 0 warnings, mcp-server builds clean, and the live E2E re-run independently — ALL PASS (split note partitioning, snapshot round-trips, save/reopen persistence, error surfaces). Engine evidence: analytic fade error exactly 0.0 with equal-power midpoint 0.70710677; unfaded null 0 differing frames; split + linear crossfade nulls against the unsplit render at 1 float ulp; −6.02 dB plateau matches analytic to 7 decimals; mid-fade scheduling starts at the exact partial-envelope value; two renders bit-identical.

## 2026-07-05 — M5 (i-a): clip edit domain — split/trim/move/gain/fades + settled engine design
- M5 opens with the headless clip-edit foundation: `Clip` gains `gainDb` (−72…+24), `fadeInBeats`/`fadeOutBeats` with `FadeCurve.linear|equalPower`, and `startOffsetSeconds` (new — audio clips previously always played from the file head; split/trim are impossible without a source offset). All fields are additive omit-when-default Codable, mirrored into ClipDocument persistence, so pre-edit projects save byte-identical. One pure evaluator `envelopeGain(atBeat:)` (equal-power = sin/cos quarter-cycle, gain and fades compose multiplicatively) is the single authority the engine (i-b) and UI (i-d) will reuse.
- Store operations, all clamped and undo-coalesced: `splitClip` (fixed-tempo source-offset math, MIDI notes partitioned with overhang truncation, fades redistributed — clip 1 keeps fade-in, clip 2 keeps fade-out), `trimClip` (leading edge advances the offset and drops outside notes; fades re-clamp), `moveClip`, `setClipGain`, `setClipFades` (proportional reduction preserving the in/out ratio when the sum exceeds clip length). Verified: 604 tests in 70 suites (+17, +3 suites), 0 warnings, independent build + suite run.
- The engine read path is settled (architect memo → ARCHITECTURE entry): clip gain rides live `AVAudioPlayerNode.volume` (seamless mid-play edits); fades bake at schedule time into three-piece scheduling (fade-in buffer / streamed middle segment / fade-out buffer) on each clip's existing player; crossfades are purely representational — overlapping clips sum on their own players, the engine has no crossfade concept. The per-strip envelope-stage alternative was killed with the exact math: post-sum it cannot express two simultaneous per-clip gains, so it is exactly wrong during any overlap.

## 2026-07-05 — M4 (viii-c, viii-d): PDC always-on — latency compensation v0 complete
- PDC is now automatic: every event that can move a latency number (chain edits, bypass, hosted-AU prepare, routing changes, rate changes, cold start) funnels through one choke point at the tail of `PlaybackGraph.applyParameters`, which maps strip state into the DAWCore planner and pushes each strip's ring target — and because offline render calls the same path on both sides of engine start, live/offline parity holds by construction. The wire now reports it all: per-strip `chainLatencySamples` (all-effects sum) and `compensationSamples` always, `compensationClamped`/`compensationSkewSamples` omitted unless meaningful, plus a project-level `pdc` object (stage targets, maxPathLatency, outputLatency structured so a future master chain adds in). No new command — snapshots ride the existing surface per the settled design.
- Verified: 587 tests in 67 suites (+9, +1 suite), 0 warnings, independent build + suite + an independently re-run live E2E, all 23 assertions: plan-correct fields while stopped (dry strip padded 240 to meet the limiter strip, bus honest zeros, omit-if-zero honored); bypass toggled mid-play left playback rolling and totals bypass-stable while ONLY the limiter strip's ring retargeted 0→240 (absorbing the absent delay); removal mid-play dropped every total to zero with the transport still advancing. Parity: the latent-chain + shared-send-bus project cross-diffs across two offline renders at bit-level 0.0 with all four paths coherently aligned (single hit, peak exactly 1.0).
- **M4 (viii) PDC v0 is complete** (viii-a planner, viii-b ring, viii-c wiring/reporting, viii-d parity). M4 now stands finished except the parked (i) live mid-play send-activation defect (workaround: stop/play). Next: M5 editing depth.

## 2026-07-05 — M4 (viii-b): the PDC compensation ring
- The delay that makes compensation real: `CompensationDelayState` — per-channel power-of-two Float rings (32 768/channel, 16 384-sample cap + quantum headroom), allocated only at prepare, driven by a heap-atomic target and reset flag (the bypassFlag pattern) with render-only cursor state. Inserted in ChainHostAU between the chain walk and the vol/pan automation stage, and in InstrumentRenderer on both the main and idle/silence paths so ring history stays continuous across idle quanta. Retargets declick by dual-reading the ring at old and new offsets and crossfading over ≤128 samples; resets (transport start/seek/cold start/offline start) zero the rings and snap without a fade. A clean-history zero-target fast path provably never touches the buffer — PDC is bit-inert until a real target arrives.
- `PlaybackGraph` gains `setCompensationTarget(_:forStrip:)` (the surface viii-c's recompute will drive) and arms ring resets exactly where chain resets already happen. One documented deviation: the v0 loop wrap flushes rings, because this engine's wrap IS a transport restart where chain tails are already cut — carrying ring history there would be the inconsistent choice; the spec's no-flush rule activates when a seamless wrap ships.
- Verified: 578 tests in 66 suites (+7, +1 suite), 0 warnings, independent build + suite run. Measured: uncompensated impulses at frames 4800/5040 collapse to a single coherent 0.5-amplitude peak at 5040 under the hand-computed plan; equal-target inverted render nulls to exactly 0 nonzero samples; 512 adversarial bit patterns (subnormals, odd mantissas) pass through the inert path bit-unchanged; the retarget fade region is bit-equal to the crossfade formula; a reset kills the 240-sample stale tail to exact zeros; two renders bit-identical.

## 2026-07-05 — M4 (viii-a): PDC plan math + settled latency-compensation design
- The PDC design is settled (architect spec, recorded in ARCHITECTURE.md): a per-strip preallocated ring delay inside ChainHostAU, upstream of the strip mixer's fan-out so one ring aligns the dry feed and every send tap at once; staged global-max alignment (tracks pad to T, buses to B, master hears T+B) with the honest admission that exact alignment for a direct-to-master track with sends is mathematically impossible with one delay per strip — that residual is reported per-strip, and vanishes in the canonical zero-latency-bus case. Bypass-stable totals (bypass never retargets the mix; the ring absorbs the difference), per-strip atomic u32 retargets (not snapshot republishes), dual-read crossfade declick, v0 output-delayed timeline, rings reset at transport/render start for exact offline parity. Item (viii) split into viii-a…d.
- viii-a lands the pure planner in DAWCore: `PDCPlan.compute(input:cap:)` over per-strip (chainLatencyAll, chainLatencyActive, kind, routing) → per-strip planned/applied compensation with clamped flag and residual, skew reporting, and T/B/maxPathLatency — deterministic, Sendable value types, garbage-tolerant (hostile hosted-AU latencies clamp instead of crashing). The engine ring (viii-b), recompute wiring + snapshot fields (viii-c), and parity harness (viii-d) follow.
- Verified: 571 tests in 65 suites (+15, +1 suite), 0 warnings, independent build + suite run + code review of the planner against the spec (worked example verbatim: comp(A)=240, comp(B)=0, T=240, B=0, zero skew). Ops note: the design cycle survived three agent stream-stalls (one watchdog kill + resume, one self-recovery mid-write) — the spec came out complete and source-verified despite them.

## 2026-07-05 — M4 (vii-e): arrange automation lane UI — automation v0 complete
- Automation becomes drawable: each track header grows a disclosure glyph (cyan glow when lanes are active) that expands an automation row under the clip lane — VOL/PAN target picker, green ON/OFF enable, delete, and a Canvas breakpoint editor sharing the arrange view's exact beat→x mapping. Click empty space to add a point, drag with a live value/beat readout, double-click or ⌫ to delete; segments render as a neon polyline (bloom-under-core glow, glowing dots, dashed neutral guide), dimmed when the lane is disabled; pan lanes draw neutral-white per the mixer's pan convention. Drags commit per-tick through `setAutomationPoints` for live audible feedback, riding the store's `automation.points:<laneID>` undo-coalescing key, with the draft re-seeded from the store's canonical sorted result at gesture end.
- All geometry, hit-testing, edit ops, and readout formatting live headless in `DAWAppKit.AutomationLaneModel` (16 tests); every mutation goes through the vii-a store methods — the view never touches `Track.automation`. A debug-tier `ui.showAutomation {trackId}` command (ui.showMixer precedent, not on the MCP surface) lets headless runs open the row for capture. The pattern is codified in DESIGN-LANGUAGE.md.
- Verified: 556 tests in 64 suites (+16, +1 suite), 0 warnings, and three live captures — the agent's (volume lane, five breakpoints landing exactly on bars 1–5 under the clip) plus two independent orchestrator captures: a pan lane drawn over the wire rendering hard-L→center→hard-R precisely against the center guide with correct hold-after-last-point, and the disabled state showing OFF + dimmed polyline. **This completes automation v0** (vii-a…vii-e); vii-f (touch/latch/write recording, sendLevel engine, AU-param lanes, master lanes, bezier) stays deferred.

## 2026-07-05 — M4 (vii-c): built-in FX-param automation lanes
- Automation now reaches inside the built-in effects: a lane targeting any of the nine kinds' parameters (delay mix, EQ band gain, compressor threshold, …) evaluates at each quantum start and stores straight into the effect's render-thread state before the chain walk — no locks, no allocation, no graph churn. `AutomationSchedule` grew POD `effectParam` breakpoint tracks (paramName resolved to a spec slot on the main actor; unresolvable lanes never reach the schedule; 64 tracks per strip, matching preallocated cursors), and `AutomationRenderer.storeEffectParams` shares generation-adoption helpers with the gain/pan path so the two consumers can never disagree on position.
- The per-kind lock-free-POD audit found a uniform hazard: every built-in's main-actor `apply` allocates (snapshot box + retire-bin append), so all nine got a lean render-thread setter that adopts pending snapshots through the same atomic slot `process()` reads, then re-derives through the existing per-kind math (pure libm/arithmetic everywhere; limiter lookahead fixed-size so lines never resize; delay/reverb/chorus time-type params are read-offset changes on MAX-sized lines). A value-type `AutomationParamOverlay` keeps knob (base) and automated (effective) params split, reverting to knob values within one quantum when a lane is disabled or removed — without it the effect stayed stuck on the last automated value forever.
- Verified: 540 tests in 63 suites (+7), 0 warnings, independent build + suite run. Measured: gain-lane staircase settles within 7.07e-09 of the analytic quantum-start value with exactly 0.0 intra-quantum spread; automated delay-mix bounce shows 0.0 in the dry region despite knob mix 0.7 (lane wins), bit-identical across two bounces; bypassed-effect-with-lane null 0 differing bit patterns; ghost-effect/out-of-range/NaN stores inert; mid-play lane edits republish with the MIDI schedule object-identical.

## 2026-07-05 — M4 (vii-b, vii-d): automation playback engine + control/MCP surface
- Volume and pan lanes now play back sample-accurately. Each strip owns a permanent `AutomationRenderer` publishing immutable `AutomationSchedule`s through the same atomic-pointer/retire-bin discipline as the MIDI scheduler; evaluation runs at the end of the chain walk (ChainHostAU for audio/bus strips, InstrumentRenderer for instruments) with per-sample linear ramps — the offline bounce matches the analytic ramp within 7.4e-9, and an automated pan lane sitting at center leaves buffers bit-identical. An enabled volume lane replaces the fader (the mixer node is pinned; mute/solo gating untouched); while stopped, the lane value at the playhead is applied WYSIWYG. Point edits during playback republish without any restart — proven by object-identity on the MIDI schedule across a mid-play edit, and live: editing points mid-loop dropped the meter with playback position advancing continuously. Live and offline render paths agree with cross-diff exactly 0.0.
- The wire surface: `automation.addLane|removeLane|setPoints|setLaneEnabled` round-trip the target and point shapes through the model's own Codable (the wire can never drift from persistence), malformed points fail with per-index errors, and v0 rejections (send-level, AU-param targets) surface the store's exact message. Snapshots carry each track's lanes via the existing Track encoding — zero extra wiring. Four MCP tools (51 total) tell AI agents how to draw rides, fades, and filter sweeps.
- Verified: 533 tests in 62 suites (+21 over vii-a's 512), 0 warnings, plus a 15/15 live E2E: drawn fade bounce hit the analytic envelope (mid-fade ratio 0.476 vs 0.5 expected), mid-play edits took effect with transport rolling, disabling the lane returned control to the fader, lanes persisted through reopen. Ops note: two agent stream-stalls this cycle were recovered via transcript resume + a fresh narrowly-scoped test agent; no work lost.

## 2026-07-05 — M4 (vii-a): automation domain model + store CRUD
- The automation foundation lands in DAWCore, headless: `AutomationLane` (one per target per track, store-enforced) with `AutomationTarget` (.volume/.pan plus persistence-stable-but-v0-rejected .sendLevel and .audioUnit-effect params — honest deferrals, not silent failures), canonically ordered `AutomationPoint`s (linear/hold segment curves; bezier is an additive future case), and one pure evaluator `value(atBeat:)` shared by UI, engine main-actor side, and tests. Values clamp through each target's existing range (volume/pan/send/effect-param specs); unknown targets are hard errors.
- Store CRUD ships with the full undo story: idempotent `addAutomationLane`, whole-array `setAutomationPoints` (4096-point cap, `automation.points:<laneID>` coalescing), enable toggle, and cascade rules — removing an effect, send, or bus drops the lanes targeting it inside the same undo step. Persistence is additive: `TrackDocument.automation` is omitted when empty so pre-automation projects save byte-identical, no schema bump.
- Verified: 512 tests in 60 suites (+19, exact contract test names), 0 warnings, independent build + suite run. Architect design (evaluation inside owned render code via immutable atomic-published schedules, fader-override rule, no-restart point republish) recorded as a settled ARCHITECTURE entry; engine read path is (vii-b), control/MCP surface is (vii-d).

## 2026-07-05 — M4 (vi): full mixer view
- The mixing console lands: a horizontal rack of channel strips in the glass-cockpit language — kind badge (audio green / instrument cyan), insert list with bypass glow dots and empty states, sends with destination + mini-fader, output picker (Master or any bus), pan knob, long-throw fader with unity detent and monospaced dB readout, Mute (red) / Solo (cyan) / Arm (amber breathing halo) buttons, and a live glowing meter per strip. Buses render as a visually divided group (no arm/sends/output, per the routing model); the MASTER strip is pinned right with an accent border and stereo meter. ARRANGE⇄MIX toggle in the header; every control drives ProjectStore directly so undo/coalescing come free.
- Pure strip-derivation/formatting/geometry logic lives in `DAWAppKit.MixerModel` (headless, 10 tests); the console itself is Canvas-drawn custom controls (`VerticalFader`, `PanKnob`, `SendMiniFader`), not stock AppKit. A minimal debug-tier `ui.showMixer` command (same tier as `debug.captureUI`, not on the MCP surface) lets headless runs drive the view for self-render verification. The strip anatomy and control-color semantics are codified in DESIGN-LANGUAGE.md as the "Mixer console" pattern. Master insert chain deferred until DAWCore grows a master effect chain; hosted-AU insert picking from the UI deferred (control-plane adds work today).
- Verified: 493 tests in 58 suites (+10), 0 warnings, and two independent live captureUI renders (agent's and orchestrator's) confirming full strip anatomy with real content — audio + instrument + bus tracks, a −3.1 dB send, EQ/Compressor/Reverb inserts — with no layout breakage.

## 2026-07-05 — M4 (v): AU effect hosting (headless)
- Third-party and Apple `aufx` Audio Units are now first-class inserts in every chain. `HostedAUEffect` adapts the AU pull model behind the `EffectRendering` seam: the incoming in-place buffers are served through a `@Sendable` pull block, rendered into a preallocated scratch buffer, and copied back — no allocation or main-actor state on the render path; a render failure passes dry rather than silencing the strip. The registry reuses the instrument hosting machinery (timeout-raced instantiate/prepare, strict-select on explicit add, placeholder-with-warning on project open), and adds are async-prepare → single-strip republish — playback never stops, the graph is never rebuilt.
- Real plugin latency lands on the wire: `latencySamples` comes from `au.latency` at prepare (AUPeakLimiter: 96 samples @ 48 kHz) and feeds the same per-effect plumbing the built-in limiter uses — PDC groundwork. AU fullState persists in `.dawproj` (set a parameter, save, reopen — it's restored). New `fx.listAudioUnits` command + `fx_list_audio_units` MCP tool (47 total); `fx.add` takes `kind: "audioUnit"` with a fourCC triple. Hosting bug found and fixed along the way: the AUv2 bridge leaves the input bus disabled by default, which fails renders with kAudioUnitErr_NoConnection until enabled before allocateRenderResources.
- Verified: 483 tests in 57 suites (+11), measured: AUDelay impulse delayed to frame 48001 (Δ1 sample from nominal at its parameter-tree-read 1.0 s default), AULowpass fullState round-trip restores 1234 Hz exactly, placeholder passthrough bit-exact. Live E2E 12/12: 23 aufx components listed, AUDelay echoes in the bounce window (0.2018 vs dry 0.0000), mid-play AUPeakLimiter add with continuous playback and latency 96 on the wire, bogus component rejected with a pointer to fx.listAudioUnits, hosted AU survives reopen.

## 2026-07-05 — M4 (iv): built-in FX pack 2 — reverb, delay, saturator, gate, chorus
- The space-and-color pack completes the built-in FX suite (9 kinds). Freeverb-topology reverb (8 damped combs + 4 series allpasses per channel, 23-sample stereo spread, up to 200 ms pre-delay, mid/side width control); stereo delay with integer-sample lines (echo lands at exactly round(timeMs×rate/1000) samples), feedback-path high-cut, and ping-pong crossfeed; tanh saturator with fixed −driveDb/2 dB level compensation (documented alias-honest, no oversampling in v0); stereo-linked noise gate whose ramps land exactly on 1/0 — fully open is bit-exact passthrough, fully closed writes true zeros; and a 2-voice chorus (sine LFO around a 15 ms center, 90° stereo / 180° inter-voice phase offsets).
- All five follow the pack-1 RT-safety conventions: atomic POD param publishes with a ≥1 s retire bin, prepare-time allocation, denormal flushes, zero added latency. Params live on the generic `fx.setParam` surface with schemas in `fx.describe`; MCP kind enum now spans all nine.
- Verified: 472 tests in 56 suites (+14), measured: delay echoes at samples 16800/15984/48 exactly with feedback ratio 0.5000000023, saturator H3/H1 = 0.316 with even harmonics at 1.1e-15, gate open-null 0.0 and closed residual 0.0, reverb tail decays ~32 dB from early to late window, all five render-to-render deterministic (diff 0.0). Live E2E 12/12: delay echoes ring in the 0.8–1.2 s bounce window (0.0909 vs dry 0.0000), mid-play reverb add with continuous playback, −1 dB gate silences to 0.0000 live, saturator+chorus chain audible, five-kind persistence round-trips.

## 2026-07-05 — M4 (iii): built-in FX pack 1 — EQ, compressor, limiter
- Three real processors join the insert chain: a 4-band parametric EQ (low shelf, two peaking bands, high shelf — RBJ biquads with Float64 accumulators; 0 dB bands are skipped so neutral settings null bit-exact), a soft-knee stereo-linked compressor (true peak detector, log-domain quadratic knee, one-pole attack/release, makeup), and a 5 ms-lookahead brickwall limiter whose output can never exceed the ceiling — guaranteed for every sample by construction (monotonic-deque sliding-window max), not just after settling.
- The limiter is the first effect with real latency: `latencySamples` (240 @ 48 kHz) now flows per-effect from the live DSP instance through the engine protocol and store to every snapshot and fx.* response — the PDC groundwork M4 (viii) will consume. All params live on the generic name/value surface with schemas in `fx.describe`/MCP (kind enum now gain|eq|compressor|limiter).
- Verified: 458 tests in 55 suites (+14), measured: EQ boost +11.99999999 dB on target band (+0.16 dB bleed at 100 Hz), compressor static curve −14.88 dBFS vs −15 theory with nominal 63% attack/release points, limiter impulse exactly 240 samples late, chain determinism nulls 0.0. Live E2E 14/14: mid-play EQ shelf cuts to ratio 0.026, heavy squash to 0.028, wire latency 240, boosted bounce peak exactly at the −6 dB ceiling (0.5012), all kinds persist.

## 2026-07-05 — M4 (ii): FX insert-chain architecture
- Every track and bus now has a pre-fader insert chain. The architecture answer to the M4 (i) live-mutation bugs: a permanent per-strip insert point (`ChainHostAU`, an in-process runtime-registered Audio Unit — spike-proven to instantiate synchronously from the SPM binary with bit-exact passthrough) walks an atomically published immutable chain snapshot. Chain edits — add, remove, reorder, bypass, param — are lock-free publishes and NEVER touch graph topology; instrument tracks process their chains inside the existing renderer. Effect DSP state survives reorders; un-bypass resets tails; every effect reports latency for future PDC.
- New `fx.*` command family (add/remove/reorder/setBypass/setParam/describe — `fx.describe` serves param schemas so agents can discover controls) + 6 MCP tools (46 total). Chains persist additively in `.dawproj` (unknown future kinds drop with a warning instead of failing the load). v0 ships the gain/trim effect to prove the seam; the real FX arrive in M4 (iii)/(iv) as `EffectRendering` implementations.
- Verified: 444 tests in 54 suites (+29), all chain-math nulls bit-exact (×0.5 gain, compose, bypass, empty-chain transparency on audio AND bus sandwiches, order-dependence). Live E2E 16/16 — the headline: mid-play `fx.add` gain 0.25 dropped the track meter to ratio 0.257 with playback position advancing continuously (no transport cycle, no glitch), live bypass/param/reorder all seamless, bounced gain ratio exactly 0.5000, persistence round-trips.

## 2026-07-05 — M4 (i): bus routing & sends (landed with one known live defect)
- Bus tracks are now real mix destinations: route any audio/instrument track's output to a bus (`track.setOutput`, nil = master) and add post-fader sends into buses (`track.addSend`/`setSend`/`removeSend` — one per destination, levels clamp 0–2). Engine: per-bus mixers + dedicated send-gain nodes behind AVAudioEngine fan-out connections; send LEVEL changes are provably non-structural (fader drags never interrupt audio — pinned); structural routing edits ride a quiesce → engine-bounce → transport-primitive resume. Solo v0 is solo-in-place (soloing a track keeps its send buses audible; soloing a bus keeps its feeders audible); bus deletion reroutes orphans to master and drops its sends in one undo step. Buses meter like tracks; persistence is additive (`outputBusId`/`sends`, pre-M4 bundles byte-identical); 4 new MCP tools (40 total).
- Verified: 415 tests in 50 suites (+31), incl. exact gain math (0.5 send × 0.5 bus = ×0.25 measured), bit-exact unity-bus null, solo matrix, both-restart-paths-identical regression. Live E2E 18/19; two live-only engine bugs were found by verification — a segfault removing a live bus (FIXED: fan-out severed before node teardown + engine bounce for structural rewires) and silent mid-play send addition (NOT yet fixed after two rounds — parked under Blocked; workaround: stop/play revives the send; everything else works live).
- Roadmap box (i) deliberately unchecked until the remaining defect clears.

## 2026-07-05 — M3 (vii): MIDI hardware input — M3 COMPLETE
- Plug in a MIDI keyboard and play: CoreMIDI input (UMP protocol-1.0, omni-connect, hot-plug) feeds armed instrument tracks live — through the poly synth, sampler, or a hosted AU — with ≤ one buffer of latency, even while the transport is stopped. The path is fully real-time-safe: the CoreMIDI receive thread pushes 16-byte events into per-renderer lock-free SPSC rings behind an atomically published fanout; render quanta merge live events with the schedule (schedule wins ties, so off-before-on survives); ring overflow flags an all-notes-off so a lost note-off can never stick a voice.
- Recording captures incoming MIDI on armed instrument tracks using the exact same host-time anchor as audio takes — audio and MIDI recorded together land in one "Record Take N" undo step. Open notes clamp at stop, retriggers close the previous note, pre-anchor (count-in) notes drop. Punch windows trim audio only in v0 (pinned by test). New: `midi.listInputs`, snapshot `midiInputs` + pollable `midiEventCount`, `midi_list_inputs` MCP tool (36 total); arming now works on instrument tracks.
- Found & fixed during integration: the CoreMIDI receive block inherited @MainActor isolation and trapped on the real receive thread — the project's documented Swift 6 pitfall, third occurrence; now pinned by an in-process CoreMIDI integration test with a real virtual source.
- Verified: 384 tests in 46 suites (+38). Live E2E 4/4 via a virtual MIDI source against the running app: hot-plug discovery, live-thru meter rise/decay while stopped, a recorded arpeggio landing as one clip with exact pitches on beats 0/1/2/3 (±0.1), and single-undo take removal.

## 2026-07-05 — M3 (vi-a): AU instrument hosting (headless)
- Third-party and Apple instrument plugins now play inside DAW Pro: AUv2/v3 music devices are discovered (`instrument.listAudioUnits`), instantiated asynchronously with a timeout race (a stalled plugin can never hang the app — it degrades to a silent placeholder with a readable `status`), and hosted behind the same `InstrumentRendering` seam as the built-ins. Our sample-accurate scheduler remains the only clock: note events reach the AU via `scheduleMIDIEventBlock` at in-quantum sample offsets; stop/seek flush maps to CC 123 + 120 (the render thread never touches the AU's ObjC surface — only two blocks captured at init).
- Component identity + full plugin state (`fullStateForDocument`) persist in `.dawproj` (additive, base64); projects referencing an uninstalled AU keep the descriptor intact and load silently with `status: "missing"`. `track.setInstrument` gains `audioUnit: {type, subType, manufacturer}` (strict selection with discovery hint); MCP adds `instrument_list_audio_units` (35 tools). `render.mixdown` became async end-to-end — offline renders instantiate fresh AU instances so live playback is never disturbed.
- Verified: 346 tests in 39 suites (+15), incl. DLS onset energy windows (pre-onset exactly 0.0, body RMS 0.062), note-off decay ratio 0.093, reset-flush 0.064 → 0.0002, AUSampler fullState round-trip (1290-byte plist → fresh instance ready), 100ms-timeout fallback. Live E2E 13/13: GM piano audible through hosted DLSMusicDevice (peak 0.10), stop flushes to 0.0000, save/reopen keeps identity and re-readies, bounced WAV peak 0.124.

## 2026-07-05 — M3 (v): built-in sampler
- Instrument tracks can now play audio files across the keyboard: `SamplerZone`s map files to key spans with a root pitch; playback resamples by `2^(Δsemitones/12)` (linear interpolation, native-rate buffers loaded immutably at reconcile — never on the render thread), first-matching-zone routing, one-shot mode for drums (ignores note-off), anti-click attack/release ramps. Zone changes rebuild the track's node; scalar tweaks (one-shot/attack/release/gain) update in place mid-note via the atomic-publish pattern.
- `track.setInstrument` gains a `sampler` object (zones wholesale-replaced like clip notes; field-path validation errors); the MCP tool mirrors it. Sampler zone files become project media: saved bundles copy them into `media/` (deduped, relative refs, counted in `mediaFilesCopied`) and reopened projects rewrite zone paths into the bundle.
- Verified: 331 tests in 36 suites (+22), incl. measured 440.000/880.000/220.000 Hz transposition through 44.1k→48k conversion, frequency-proven zone routing, exact-zero release tails, determinism nulls. Live E2E 16/16: two-zone kit audible (system sounds), mid-play one-shot/gain update gapless, save copied 2 zone files into the bundle, reopened bundle paths load and sound, bounced WAV peak 0.210.

## 2026-07-05 — M3 (iv): built-in poly synth
- The default sound of instrument tracks is now a real 16-voice subtractive synth: PolyBLEP-corrected saw/square (aliasing suppressed), triangle, sine; linear ADSR with exact-zero release tails; per-voice Simper SVF low-pass (cutoff/resonance); velocity scaling + output gain. Parameters live on the track as `InstrumentDescriptor` (additive model field, nil ⇒ default) and update in place mid-note via the scheduler's atomic-publish pattern — tweaking the filter never cuts held voices; switching instrument kind (polySynth ↔ testTone) rebuilds just that track's node.
- New `track.setInstrument` control command (partial update: omitted fields keep current values, numbers clamp) + `track_set_instrument` MCP tool (surface now 34). Snapshot always shows the resolved descriptor on instrument tracks, omits it on audio tracks. Undo label "Change Instrument" (coalescing); persistence is additive so older .dawproj bundles still open.
- Verified: 309 tests in 34 suites (+29), incl. Goertzel harmonic identity (square H2/H1 = 1.6e-16 vs saw 0.499), ADSR frame timing, 17-note oldest-steal, bit-identical determinism nulls. Live E2E 23/23: sine chord audible (RMS 0.168), mid-play cutoff change keeps sounding (RMS 0.164), mid-play kind switch survives, undo/redo, save/reopen keeps the descriptor, bounced WAV peak 0.783.

## 2026-07-05 — M3 (iii): sample-accurate MIDI scheduler
- MIDI clips now make sound. One `AVAudioSourceNode` per instrument track pulls from an immutable, pre-built event schedule published through a C11 atomic pointer (new `CAtomics` shim target) — the render thread never allocates, locks, or touches Swift shared state. Live playback derives sample time from the shared host-time anchor (host-delta epoch); offline render latches the first `mSampleTime`. Every stop/seek/tempo/loop-wrap/reschedule raises a flush flag → all-notes-off + `reset()` on the next quantum.
- New `InstrumentRendering` seam (AU-shaped for M3 vi) with `TestToneInstrument` (16-voice sine) and `EventCaptureInstrument` (test-only event ring). Cross-kind solo now works: soloing an instrument track silences audio tracks and vice versa. This settles the sequencer-clock decision in ARCHITECTURE.md.
- Verified: 280 tests in 32 suites (+20), incl. frame-exact event timestamps (on p60 @ sample 24000, off @ 48000 — exact `==`), 0-frame-tolerance onsets, bit-identical 512-frame-quantum captures, exact-zero null tests. Live E2E 8/8: audible arpeggio (track RMS 0.139), mid-play `clip.setNotes` reschedule survives, mute → 0.0000 RMS, bounced WAV peak 0.197.

## 2026-07-05 — M3 (ii): piano-roll editor + timeline lanes
- Timeline lanes replace the arrange placeholder: per-track clip blocks (green audio / cyan MIDI / violet AI), bar ruler, glowing playhead. Piano roll (bottom panel): keyboard sidebar, snap grid (Off/Bar/Beat/1/8/1/16), add/move/resize/select/delete, velocity lane, Simple ↔ Pro modes — all edits drafted locally, submitted as whole-array `setClipNotes` (one undo step per gesture).
- New `DAWAppKit` library target holds the testable geometry model (16 unit tests). New `debug.captureUI` control command: the app renders its own window to PNG (no Screen Recording permission needed) — now the standard UI-verification path; `selectClip` param opens the piano roll for capture.
- Verified: 260 tests in 29 suites; pixel-level inspection of a live capture — the sent arpeggio renders exactly (positions, lengths, velocity→brightness), selection glow, design-language chrome throughout.

## 2026-07-05 — M3 (i): MIDI domain + commands
- `MIDINote` model + `Clip.notes` payload (mutual-exclusion invariant with audio; canonical sort; clamped values; non-destructive clip bounds; overlaps legal — the scheduler contract is locked in now). Commands `clip.addMIDI` / `clip.setNotes` (whole-array replace — one agent call writes a melody) / `clip.remove` + MCP tools (33 total). Persistence: additive `notes` field, schema stays v1. Undo: per-clip coalescing key.
- M3 decomposed into 7 dependency-ordered sub-items (piano roll, scheduler, synth, sampler, AU hosting [needs Xcode license], MIDI input).
- Verified: 240 tests in 28 suites; live E2E 18/18 — arpeggio written in one call, verbatim validation errors, undo restores melodies, notes survive .dawproj round-trip. MIDI clips are silent by design until the scheduler + instruments land.

## 2026-07-05 — M2 COMPLETE: pinned-device recording fixed
- Root cause found by experiment (the parked theory was disproven): (1) the same-device guard compared uids against the input engine's PRIVATE AGGREGATE device ID, so it never skipped; (2) the pin-induced benign AVAudioEngineConfigurationChange (~65 ms post-start, engine still running) was treated as fatal, silently self-aborting every pinned take.
- Fixes: two-phase InputCapture start (pin → format → writer → tap), guard now compares against the system default input, config-change triage (benign vs fatal), plus a 1.5 s first-buffer watchdog with a readable abort error.
- Verified: 216 tests in 24 suites; live E2E 10/10 including a real take on a pinned device; agent also live-tested ZoomAudioDevice (frames flowed) and unpinned regression.
- **M2 (recording & persistence) is now fully complete** — nothing parked.

## 2026-07-05 — M2: undo/redo (snapshot journal)
- Full undo/redo across all 16 document mutators: before-state snapshot journal (architect overruled the roadmap's "command-pattern" wording — closure mutators can't be inverted; COW makes KB snapshots free), 800 ms keyed coalescing (fader drag = 1 step, 8 agent commands = 8 steps), 100-entry cap, load barrier on open/new, refused while recording, async take completion lands on top.
- `edit.undo`/`edit.redo` commands + `edit_undo`/`edit_redo` MCP tools (30 total) + Edit menu ⌘Z/⇧⌘Z with live labels; `undoLabel`/`redoLabel` in snapshots.
- Post-review fixes: state-dependent labels (Arm/Mute/Solo were literal "Arm/Disarm" strings).
- Verified: 215 tests in 24 suites; live E2E 13/13 — coalesced burst undone to origin in one step, real recorded take undone ("Record Take 1" → clip removed, WAV kept), redo semantics, mid-take refusal.
- **M2 complete** except the Blocked pinned-device capture item.

## 2026-07-05 — M2: .dawproj project persistence
- Self-contained `.dawproj` bundles: versioned project.json (schema v1, git-diffable, no transient state) + media/ with dedupe and collision suffixes; open/save/save-as/new with flush-by-default transitions; 30 s autosave (in-place for titled, JSON recovery bundle for untitled); ⌘N/⌘O/⌘S/⇧⌘S in the app.
- Commands `project.save/open/new` + MCP tools `project_save/open/new` (28 total). Undo/redo seams left ready (markDirty funnel, applyOpenedState primitive).
- Verified: 174 tests in 21 suites; live E2E 15/15 — on-disk schema inspected, dedupe (2 clips → 1 file), idempotent re-save (0 copies), reopened project audible via meters, missing-media warnings, newer-version rejection.

## 2026-07-05 — M2: metronome + count-in
- Synthesized click (downbeat 1600 Hz accented, beats 1000 Hz) scheduled sample-accurately on its own player node, with top-up while rolling; `transport.setMetronome` command + `transport_set_metronome` MCP tool (25 total) + CLICK chip. Count-in (0-4 bars) delays the record anchor — clicks fill the gap, the take never includes them.
- Verified: 152 tests in 20 suites (offline: clicks at exact beat frames, correct pitches, 3/4 downbeats); live E2E 9/9 — click audible on an empty project via meters, silent when off, real count-in take excluded exactly the count-in duration.

## 2026-07-05 — M2: punch in/out recording
- `transport.setPunch` command + `transport_set_punch` MCP tool (24 total) + PUNCH chip: recording keeps only audio inside [inBeat, outBeat]; the take clip lands at punch-in with the window's length. Validation: range checks, refused mid-take, refused when the window is behind the playhead.
- Writer generalized to a two-sided accept window with a separate anchor-relative offset reference (one placement bug found by live E2E and regression-locked as W5); degrades honestly to a full take on timestamp-broken devices.
- Verified: 139 tests in 19 suites; live E2E 8/8 with REAL capture — punch [1,2] @120 BPM from beat 0 produced a clip at exactly startBeat 1.000, lengthBeats 1.000.

## 2026-07-05 — M2: input device enumeration/selection (partial)
- `input.listDevices` / `input.setDevice` commands + `input_list_devices` / `input_set_device` MCP tools (23 total) + themed input-picker chip in the header. CoreAudio HAL enumeration verified live (4 real devices found, default flagged); selection/validation/reset all verified over the control port; RecordingWriter hardened against invalid input timestamps (regression-tested).
- KNOWN ISSUE (see ROADMAP Blocked): recording with a *pinned* device captures zero frames — unpinned recording unaffected (re-verified live). 123 tests in 19 suites green.

## 2026-07-05 — M2: audio recording (Stage A)
- Arm tracks (`track.setArm` + `track_set_arm` MCP tool, "R" chip) and record the default input (`transport.record` + `transport_record` tool, wired record button; 21 MCP tools total). Record = capture + play; takes land as clips on every armed track (one shared WAV, host-time-aligned to the player start anchor, ±1 frame).
- Architecture: separate input-only AVAudioEngine (playback survives input device changes), serial-queue RecordingWriter (Float32 WAV at device rate, ≤2 ch), seek/tempo refused mid-take, loop wrap suspended while recording. Known v0 gap: no round-trip latency compensation (M4 PDC).
- Verified: 110 tests in 17 suites (writer bit-exact vs on-disk WAVs, alignment trim ±1 frame, permission/state-machine coverage); live E2E 10/10 including a REAL capture — 1.5 s of mic input became clip "Vocal Take 1" via the control protocol.

## 2026-07-05 — M1 COMPLETE: render.mixdown + test harness
- `render.mixdown` command + `render_mixdown` MCP tool (19 total): offline bounce to Float32 stereo 48 kHz WAV, default duration = project length + 0.5 s tail, default temp path, readable errors ("nothing to render…").
- Engine test harness closed: determinism null test (two renders per-sample identical, exactly 0.0), unity-graph-vs-source null, gain assertions.
- Verified: 88 tests in 15 suites; live E2E 8/8 — bounced WAV confirmed by afinfo (2.0015 s, 48 kHz, 772 KB), bit-exact write round-trip.
- **M1 (core audio engine) is complete**: import, sample-accurate multitrack playback, transport with loop + broadcast, per-track metering, wired mixer, offline mixdown.

## 2026-07-05 — M1: mixer parameters wired to engine
- Track volume/pan/mute/solo now audibly control the engine (per-track mixer nodes; parameter changes never interrupt playback). New master volume: `mixer.setMasterVolume` command + `mixer_set_master_volume` MCP tool (18 total) + vertical glow fader in the transport bar; `masterVolume` in snapshots.
- Two AVFoundation quirks found by experiment and worked around: mixer pan set before `engine.start()` is discarded, and same-value pan writes are swallowed by the property cache after an AU reset.
- Verified: 74 tests in 13 suites (offline renders: volume 0.5 → RMS exactly halved, mute/solo/master-0 → digital silence, pan −1 → right channel 0.0); live E2E 7/7 via snapshot meters (incl. pre-master vs post-master metering distinction).

## 2026-07-05 — M1: per-track + master metering
- Per-track meter taps on the track mixers → glowing MiniLevelBars in the track list; meters now included in `project.snapshot` (`meters.master` + `meters.tracks` keyed by track UUID) so AI agents can verify audio is actually rendering.
- Meters reset to silence on stop; entries dropped with their track.
- Verified: 64 tests in 12 suites (offline meter RMS within 5e-5 of theoretical); live E2E 5/5 — track + master meters register signal during looped playback over the control port, silent after stop.

## 2026-07-05 — M1: loop region + transport broadcast
- Loop region: `transport.setLoop` command + `transport_set_loop` MCP tool (17 total) + LOOP chip in the transport bar; engine wraps at loop end via the restart primitive (~60 ms gap, documented v0).
- Transport broadcast: control clients now receive pushed `{"event":"transport",...}` frames — immediately on state changes, ~4 Hz while playing — instead of polling; MCP bridge tolerates event frames.
- Verified: 59 tests in 11 suites; live E2E 8/8 (wrap bounded at loop end, 22 events over 5.5 s, loop-off passthrough, push-on-change while stopped).

## 2026-07-05 — M1: sample-accurate multitrack playback
- New engine core: per-clip AVAudioPlayerNodes under per-track mixers (overlapping clips sum), schedule math in exact file-rate frames, shared host-time start anchor, stop-reschedule-resume primitive for seek/tempo/mutations during playback, engine-derived playhead at 30 Hz.
- `OfflineRenderer` renders the same graph headlessly (manual rendering mode) — now the sample-accuracy test harness, later `render.mixdown`.
- Engine protocol: `transportDidChange` → four intent methods (`startPlayback/stopPlayback/seek/setTempo`) + `playheadHandler`.
- Verified: 48 tests in 10 suites; measured onset error 0 frames same-rate, +17 frames through 44.1→48 kHz SRC (±64 spec, pitch-verified); live E2E 7/7 (playhead rate, import-while-playing, seek/tempo mid-playback, stop/resume).
- Notable fix found during implementation: track mixers must connect at explicit graph-rate format — `format: nil` leaves them at 44.1 kHz and silently double-resamples.

## 2026-07-05 — M1: audio file import
- `clip.addAudio` control command + `clip_add_audio` MCP tool (16 tools total): import wav/aiff/mp3/m4a onto audio tracks; length auto-computed from duration at current tempo, append-after-last-clip default, `atBeat` override.
- New: `AudioFileInfo`/`MediaImporting`/`ProjectError` (DAWCore), `AudioFileImporter` via AVAudioFile (DAWEngine), clip-count badges in the track list.
- Verified: 29 Swift tests in 7 suites; live E2E 10/10 against the running app incl. real AIFF import (1.5 s → 3.003 beats @ 120 BPM), readable errors for missing files and non-audio tracks.

## 2026-07-05 — M0 Foundation
- SPM monorepo: DAWCore (domain), DAWEngine (AVAudioEngine + metering + test tone), DAWControl (loopback WebSocket control server, 12 commands), AIServices (Anthropic/OpenAI/Suno/GPT-Image clients), DAWApp (SwiftUI glass-cockpit shell).
- MCP server (`mcp-server/`, TypeScript): 15 tools — 12 bridged DAW commands + generate_lyrics / generate_song_suno / generate_image.
- 17 Swift tests passing (`./scripts/test.sh`); live E2E: 11/11 control-protocol checks against the running app.
- Fixed: Swift 6 isolation trap in the metering tap (`@Sendable` on the AVFAudio tap closure).
- Docs: VISION, ARCHITECTURE, ROADMAP (M0–M9), AI-INTEGRATIONS, DESIGN-LANGUAGE. Agent fleet (8) + skills (6).
