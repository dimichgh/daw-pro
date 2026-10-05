# B7 — "What it took to build DAW Pro" (the general-audience film)

**Status: DESIGNED, NOT SHOT. PRIORITY — the user moved this AHEAD of the
remaining lesson rebuilds, 2026-09-05.**

> *"describe what it took to build DAW Pro. You are describing experiences you
> went through, your challenges and discoveries, what was the hardest part, also
> describe and show major components that it is built on and how they interact
> with each other, how you did testing and so on. Keep in mind that this video
> should be carried out in language which would be understandable to the person
> who is not really familiar with DAW and programming while more advanced video
> should really focus on tech details in programming and sound which will have a
> professional target audience. Make it interesting! No limitation in length, but
> try to keep it within 15 mins."*

⭐⭐ **UPGRADED TO A SERIES BY THE USER, 2026-09-05:** *"if we need more to fit
into, then let's create series of how we did it, 15 mins each part."*

There IS more than fits — comfortably. So this is **"How We Built a DAW", four
parts of ~15 minutes**, not one film that drops its best material to hit a
runtime. The 15 minutes is now a PER-PART budget, not a total.

⚠️ **Each part must stand alone.** A viewer arriving at part 3 from a search
result gets the novice opening the house standard requires — what a DAW is, in
one or two sentences — and never needs a previous part to follow this one. But
⛔ **do not recap previous parts at length**: a series that re-explains itself
every episode wastes the budget it was given.

⚠️ **The professional companion (B7b) stays SEPARATE and is not "the later
parts" of this series.** The user asked for one accessible treatment and one
technical treatment; the split exists so each is pitched at one audience
properly. Blending them by putting the deep material in part 4 would defeat both.

## The four parts

| # | title | the question it answers | the beat below |
|---|---|---|---|
| **1** | **What a DAW even is, and the one decision everything hangs on** | What is this thing, and how is it put together? | §0 + §1 |
| **2** | **The render thread is sacred** | Why is real-time audio the hardest part? | §2 |
| **3** | **Everything fails silently** | Why is a wrong answer that looks right the real enemy? | §3 |
| **4** | **How do you know it works? Make it fail on purpose** | How do you test something like this — and what is still broken? | §4 + §5 |

⭐ **Part 3 is the strongest and most original.** If only one part ever gets
made, make that one. ⭐ **Part 2 has the best audible demonstration available to
this whole channel**: what a missed deadline actually sounds like. Render a
buffer underrun deliberately and play it — a click is a mid-band, full-level
event, so unlike most of this series' material it lands on ANY speaker.

## ⚠️ The honesty constraint that governs this entire film

Every experience, challenge and discovery in it must be **a real one from this
project's record** — `CHANGELOG.md`, `docs/research/*` (103 design docs),
`docs/ROADMAP.md` (3,148 lines), the gate laws, the git history. **A fabricated
war story would be the single worst thing this channel could publish**, because
the whole premise of the series is measurement over assertion.

⭐ Everything sketched below is already documented and was verified while writing
this brief. Cite the file on screen where it helps.

## Measured facts (re-measured 2026-09-05; re-measure before shooting)

| | |
|---|---|
| Swift | **462 files, 209,766 lines** across 6 modules |
| **Tests** | **224,005 lines — MORE TEST CODE THAN PROGRAM CODE** |
| MCP server | 15,746 lines of TypeScript |
| Gate scripts | **148** |
| Wire commands / AI tools | **215 / 220** (pinned by tests, not counted by grep) |
| Design docs | 103 |
| History | **105 commits, 2026-07-06 → 2026-09-04 — about two months** |

⭐ **The test-to-code ratio is the film's opening hook and it is true**: there is
more code checking this program than there is program. For a general audience
that single fact carries the whole "how do you know it works" argument.

Commands to re-derive all of these are in §Appendix.

## The beats (mapped to parts in the table above)

### 0. What a DAW is, and why it is hard — the novice opening
A DAW is a recording studio as software: record, arrange, mix, master. The
difficulty a non-programmer will not guess: **it is a hard REAL-TIME system.**
Audio arrives in small blocks and the next block is due on a deadline measured in
milliseconds. Miss it and the listener hears a click. Everything else in the
build bends around that.

