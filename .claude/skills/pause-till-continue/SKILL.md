---
name: pause-till-continue
description: Pause the current work and hold. Cancels ALL scheduled jobs immediately so nothing self-resumes, but lets any running agent finish first — work already done stays and remains authorised, nothing is reverted or marked unauthorised. Pass NOW to abort running agents instead of waiting. Resume with /dev-cycle or "continue".
---

# Pause till continue

**This is a PAUSE. It is not a cancellation.**

Three different things, and the distinctions are the whole point:
**SCHEDULES STOP IMMEDIATELY — all of them.
RUNNING AGENTS ARE LEFT ALONE — the pause waits for them.
WORK STAYS — all of it, and it stays authorised.**

## Two modes

| Invocation | Running agents |
|---|---|
| `/pause-till-continue` | **Never touched.** They run to completion; the pause is not finished until they are. |
| `/pause-till-continue NOW` | **Aborted immediately**, with whatever they had completed recorded. |

Scheduled jobs are cancelled **immediately in both modes** — they are what would
restart the work unattended, and nothing is lost by stopping them.

Everything already done stays, and stays **authorised** — code an agent has already
written, files edited, items in progress. Nothing is reverted, discarded, re-labelled
"unauthorised", or marked blocked. There is no decision here for the user to make.

## Why this skill exists

On 2026-08-03 an `m23-bs-3a` delegation was interrupted. It was logged *cancelled*,
and because the agent had already written its code, that code was recorded as
*"in-tree, uncommitted, unauthorised — awaiting the user's keep-or-revert ruling."*
**The user was never asked for such a ruling and none was needed.** The label then
propagated: `m23-bs-3b`, `m23-bs-4` and `m23-bp-2b` were all marked blocked on it,
and `m23-bp-2b` gates `m23-bp` — a probable real user-facing bug. One misread word
froze four roadmap items for eight days.

The user's own words, 2026-08-11: *"I did not mean to cancel, I always ask to pause
the process and then resume either with dev cycle or when I say continue."*

## Steps

1. **STOP EVERY SCHEDULED JOB — FIRST, AND ALL OF THEM.** Do this before anything
   else, so nothing can fire while the rest of the pause is still in progress. A
   pause is meaningless if a scheduled job restarts the work ten minutes later.

   - `CronList` → `CronDelete` **every job returned**.
   - `ScheduleWakeup({stop: true})` if a dynamic loop is pacing anything.
   - `TaskList` → `TaskStop` every **monitor** and every **background shell**.

   ⛔ **BUT NOT RUNNING AGENTS — they also appear in `TaskList`, and they are the
   one thing this step must leave alone.** Stopping a schedule loses nothing;
   stopping an agent destroys work in flight. Step 2 governs agents. In the default
   mode nothing here may touch one.

   ⚠️ **CANCEL ALL THE SCHEDULES — do not judge which ones are "related to this
   work".** That judgment is the same inference that caused the bug this skill
   exists to prevent, and a job you decide is unrelated will still wake you into the
   paused task. Stopping is cheap and restoring is one command; guessing wrong is
   not.

   ⚠️ **VERIFY, DO NOT ASSUME.** Re-run `CronList` afterwards and confirm it comes
   back empty; re-run `TaskList` and confirm nothing remains except agents you are
   deliberately letting finish. A delete call that returned is not proof the
   schedule is gone.

   **Report every cancelled job by ID and by its exact prompt text, verbatim**, so
   the user can restore it on resume. Never silently drop a schedule they set up.

2. **LET EVERY RUNNING AGENT FINISH. Do not stop one, ever, in the default mode.**
   Their work is authorised, and killing an agent mid-flight destroys exactly what
   this skill exists to protect — that is how the bs-3a code came to be mislabelled
   in the first place.

   - **The pause is not complete until they finish.** Say so, name the agent and
     what it is doing, and wait. An interim "paused, waiting on <agent>" report is
     the correct output here — do not present the pause as done while one is live.
   - **Do not start anything new** while waiting: no new agents, no new gate runs,
     no new edits to the paused task.
   - When it returns, take its result normally — record it, keep its work — then
     finish the remaining steps.

   ⛔ **ONLY `/pause-till-continue NOW` overrides this.** In that mode, abort running
   agents immediately (`TaskStop`), and for each one record **what it had completed
   before the abort** and that its work is **still authorised and must not be
   reverted**. A partial result is kept, never discarded.

3. **Make the work durable before stopping.** Write the file, save the artifact,
   update the roadmap/CHANGELOG entry you were mid-way through. A pause that loses
   uncommitted reasoning is a cancellation wearing a different name.

4. **Release expensive resources** — the same hygiene as any close-out. ⛔ **This
   step runs only AFTER step 2 has finished, and that ordering is load-bearing: a
   running agent may be driving staging or the sidecar, so killing them while one is
   live would break the very work you are protecting.**
   - Kill staging **PIDFILE-EXACT** (never `pkill`/`pgrep`). Port 17600 is the
     user's live app and is never touched.
   - **Kill the ACE sidecar pid-exact** if it no longer has a job — it holds
     ~75 GB while RSS reports ~1 GB.
   - Confirm with `/bin/ps -Ao pid,comm` plus a positive control on the grep.

5. **Do NOT** commit (commits need the user's word, and a pause is not that), and do
   NOT run `git checkout` / `stash` / `restore` / `clean` over anything.

6. **Report the resume point precisely** — enough that resumption needs no guessing:
   - the item id being worked and what step it had reached
   - what is verified vs. merely written
   - the exact next action
   - tree state (`git status --porcelain`) and what is uncommitted
   - **every schedule cancelled — ID and exact prompt text, verbatim** — plus the
     confirmation that `CronList` came back empty
   - **every agent that was running**: whether it finished normally or was aborted
     by `NOW`, and what it had completed either way

## Resuming

Only two things resume the work: the user invoking **`/dev-cycle`**, or the user
saying **"continue"**. Until one arrives, do nothing further on the paused task.

Answering an unrelated question in the meantime is fine — that is not resumption,
and it does not license picking the work back up.

⚠️ **Schedules do NOT come back on their own — that is deliberate.** On resume, offer
to restore the cancelled jobs from the verbatim record above and let the user choose;
re-arming a loop they did not ask for is how a pause turns back into an unattended
run. Resuming the *task* and resuming the *cadence* are separate decisions.

## The rule this encodes

**Never invent a user decision the user was never asked for.** If work is recorded as
blocked on the user, the record must name the message where they were actually asked.
If no such message exists, *that is the bug* — surface it instead of re-raising a
question that was never posed.
