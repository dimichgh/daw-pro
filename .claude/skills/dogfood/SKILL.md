---
name: dogfood
description: Make a real piece of music end to end using the product's own agent surface, and write down what hurts. Run after a major update, NOT every test run. Finds the defects that pass every gate — including regressions we shipped hours earlier. Produces a friction log in docs/dogfood/ and roadmap items for what could not be fixed in-session.
---

# Dogfood

**We make the song ourselves.** Not a smoke test, not a scripted probe — a real piece of
music, start to finish, using the same tools an outside user's agent would use, and an
honest log of every place the product got in the way.

The user's own framing, 2026-08-23:

> *"instead of having sax team external loop, why not start creating songs ourselves and
> experience the issues and difficulties, not just doing small test cycles. We could run it
> as an experimental phase to evaluate experience. This should not be run every time we run
> tests, but after major updates we should have this cycle."*

And, when the first attempt was scoped as capability-building rather than use:

> *"not just run, but run, troubleshoot and improve, tools, agents, skills, code and etc."*

That second sentence is the mandate: **fix what you trip over, in the same session, where
you can.** A session that only files tickets has done half the job.

## Cadence

**After a major update. Not every test run.** This is expensive on purpose — an hour of
real use, not a five-minute check. Running it every cycle would make it a gate, and a gate
is precisely what it must not be: gates measure what we already thought to measure.

## ⛔ Before you start: name your project

**USER RULE, 2026-08-23, verbatim:**

> *"this is your project with tests, you can remove it, but you better always create a new
> project and give it a name so it will get your known ownership"*

Said after a directory literally named `undefined/` — 1.6 MB, four files, **committed to
git**, containing a `.dawproj` — was found in the repo root, and I flagged it rather than
deleting it because I could not tell whether it was the user's real work or my own leftover.

So, before the first note:

- **`project_save` to an explicitly NAMED path you choose**, never an inferred or default
  one. Pattern that works: `~/Music/DAW Pro Dogfood/<YYYY-MM-DD> <Name>.dawproj`.
- **Name it so ownership is obvious on sight** — a date and a purpose. The point is that a
  future session, yours or theirs, can tell at a glance whose artifact it is.
- **Keep scratch renders in the session scratchpad**, never the repo.

**Ambiguous ownership converts cleanup into a question for the user.** That is the whole
cost, and it is entirely avoidable.

## The loop, in order

The ordering is load-bearing. Session 1's single most valuable finding came from step 3,
not from making music.

### 1. Make something real, end to end

A whole short piece — an arrangement, not a bar. Multiple tracks, real instruments, a
render at the end. Use the **agent surface** (the `daw-pro-music-team` plugin's agents and
the MCP tools), not internal Swift APIs: the point is to walk the path a user's agent walks.

Reach the end. A session that stops at "the notes are in" never exercises rendering,
loudness, bouncing, or saving — and those are where the interesting defects live.

### 2. Log friction AS IT HAPPENS, not afterwards

Open `docs/dogfood/<YYYY-MM-DD>-session-N.md` **first** and write into it while you work.

Reconstructed friction is sanitised friction. The moment where you had to guess at a
parameter, or re-read a description twice, or work around something — that is the finding,
and it evaporates the instant you route around it. Write it down before you fix it.

**What counts as a finding.** Anything that made the work harder than it should have been:

| class | mark | example from session 1 |
|---|---|---|
| documentation that is wrong or stale | 📄 | the shared wire reference said we cannot slur, on the morning we shipped slurring |
| an actual bug | 🐛 | a widened schema silently re-admitted nonsense for every other parameter |
| a wall — the thing cannot be done at all | 🧱 | the sampler cannot be smoke-tested; a fresh project ships no sample content |
| friction — it works but it costs too much | 😖 | every MIDI write echoes all its notes back, on the hot path of composing |
| a meta-finding about our own process | 🔍 | *see M2 below* |

Number them (F1, F2, …) so the roadmap and the log can cite each other.

### 3. FINISH THE LOOP — this is where the regression was

**Making the music is not the whole product.** The step people skip is the one that pays:

- **Regenerate the plugin bundle** (`claude-plugin/server/index.mjs`) so it matches
  `mcp-server/src/`, and **verify the bundle carries the change** by grepping it for a
  distinctive string, with a positive control against the source. A regenerate command
  that returned is not proof the bundle changed.
- ⭐⭐⭐ **RE-RUN BOTH TEST SURFACES.** This tree has **two independent** ones:
  - Swift — `./scripts/test.sh` (never bare `swift test`)
  - MCP — `cd mcp-server && npm test`

  **Both, after the LAST change that touches either.** A green Swift run says nothing
  about a zod schema; the defect can live entirely in TypeScript. And an agent's earlier
  MCP figure is stale the moment a later leg edits `server.ts`.

  This law was bought at full price: on 2026-08-23 the Swift suite was re-run after the
  final leg and the MCP suite was not, a **real regression shipped in that commit**, and an
  agent's hours-old `467/467` was quoted in the commit message for a tree where it was no
  longer true.