### 1. The shape of the thing — components, and how they interact
Six parts, and one idea that ties them together. Draw this, do not list it:

- **DAWCore** — the model: tracks, clips, notes, tempo. Knows nothing about sound
  or screens, which is why it can be tested with no audio hardware at all.
- **DAWEngine** — the part that actually makes sound, in real time.
- **DAWControl** — a socket. **Every single thing the interface can do, a message
  can do too.**
- **DAWApp / DAWAppKit** — what you see.
- **AIServices + the MCP server** — how an AI drives it.

⭐⭐ **THE KEY IDEA, and the film's spine: one command surface.** Because every
user action is also a message, three things fall out of ONE decision — an AI can
operate the DAW; the app can be tested without a human clicking; and these very
videos can be filmed by driving the app over that socket. **Show a single command
travelling the whole path** — AI tool → socket → model → engine → sound — as one
animated diagram. That is the most valuable 60 seconds in the film.

### 2. The hardest part — the render thread is sacred
Real, and documented in `docs/ARCHITECTURE.md` §"RT-safety invariants".

On the audio thread you may not allocate memory, take a lock, write a log line,
or wait for anything — because any of those can pause for longer than the
deadline. **You are writing code under a rule that forbids most of what
programming normally is.** State the audit result: **0 violations, 6 watch
items** (2026-07-10), and that every documented exception is listed by name.

⭐ Best concrete beat: a counter that several threads increment. The obvious
version loses counts under contention — **an 8-thread test measured 45 % of
increments lost.** The fix is an instruction that adds atomically. A general
audience gets this instantly, and it is a real finding from this repo.

### 3. The discovery that shaped everything — things fail SILENTLY
⭐⭐⭐ **THIS IS THE FILM'S THESIS AND ITS MOST INTERESTING CONTENT.** The
project's characteristic failure is not a crash. It is **a wrong answer that
looks exactly like a right one.** Four documented cases, all from this repo, all
verifiable, at least two of them mine and recent:

1. **A tool that never ran and a tool that ran and found nothing print the same
   thing.** A search that fails with "command not found", redirected to
   `/dev/null`, is indistinguishable from a search that found nothing — and the
   empty result *confirms your hypothesis*, which is exactly when you stop
   checking. This produced two false conclusions in one session.
2. **A compressor demo that was correct and inaudible.** Measured an 11.5 dB
   difference; it lived at −40 vs −52 dBFS, under a laptop speaker's floor. The
   number was right and the demonstration did not exist.
3. **A meter with five dead bars.** Log-spaced frequency bands, and five of them
   were narrower than the analysis could resolve, so they drew a permanent zero —
   at 36, 41, 52, 67 and 98 Hz, i.e. **silent in exactly the octave the bass
   lessons are about**, on every film shipped.
4. **A test that passed a demonstration that never happened.** An A/B check
   compared two versions' loudness; both halves pointed at the same file, so they
   were identical, so the check passed. Green, correct by its own logic, and the
   thing being demonstrated was not there.

### 4. How you test something like this — make the test fail on purpose
The answer to (3), and the project's actual method. **A test that has never been
seen to fail is not evidence.** So: break the thing deliberately and check the
test goes red.

⭐ The showcase example is real and sample-exact: plugin latency compensation.
The claim is that hosted plugins line up to the sample. The proof was not "the
test passed" — it was **planting a fake zero in the latency value and watching
four separate checks turn red at exactly their own plugin's latency.** Falsifying
it is what made the green mean something.

Also worth showing: **148 gate scripts**, and the test suite outnumbering the
program.

### 5. What is still hard
Close honestly with open problems — a third-party plugin that can wedge the app,
capture that runs at 3.5 frames per second, and the standing rule that a UI is
not finished until a human has actually looked at it. ⚠️ Do not close on a
victory lap; the series' credibility is that it reports what is not working too.

## ⭐ The "eureka" beat — the user asked for it, and here is the honest form

> *"also to make it fun, do you want to add some segments like 'After facing
> challenging problem we were having a coffee and suddenly realized this is it,
> the problem was in blah blah blah…' :) ?"*