- ⛔⛔⛔ **RESTART THE SERVING PROCESS, AND VERIFY THE RESTART FROM THE CLIENT SIDE.**
  **VERIFYING THE ARTIFACT IS NOT VERIFYING WHAT IS RUNNING**, and the grep-the-bundle step
  above does NOT cover this — it passes while being completely wrong.

  Bought 2026-08-24, session 2: the MCP server process had started at **16:41:06** and
  `dist/server.js` was built at **22:51:31** — a **6 h 10 min** gap. The source was right,
  the build was right, `grep` found the new parameter in both, **and the live tool schema
  did not have it**, because the node process had never read the file. An entire session ran
  against a tool surface six hours stale.

  ⚠️ **The failure is SILENT and it mimics "that feature was never built"** — which is the
  exact wrong conclusion. Only reading the source proved otherwise.

  So: after regenerating, **restart the server process**, then confirm from the CLIENT that
  a schema field which did not exist before is now present. A file on disk is not evidence
  about a process that started before it.

  ⭐⭐ **THERE IS NOW AN INSTRUMENT FOR THIS — USE IT INSTEAD OF INVENTING A PROBE (m31-a,
  shipped 2026-08-28).** `app_connection_info` reports the server's OWN build identity:

  | field | meaning |
  |---|---|
  | `serverProcessStartedAt` | when the running process booted |
  | `serverBuildMtimeAtStartup` | `server.js` mtime **as the process read it** |
  | `serverBuildMtimeNow` | that same file's mtime **right now** |
  | `serverBuildMayBeStale` | the two disagree — the diagnosis, not a hint |

  **`serverBuildMayBeStale: true` means the process is serving code older than what is on
  disk.** That is the whole 6-hour bug, reported as a boolean instead of reconstructed from
  timestamps by hand.

  ⚠️ **AND IT IS ITS OWN POSITIVE CONTROL, WHICH IS WHY IT BEATS A HAND-BUILT PROBE.** These
  four fields did not exist before m31-a. If `app_connection_info` comes back WITHOUT them,
  you have not restarted — you are talking to the old process, and it just told you so. A
  probe that cannot distinguish "restarted" from "never restarted" is the failure this whole
  entry is about; this one cannot fail that way.

  ⛔ **Do not read these off a bundle grep.** The point is what the PROCESS answers, not what
  the file contains — that confusion is the original defect.

- **Verify the session's own shipped work in the running app**, not just in the suite. A
  feature that has only ever been exercised by tests has not been used.

### 4. Fix what you can, in the same session

Documentation defects, tool descriptions, schema gaps, error messages: fix them now. You
have the context, and the fix is usually smaller than the ticket describing it.

**Anything you fix must still go in the log**, with its mechanism — the log is the record
of what the product was like, not just of what remains broken.

### 5. File the rest, honestly

Everything you could not fix becomes a roadmap item with its mechanism, not just its
symptom. Route it (`Route: mcp-integration-engineer`, etc.). Say plainly when something is
unverified.

## Hygiene, at the end and non-negotiable

- **Kill the ACE sidecar pid-exact** if you started it — it holds **~75 GB** while RSS
  reports about 1 GB. `pkill`/`pgrep` are forbidden; pid-exact only.
- **Kill staging pidfile-exact.** Port **17600 is the user's LIVE app** — never bind it,
  never kill it. Identify the live app **by port** (`lsof -nP -iTCP:17600 -sTCP:LISTEN`),
  never by path and never from a note; staging is **17695**.
- **Clean up your own artifacts.** Named project stays (that was the point); scratch
  renders go. Never leave anything in the repo root.
- **Do not commit.** Commits need the user's word, every time, and each authorisation is
  spent on the commit it was given for.

## What this cycle is FOR

Three things no gate in this tree can do:

1. **It uses the product as a product.** Every gate here tests a unit against what we
   thought to assert. Dogfooding tests it against what someone actually wants to do.
2. **It reads our own documentation as a consumer.** Doc rot on an agent surface is not
   cosmetic — a capability nobody's agent knows about does not exist for them. Session 1
   found three such defects **before a single note was played**, all of which would have
   steered an agent away from a feature we had shipped that morning.
3. **It finishes the loop.** Which is where the regression was.

## Two laws session 1 bought, worth re-reading before you start

⭐ **A change that widens a schema to admit a NEW valid case silently widens it for every
EXISTING case too.** A union is not a per-variant contract. When a parameter becomes
polymorphic, the narrowing that used to come free must be re-established by hand.

⭐ **A picture is a diagnostic, never a gate.** The spectrogram experiment produced a
confident WRONG conclusion on its first read — a render was called bass-heavy when
measurement put its sub-60 Hz energy 12 dB *below* the full-band figure. `fscale=log` gives
the bottom octaves most of the image's vertical area, and an unstated `gain` did the rest.
Numbers stay the gate. If you emit an image, pin **and print** every render parameter with
it: an image whose parameters are unstated is not evidence.

## Prior sessions

- `docs/dogfood/2026-08-23-session-1.md` — 7 defects, 2 meta-findings, one real regression
  caught the same day it shipped. Roadmap: **M30**.
- `docs/dogfood/2026-08-24-session-2.md` — 5 findings, 2 meta-findings, 2 near-misses I
  caught on myself. Three arrangements in three contrasting FORMS (twelve-bar, loop-based,
  32-bar AABA), all landing within 0.9 dB of −14 LUFS at −1.00 dBTP, cycle 1 independently
  re-measured with `ffmpeg ebur128`. Roadmap: **M31**.

  ⭐ **Its keeper: nothing that broke was in the audio.** Every finding sat on the agent
  surface, and three of five were cases where **the product knew something and did not say
  it** — the server knew its build time, the roster knew its track kinds, the duplicate knew
  the caller already had those notes.

  ⭐ **And its practical tip: for bulk composition, write a Standard MIDI File and
  `clip_import_midi` it.** Jazz's 5,248 notes went in as **45 KB of SMF instead of ~330 KB
  of JSON**, one call per part, with a per-part note-count report to verify against. ⚠️
  **The critical limit (see daw-wire-reference): `clip_import_midi` replaces notes
  wholesale and never changes clip length — it is not additive.** An agent that reaches
  for it expecting to append will silently lose the existing notes.