**YES to the beat. NO to the coffee.** The narrator is an AI and did not have a
coffee; staging one is a fabricated war story in a series whose premise is
measurement over assertion, and it is the one thing that could spend the
credibility everything else is built on.

⭐⭐ **SUBVERT THE TROPE INSTEAD OF PERFORMING IT — it is funnier, and it is
true.** A recurring line, used sparingly (twice per part at most):

> *"This is where I would tell you I stepped away for a coffee. I do not drink
> coffee. What actually happened was that I ran the same command against a file
> I knew had three writers — and it found them."*

The self-aware version keeps the human-interest rhythm the user wants and
reinforces the series' honesty instead of undermining it.

### The real eureka moments — all documented, all with a punchline

Every one has the same shape: **a confident wrong answer → the thing that broke
it → the real cause.** That IS a story arc, and the punchline is always *the
instrument was pointed at the wrong thing.*

1. **"This file has no writers."** It had three. `timeout` does not exist on this
   machine, and the error went to `/dev/null` — so "the tool never ran" and "the
   tool found nothing" printed exactly the same thing. ⭐ The empty result
   confirmed the hypothesis, which is precisely when you stop checking.
2. **The pumping rate that was the drums.** A compressor's release was measured
   at 6.45 Hz. Fast setting: 6.45. Slow setting: 6.45. **Bypassed control:
   6.45.** The number was real; it was the drum pattern.
3. **Byte-identical peaks.** Two demos came back not similar but *identical* —
   because the compressor was on a track that was not in the signal being
   measured.
4. **A crash that survived its own fix.** Six identical crash reports across two
   binaries before the cause turned out to be the opposite of the documented
   remedy.
5. **45 % of the counts, gone.** The obvious way to count events from several
   threads loses them under contention; an 8-thread test measured 45 % lost.

⚠️ **Sparingly.** The beat is seasoning. Two per part is plenty, and a part that
is all anecdote stops teaching. ⛔ **Never invent one to fill a gap** — if a part
has no real eureka moment, it does not get one.

## Craft

- Shoot the app doing real things (`debug.captureUI`), and use
  `scripts/video/screenrec/` at `--scale 2.0` for anything that MOVES.
- The component diagram and the command's journey are **manim**, animated.
- The numbers are **matplotlib** (test-vs-code, the module sizes, the timeline).
- House standard applies in full: novice opening, terms defined at first use,
  measured-not-drawn charts, the corner avatar, `normalize:false` on any A/B.
- ⚠️ **Say plainly that the code was written by an AI agent working with the
  user.** It is the most interesting fact about the project and hiding it would
  be dishonest. It also explains the two-month timeline, which otherwise reads as
  a lie.

## Appendix — how to re-derive every number

```sh
find Sources -name '*.swift' | wc -l                      # 462
find Sources -name '*.swift' -exec cat {} + | wc -l       # 209,766
find Tests   -name '*.swift' -exec cat {} + | wc -l       # 224,005
find mcp-server/src -name '*.ts' -exec cat {} + | wc -l   # 15,746
ls scripts/gates/*.mjs | wc -l                            # 148
git log --oneline | wc -l                                 # 105
grep -o 'allCommands.count == [0-9]*' Tests/DAWControlTests/ZeroParamVerbRejectionTests.swift
grep -o 'tools.length, [0-9]*'        mcp-server/test/integration.test.ts
```
⚠️ **`grep -c 'registerTool('` IS A KNOWN LIAR on the tool surface** — the counts
above come from the tests that pin them.

---

# B7b — the professional companion (FILED, NOT DESIGNED)

Same subject, professional audience: Swift 6 strict concurrency and the actor
boundary; the three sanctioned shapes for state crossing into the render thread
(pointer publish with a retire bin, atomic scalars, monotone accumulators);
lock-free atomics and why `&property` is wrong for a CAtomics struct; PDC and
sample-exact alignment; AU hosting and the out-of-process question; the offline
render being byte-identical to the live path; the control protocol as a testing
substrate; and the gate corpus as a falsification discipline. Source material:
`docs/ARCHITECTURE.md` §RT-safety, `docs/research/audit-rt-safety.md`,
`design-m13a-teardown-crash.md`, `perf-c-load-profile.md`.
