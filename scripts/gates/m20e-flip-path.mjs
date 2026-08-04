// m20-e gate — the FLIP PATH: a device sample-rate change under a playing
// transport must not restart the graph's rate, must not re-prepare a single
// hosted AU, and must not cost a frame of playback beyond a bounded,
// DERIVED ceiling (m23-bq-2 — see the addendum below the main measured
// table for the second mutant this file now discriminates against).
//
// WHAT THIS PROVES. m19-k Phase 3. Before m20-c/d the AU prepare key embedded
// the DEVICE rate (`syncAudioUnitInstruments` :1573 read a live query), so the
// first `tracksDidChange` after any device flip changed EVERY hosted track's
// key, tripped `AUHostRegistry.releaseInstrument(forTrack:)` (called from
// `syncAudioUnitInstruments` at :1591/:1606) and spawned a re-prepare per
// track — the "re-prepare storm". Since m20-d the key embeds
// `AudioEngine.projectSampleRate`, a constant, so `guard auDesired[id] != key
// else { continue }` (:1601) short-circuits and nothing is released. This gate
// stages that exact situation against a real device and reads the registry.
// ⚠️ ALL FOUR COORDINATES IN THIS PARAGRAPH WERE RE-RESOLVED BY SYMBOL FOR
// m23-br-2 (2026-08-02) — the file previously cited :1343/:1372/:1367, which
// PREDATE the m23-bs-2/bs-3a edits and no longer point at this code. See the
// m23-br-2 ADDENDUM below for the full coordinate-staleness sweep and the
// standing instruction it leaves for the NEXT person who touches this file.
//
// ⚠️ THE ROADMAP'S STATED OBSERVABLE IS STALE AND CANNOT DISCRIMINATE — and
// that is now MEASURED, not argued. The item asks for "absence of the
// HostedAUInstrument.swift:156 renegotiation stderr line". That line fires only
// when the registry-prepared rate differs from the rate the node connects at
// (`HostedAUInstrument.swift:125`). In the BROKEN arm the registry prepares at
// the new device rate AND the graph adopts the new device rate — they agree, so
// the line stays absent there too. Absent when it works, absent when it's
// broken: a constant field. The registry seam below replaces it.
//   ⚠️ EXACTLY WHAT WAS MEASURED — this is one of the item's headline results
//   and must not be stated wider than its evidence. The staging log is 0 BYTES
//   in BOTH arms, and the fd plumbing was proven separately by driving
//   `/bin/sh -c 'echo … 1>&2'` through the identical openSync-append +
//   `stdio:["ignore", fd, fd]` shape `startStaging` uses. So: capture works,
//   and the app emitted nothing. This app was never OBSERVED writing a line to
//   that log — app-stderr capture is INFERRED from the plumbing plus the app's
//   silence, not demonstrated end to end.
//
// ⚠️ THE BRIEFING'S CAUSAL CHAIN WAS ALSO WRONG, AND THE CORRECTION IS THE
// SCENARIO. `recoverEngine` (:3879) does NOT call `rebuildEngine` — the only
// callers are :1049 (announce-class reconcile, `rebuildEngine(reason:
// "announce-class reconcile")`) and :2703 (device reset, `rebuildEngine(reason:
// "output device reset to system default")`). ⚠️ RE-RESOLVED BY SYMBOL for
// m23-br-2 — the file previously cited :3176/:893/:2452, all stale. A bare
// device flip therefore gives config-change → restart → `startPlayers` and
// NEVER re-enters `syncAudioUnitInstruments`. The storm is latent until the
// next `tracksDidChange`. So this gate supplies that action itself, and it
// measured WHICH action storms:
//
//     action after the flip                    REAL      MUTANT (graphRate:nil)
//     flip alone, no mutation                  0 n/r     0 n/r      ← latent
//     parameter-only mutation (setVolume)      0 n/r     41 n/r     ← STORM
//     teardown-class mutation (add+remove)     0 n/r     0 n/r      ← key already moved
//
// The parameter-only mutation is the trigger, because it is the FIRST
// `tracksDidChange` after the flip; by the time the teardown-class change runs,
// the mutant has already re-keyed. A gate that only did the teardown-class
// change (the obvious one, and the one m20-d used) would have read ZERO
// re-prepares in the mutant and reported a confident, hollow green.
// ⚠️ THE NUMBERS IN THIS TABLE ARE THE OLD HAMMER-SAMPLED READING — kept
// verbatim for the historical record. m23-br-2 (below) replaces every one of
// these with an EXACT counter delta; see that section before trusting a
// count printed here.
//
// ══ MEASURED RED BASELINE — THIS GATE, BOTH ARMS (HAMMER-SAMPLED, PRE-br-2) ══
// Run 2026-08-02 on this machine. Mutant = `graphRate: Self.projectSampleRate`
// → `graphRate: nil` at AudioEngine.swift:601 and :1247 (⚠️ RE-RESOLVED BY
// SYMBOL for m23-br-2 — previously cited as :479/:1037, which are stale; both
// current sites are `graph = PlaybackGraph(engine: engine, graphRate:
// Self.projectSampleRate)`, one in `init()`, one in `rebuildEngine`), rebuilt,
// THIS FILE run unchanged against it; then reverted and verified byte-exact by
// sha256.
//
//     TOTALS      real  46 pass / 0 fail        mutant  42 pass / 4 fail
//
// ⚠️ THE MUTANT TOTAL IS 4–5 FAILURES, NOT 4 — RACE-DEPENDENT, AND THE REAL
// ARM IS UNAFFECTED. An INDEPENDENT orchestrator re-run of this exact file
// against the same mutant read **41 pass / 5 fail**. The extra red was L5's
// anti-vacuity pair (`graph rate unmoved by the mutation, device still
// 44100`), which read `sampleRate: 44100`. Cause, visible in that run's own
// trace: L4 printed `graph=48000` ("the graph object has not been replaced")
// and L5 printed `graph=44100`, so the ANNOUNCE-CLASS reconcile rebuild
// (`AudioEngine.swift:1049`) landed BETWEEN those two windows; in the run
// tabled above it landed after L5. Whether that rebuild beats the param
// mutation is a race, so in the mutant arm that leg is INCIDENTALLY
// discriminating and must not be counted on. **On the real tree it is
// deterministically green — a constant graph rate cannot move whenever the
// rebuild lands, which is the whole point of m20-d.** Storm COUNTS also vary
// run to run (L5 25 vs 41, L7 10 vs 21 between the two mutant runs): the
// hammer samples a millisecond-scale window, so treat the counts as "many,
// on 8/8 tracks", never as a pinned figure — m23-br-2's exact counter deltas
// exist precisely to stop needing this caveat. What reproduced EXACTLY across
// both mutant runs is the set of legs that redden, minus this race.
//
//   leg                                            REAL          MUTANT
//   L2 cold-prepare positive control (n/r seen)    30            30
//   L3 quiescent @48k, notReady / auditions        0 / 9181      0 / 8880
//   L4 after flip↓44.1k, no mutation               0 / 14129     0 / 14282
//   L5 flip↓ + param mutation       ★DISCRIMINATES 0 / 23288     41 / 18335  ✗
//        …storm span                               —             9…18 ms, 8/8 tracks
//   L6 flip↓ + teardown mutation                   0 / 18384     0 / 19110
//   L6 graph rate after the rebuild ★DISCRIMINATES 48000         44100       ✗
//   L6 quantum vs 512×48000/44100=557.3            558†          512         ✗
//        († 557 in later runs — the integer ALTERNATES; see the note below)
//   L7 flip↑48k + param mutation    ★DISCRIMINATES 0 / 22771     21 / 17895  ✗
//        …storm span                               —             9…80 ms, 8/8 tracks
//   L7 flip↑ + teardown mutation                   0 / 18419     0 / 18546
//   L7 final graph rate / quantum                  48000 / 512   48000 / 512
//   master peak, min…max across all windows        −15.8…−6.3 dB (mutant −23.9…−6.3
//        — that mutant figure is from the equivalent PROBE run, not this gate's
//        mutant run, whose meter lines were not captured; flagged rather than
//        quietly presented as the gate's own)
//   L8 watchdog restartCount                       0             0
//   L10 wedge-log byte delta                       0             0
//   L11 staging-log bytes / renegotiation lines    0 / 0         0 / 0
//
// ⚠️ WHAT THE TABLE SAYS ABOUT LEGS THAT MERELY CORROBORATE. Exactly THREE
// facts differ between the arms (L5's storm, L6's rebuilt graph rate, L7's
// storm — L6's quantum is a fourth failing check but a second view of the same
// rate reading, not independent evidence). Everything else — playback resuming,
// meters flowing, the wedge log, the watchdog, the no-mutation windows, the
// FINAL graph rate — is IDENTICAL in a broken build and is labelled
// CORROBORATING below. They are worth asserting (a regression that breaks them
// is real) but none of them is evidence that the flip path works.
//
// ══ m23-br-2 ADDENDUM (2026-08-02) — THE SIX ZERO LEGS MOVE TO
// `engine.auPrepareStats`, AN EXACT COUNTER, INSTEAD OF A HAMMERED SAMPLE ═════
//
// FILED m23-br (2026-08-02): m20-e's zero legs proved absence through
// `note.audition`'s `reason` field, which reaches
// `auRegistry.preparedInstrument(forTrack:)` only after mute/solo, `!isRunning`
// and `noRenderer` are checked (`AudioEngine.swift:auditionAudibility`) — a
// single sample could report `engineStopped`/`engineRebuilding` and mask a
// concurrent not-ready, so the gate compensated by hammering ~9000–23000
// samples per window instead of reading a number. `engine.auPrepareStats`
// (m23-br-1) closes that: `instrumentPrepares`/`instrumentReleases` are
// MONOTONE LIFETIME TOTALS on the live `AudioEngine`, incremented PAST the
// registry's idempotency guard and BEFORE its `.missing`/`.failed` early
// returns — so a FAILED re-prepare still counts, because it is still real
// re-prepare work. Coordinates (re-resolved by symbol 2026-08-02, guard →
// increment): instrument `AUHostRegistry.swift:650` → `:665`, effect `:520`
// → `:523`. No reset seam. The idiom is read → act → read →
// subtract, which is what every leg below now does.
//
// ⚠️ L2's audition-seam anti-blindness control (below) DOES NOT TRANSFER to
// this new seam — it proves `note.audition` can observe `instrumentNotReady`,
// which says nothing about whether the COUNTER moves. A dedicated leg, L2c,
// proves the counter's own positive control BEFORE any zero-delta leg below it
// is trusted: add a fresh hosted track (GM sound bank, same param shape as the
// L2 fixture), settle, assert `instrumentPrepares` rose by exactly 1 and the
// track appears in `tracks[]` with a `keyDigest`; remove it, settle, assert
// `instrumentReleases` rose by exactly 1. This is the exact defect m23-bq-2
// paid for (a detector that was never proven able to see the thing it is
// asserting the absence of), reproduced here rather than assumed away.
//
// WHAT CHANGED, LEG BY LEG (the six zero legs named in the m23-br-2 roadmap
// entry): L3 `no re-prepare while nothing has changed`, L4 `the flip ALONE
// re-prepares nothing`, L5 `ZERO AU RE-PREPARES … after the flip`
// (★discriminates), L6 `no re-prepare across the rebuild`, L7 `ZERO AU
// RE-PREPARES … after the flip BACK` (★discriminates), L7 `no re-prepare
// across the second rebuild`. Every one of the six now snapshots
// `engine.auPrepareStats` immediately before its triggering action, lets the
// engine settle, snapshots again, and asserts the FOUR-FIELD delta is exactly
// `{0,0,0,0}` — never a sampled `notReady` count.
//
// ⚠️ THE HAMMER'S FAN-OUT (cycling `note.audition` over every hosted track) IS
// REMOVED, NOT SHRUNK, EVERYWHERE ITS ONLY JOB WAS THE notReady===0 CLAIM —
// L4's "no mutation" leg and BOTH teardown-class legs (L6, L7 2nd rebuild)
// carried no other claim, so `hammer()` is gone from this file entirely and
// those three legs are counter-delta-only. Where a hammer call ALSO carried a
// genuine audio-quality claim the counter cannot make — L3 and L7's "master
// tap is live and above the floor", L5's "master tap never floored — no
// placeholder-silence gap" — that claim survives on a new, leaner
// `meterProbe()` (a pure `mixer.masterAnalysis` loop, no audition fan-out).
// `meterProbe` reads MORE meter samples per window than `hammer()` did (it no
// longer interleaves 8 audition calls per meter read), so nothing about the
// surviving claims got weaker.
//
// ⚠️ SETTLE BEFORE THE SECOND READ — WHY THIS ISN'T A BARE ASSUMPTION. The old
// hammer had to be SAMPLING DURING the storm (measured 9…80 ms in the table
// above) to see it. The counter has no such constraint, but a read taken WHILE
// an async prepare/release Task is still in flight would report a partial
// delta — indistinguishable from "a smaller storm happened" unless something
// polls to quiescence first. `settleCounters()` (below) polls
// `engine.auPrepareStats` itself — cheap, one control round trip, no
// note.audition fan-out — until all four counters hold still for 200 ms,
// capped at 3000 ms. 200 ms is ~2.5× the worst measured storm span (80 ms);
// 3000 ms matches this file's own historical hammer windows so a genuinely
// wedged prepare cannot hang the gate silently.
//
// ⚠️ COMPARE TWO READS FIELD BY FIELD, NEVER `JSON.stringify(a) ===
// JSON.stringify(b)`. Object key order on the wire is NOT stable — this bit
// the m23-br-1 round trip directly: two byte-different serializations of
// IDENTICAL data were observed, with `instrumentReleases` and `effectPrepares`
// swapped position between encodes. Array order IS pinned (the registry sorts
// both `tracks` and `effects` by id), so only the four scalar counters need a
// field-by-field comparison — `countersEqual()` below does exactly that, never
// a whole-object stringify.
//
// ⚠️ THE REAL ARM ASSERTS EXACT `=== 0`. THE MUTANT ARM DOES NOT GET A
// HARDCODED NUMBER IN THIS SCRIPT. The real arm is deterministic — a constant
// graph rate cannot move whenever the reconcile rebuild lands, which is the
// entire point of m20-d, so every real-tree delta below is `{0,0,0,0}`,
// unconditionally. The mutant arm is RACE-DEPENDENT — the hammer-sampled table
// above already shows the announce-class reconcile rebuild landing between L4
// and L5 in one run and after L5 in another, which would move re-prepare work
// from one leg's window into a neighbour's. So the counter equivalents are
// documented here as a floor/range with the SET of legs expected to redden,
// never a total, and the actual mutant numbers are:
//
//     ══ MEASURED, ORCHESTRATOR'S OWN MUTANT RUN, 2026-08-02 ═══════════════
//     Recipe: `graphRate: Self.projectSampleRate` → `graphRate: nil` at BOTH
//     `PlaybackGraph(engine:graphRate:)` construction sites in
//     AudioEngine.swift (`init()` :601 and `rebuildEngine` :1247 as of this
//     writing) — found BY SYMBOL with the match count asserted == 2 before
//     writing, `swift build`, this file run UNCHANGED, then reverted and
//     proven byte-exact by sha256 (clean b3808d82…, mutant 3c7fcaa7…,
//     restored b3808d82…).
//
//         TOTALS      real  68 pass / 0 fail      mutant  64 pass / 4 fail
//
//     THE FOUR-LEG REDDENING SET (pin the SET, never the total):
//       ★ L5  counter delta      Δ prepares +8  Δ releases +8   (real {0,0,0,0})
//       ★ L7  counter delta      Δ prepares +8  Δ releases +8   (real {0,0,0,0})
//         L6  rebuilt graph rate  44100                          (real 48000)
//         L6  converter quantum   512 vs ≈557.3                  (real 557)
//     ⚠️ 557 here, 558 in the older table above — and m23-br-3 (2026-08-02)
//     found the honest answer is BOTH. The derived value is 512×48000/44100 =
//     557.28 and the reported integer is NOT stable across reads: br-3's
//     MUTANT arm printed `quantum=558` at the (unasserted) L5 stats line while
//     every other stats line in the same run printed 557. The ASSERTED L6 leg
//     has read `converted=557` in all four observations to date (br-2 real ×2,
//     br-3 real + mutant), and its ±2 tolerance covers both values regardless.
//     m23-br-2 recorded this as "557, NOT 558" — that over-narrowed an
//     ALTERNATING pair into a single figure, which is how a number ping-pongs
//     between "corrections" forever. The durable form is the DERIVED value
//     plus the OBSERVED SET: 557.28 derived, {557, 558} observed. The original
//     br-2 point survives intact and is the reason this was caught: an
//     inherited number is not a measured one however plausibly it reached you.
//     The last two are m20-d's ORIGINAL rate legs, unchanged by m23-br-2 and
//     reproduced here only to show the arm was genuinely the m20-d mutant.
//
//     ⚠️ THE HEADLINE RESULT — THE COUNT STOPPED BEING A RANGE. The retired
//     hammer read 25 in one mutant run and 41 in another (table above) for
//     the SAME defect, because it sampled a millisecond-scale window; the
//     roadmap could only ever say "many, on 8/8 tracks". The counter reads
//     EXACTLY 8 prepares AND EXACTLY 8 releases — N_TRACKS on both, at both
//     storming legs. That is the whole point of m23-br-2: an integer that
//     means something, in place of a sample count that meant "some".
//
//     ⚠️ L6 AND L7-TEARDOWN READ `{0,0,0,0}` ON THE MUTANT TOO, and that is
//     the documented mechanism, not a gate defect: by the time either
//     teardown-class change runs, the param mutation before it has already
//     re-keyed every track, so the guard short-circuits. The race the
//     paragraph above anticipated did NOT materialise in this run — L5 read
//     `graph=48000` in its own `stats` line while its counters had already
//     moved +8/+8, so the storm did not need the announce-class rebuild to
//     land first. Treat that as ONE observation, not a law.
//
//     THE CHECK TO APPLY ON ANY FUTURE MUTANT RUN, unchanged by the above:
//     (a) L3 and L4 are unconditionally `{0,0,0,0}` — nothing before the
//     first post-flip mutation can move a re-prepare counter; (b)
//     `instrumentPrepares` AND `instrumentReleases` summed across
//     {L5, L6, L7-param, L7-teardown} both reach a FLOOR of N_TRACKS=8,
//     however that floor is distributed (measured here: 16 and 16, i.e. 2×
//     the floor, split 8+0+8+0). Do NOT pin a specific leg to zero on the
//     mutant arm and do NOT pin the total — pin the SET and the summed floor.
//
// ⚠️ COORDINATE HYGIENE — STANDING INSTRUCTION, NOT A ONE-TIME FIX. Every
// AudioEngine.swift line number in this file was re-resolved BY SYMBOL for
// m23-br-2, because the ones inherited from m20-d/m23-bq-2 had drifted this
// far without anyone noticing (m23-bp-2 already paid for the same rot once).
// The bs-3a edits already in this tree (unauthorized as of this writing —
// see the project memory) moved code below line ~2572 by roughly 70 lines, so
// EVERY future edit to this header must re-grep the symbol, confirm the match
// count, and only then cite a line number — never trust an inherited one.
// ⚠️ m23-br-3 (2026-08-02) CLOSED THE ONE SET m23-br-2 DELIBERATELY LEFT.
// br-2 flagged that the m23-bq-2 addendum below still cited
// `AudioEngine.swift:3960` for the `renderClockTrusted` mutant and
// "`rebuildEngine`'s OWN call site, ~line 3336" inline in the L6/L7 plateau
// assertions, and left them because they belonged to a different roadmap item.
// Both were stale. RESOLVED AND RE-PROVED — the mutant arm was re-run against
// this file at its CURRENT 68 legs, not renumbered on paper:
//     :3960  →  :3975   (inside `recoverEngine`, declared :3879; the next
//                        declaration is `watchdogRestart` :4036. :3960 had
//                        drifted into the middle of that site's comment.)
//     ~3336  →  :1336   (inside `rebuildEngine`, declared :1163; the next
//                        declaration is `projectWillReplace` :1351.)
//     third site :1121  (inside `tracksDidChangeBody` — carries
//                        `renderClockTrusted: false` too but drives no leg
//                        here; named so the count below is checkable.)
//
// ⚠️ AND THE br-2 LAW ("cite the symbol, not the line") WAS NOT ENOUGH HERE —
// THE SYMBOL IS AMBIGUOUS. The mutant's own text,
// `renderClockTrusted: false, cause: .continuation`, matches THREE times in
// AudioEngine.swift (:1121, :1336, :3975) and the three statements are
// textually near-identical. A symbol-based apply script keyed on that string
// would have mutated all three and silently destroyed the discrimination the
// table below exists to make — the L6/L7 legs would have reddened too and the
// "only recoverEngine-driven legs move" result would have evaporated.
// The durable anchor is a neighbouring token from the SAME statement that is
// unique: `startPlayers(fromBeat: resume, tempoMap: anchor.tempoMap,` —
// grep count 1. The other two both read `fromBeat: beats, tempoMap:
// resume.line.tempoMap`. THE RULE: an apply script must assert its match
// count, and when the natural symbol is not unique, widen the anchor until it
// is — do not fall back to a line number.
//
// ══ MEASURED — m23-bq-2's OWN RED BASELINE, BOTH ARMS ═══════════════════
// ⚠️ RE-MEASURED IN FULL AT m23-br-3 (2026-08-02) against the file at its
// CURRENT 68 legs. The figures previously here (51/0/0 and 49/2/0) were
// PRE-br-2 totals for a 51-leg version of this file and could not be
// renumbered — they had to be re-run, and were.
// `RESUME_WINDOW_MS`=3000 (the shipped default),
// `RESUME_PLATEAU_CEILING_MS`=300 (the shipped default). Mutant =
// `renderClockTrusted: false` → `true` at `AudioEngine.swift:3975` (inside
// `recoverEngine` ONLY — anchored on the unique
// `startPlayers(fromBeat: resume, tempoMap: anchor.tempoMap,` line, NOT on the
// three-way-ambiguous `renderClockTrusted: false, cause: .continuation`; see
// the coordinate addendum above). `rebuildEngine`'s own separate
// `renderClockTrusted: false` (:1336) and `tracksDidChangeBody`'s (:1121) are
// untouched. Rebuilt, THIS FILE run unchanged against it; then reverted and
// verified BYTE-EXACT by sha256.
//     clean   b3808d826dd88233025ecdba7c3bae584a4af0ff44edab852e0ac80bb7ad8583
//     mutant  c6b66f13baa46743ec0cd5219fed604197834cc67f15d9071fd2cbb45981d4e0
//     revert  b3808d826dd88233025ecdba7c3bae584a4af0ff44edab852e0ac80bb7ad8583  ✓
// ⚠️ The sha256 previously pinned here (`3519730279…`) was the clean baseline
// of an OLDER tree and no longer matches this one. A revert verified against a
// stale hash reports a false mismatch — or worse, invites someone to "fix" the
// baseline to whatever the tree happens to hold. Re-pin it every run.
// ⚠️ :1336 is a CONDITIONAL COORDINATE — it sits on the unauthorised in-tree
// bs-3a code. If the user rules "revert bs-3a" it moves again; `rebuildEngine`
// (:1163) and its continuation `startPlayers` are the durable references.
//
//     TOTALS      real  68 pass / 0 fail / 0 skip     mutant  66 pass / 2 fail / 0 skip
//
//   leg                        MECHANISM        CLEAN plateau    MUTANT plateau
//   L4  after flip↓            recoverEngine     60–67 ms        ⚠️ FAIL — 2832 ms (2822–10371 hist.)
//   L6  after rebuild@44.1k    rebuildEngine     34–37 ms        PASS — 35 ms (unaffected)
//   L7  after flip↑            recoverEngine     66–102 ms       ⚠️ FAIL — 2849 ms (2819–14823 hist.)
//   L7  after second rebuild   rebuildEngine     35–37 ms        PASS — 36 ms (unaffected)
//
// br-3's own readings: clean 60 / 34 / 66 / 37 ms, mutant 2832 / 35 / 2849 /
// 36 ms — both mutant failures CENSORED lower bounds already past the 300 ms
// ceiling, so both asserted as FAIL, not skipped. The CLEAN ranges above are
// widened by br-3's run (L4's floor 63→60; L7 flip↑'s floor 99→66) — the
// derivation's worst-observed figure is still 102 ms, so the 3000 ms window
// and 300 ms ceiling are unchanged.
// ⚠️ The 68/0/0 above is the run against THIS FILE AS SHIPPED — br-3's edits
// are comments and two `ck()` labels, but the totals were re-measured on the
// final bytes rather than inherited from the pre-edit run (63 / 36 / 99 /
// 36 ms, `converted=557`, all inside the ranges above). A record that
// describes a file the run never saw is the same class of defect as a stale
// coordinate.
//
// ⚠️ WHAT ELSE br-3 CONFIRMED, and it is the part worth keeping: the two
// mutants this file discriminates against are INDEPENDENT. Under the bq-2
// mutant ALL SIX of br-2's `auPrepareStats` counter legs stayed GREEN, as did
// L2c's anti-blindness control, L13's effect pair, and the L9b detector
// control. The bq-2 mutant is about resume ANCHORING; the m20-d mutant is
// about AU prepare KEYS; neither leaks into the other's legs. If a counter leg
// ever reddens under the bq-2 mutant, that is a real finding — the two
// mutants would not be as independent as both headers assume.
//
// CLEAN figures are the range across 5 independent runs, never censored.
// MUTANT figures are the range across 2 independent characterization runs —
// one at the shipped 3000 ms window (plateau read as a CENSORED 2822/2819 ms
// LOWER BOUND — the true value is unknown but already far past the 300 ms
// ceiling) and one at a 15000 ms characterization window (L4 completed
// un-censored at 10371 ms; L7(flip↑)'s plateau STILL exceeded 15000 ms).
//
// ⚠️ THE MUTANT'S PLATEAU SCALES WITH HOW LONG THE PREVIOUS SESSION HAD BEEN
// RUNNING — bq-1's own finding (freeze length ≈ previous session's length),
// reproduced here rather than assumed. L7(flip↑)'s freeze is LARGER than
// L4's precisely because this file's own full-window polling at L4 (every
// `resume*` call busy-polls for the ENTIRE window regardless of when the
// plateau ends, by design) had already let the rebuilt engine run for far
// longer before L7's flip triggers the next bounce. This is a genuine,
// reproducible property of the defect, not gate noise — do not "fix" it by
// shortening the window; the shipped 3000 ms window does not need to
// outlast it (see the next paragraph).
//
// ⚠️ A CENSORED READING IS NOT ALWAYS A SKIP — see
// `assertResumePlateauCeiling`'s doc comment. A censored lower bound that
// ALREADY exceeds the ceiling (both mutant L4/L7(flip↑) readings at the
// shipped window) is asserted as a FAIL, not skipped; only a censored
// reading still under the ceiling is genuinely undecidable and skips. This
// was a real bug caught while characterizing the mutant with this file's
// FIRST draft of the assertion, not a hypothetical — worth naming because
// getting it backwards would have let a multi-second freeze under the
// shipped window report SKIP instead of the FAIL it plainly is.
//
// WHY ONLY TWO OF THE FOUR LEGS REDDEN, AND WHY THAT IS CORRECT, NOT A GAP:
// `recoverEngine` (L4, L7 flip↑ — a bare device-config-change bounce) and
// `rebuildEngine` (L6, L7 2nd rebuild — a teardown-class structural change)
// are TWO SEPARATE call sites, each with its OWN `renderClockTrusted: false`
// (`AudioEngine.swift:3975` and `:1336` inside `rebuildEngine` — see
// `RenderClockTrustSiteTests`' six-site table for both; m23-br-3 re-read that
// table and it still enumerates exactly three untrusted sites,
// {tracksDidChangeBody, rebuildEngine, recoverEngine}, so the mechanism claim
// below rests on a pin that still says what it is quoted as saying). The
// mutation touches ONLY `:3975`, so ONLY the `recoverEngine`-driven legs were
// predicted to redden — and exactly those two, and no others, did. That is
// corroborating evidence the new ceiling assertion measures the RIGHT
// mechanism rather than something incidentally correlated with a device flip
// in general.
//
// BUFFER/RATE THIS DERIVATION ASSUMES: 512 frames native / 48 kHz; 557–558
// frames pulled while the device sits at 44.1 kHz (512×48000/44100 = 557.28,
// and the reported integer alternates — L6's own quantum check, ±2 tolerance).
// `RESUME_WINDOW_MS`/`RESUME_PLATEAU_CEILING_MS`'s own comments carry the
// numeric derivation and the buffer-size caveat (a bigger buffer inflates the
// legitimate gap — same law as `RecoveryPlayheadTests`, which this file's
// plateau metric deliberately does NOT reuse: that Swift suite switched to a
// lag-against-wall-clock metric specifically to survive main-actor
// starvation under the FULL Swift suite (m23-bu), a failure mode this node
// gate — a separate process polling a live app over a WebSocket — does not
// share.
//
// ⚠️ NOTE THE FINAL-STATE TRAP. At the END of the run the mutant reads 48000
// too, because its last rebuild happened with the device back at 48 kHz. A gate
// that measured the graph rate only at the end — the natural place to put it —
// would have passed on a broken build. The rate MUST be read while the device
// is at 44.1 kHz AND after a rebuild; L6 is the only leg that does.
//
// ⚠️ THE PLACEHOLDER-SILENCE DIP WAS MEASURED AND REJECTED. The obvious
// user-facing observable — `releaseInstrument` runs BEFORE the async prepare,
// so the track renders the silent placeholder — is NOT usable here. The storm
// window is ~12 ms and the re-prepare of all 8 tracks completes inside it, so
// the master tap never reaches its floor even in the mutant (min −23.9 dB vs a
// −80 floor, against a −6.3 dB baseline). Measured, not assumed. Meters are
// therefore a liveness leg only — carried now by `meterProbe()`, see the
// m23-br-2 addendum above.
//
// ⚠️ THE STORM WINDOW IS TENS OF MILLISECONDS. Measured not-ready spans in the
// mutant: 9…18 ms after the first flip and 9…80 ms after the second (probe
// runs: 9…21 ms and 10…20 ms). This is why `settleCounters()`'s 200 ms quiet
// window and L2's own inline cold-prepare loop below both poll densely rather
// than sleeping a single long interval: a 25 ms poll saw the SAME storm in
// exactly ONE sample out of 91 in earlier hammer-based characterization, and a
// 120 ms poll would have missed it outright. The 8-track fixture is part of
// the sensitivity for L2's audition-seam control specifically: the storm
// releases EVERY hosted track at once, so N tracks give N independent chances
// for that seam to see it. (m23-br-2's counter-based zero legs do not need
// this margin at all — a monotone integer cannot alias a window the way a
// sampled boolean can; the settle-poll exists to avoid reading it mid-flight,
// not to avoid missing a transient.)
//
// ⚠️ HOW MUCH MARGIN L2 ACTUALLY HAS — the number that sizes L2's own claim
// (the audition seam can see `instrumentNotReady`) and, by extension, L2c's
// need to exist as a SEPARATE control for the counter seam. Per-track cold
// not-ready counts over four runs (three real, one mutant):
//     [8,2,4,3,3,4,3,3]  [10,2,3,3,3,2,3,4]  [9,2,3,3,3,4,4,4]  [10,4,3,2,2,3,3,3]
// Totals 30/30/32/30 against a threshold of >0, so the leg is far from failing —
// but the PER-TRACK floor is 2, and that is the honest margin. A machine a few
// times slower on the wire would start losing individual tracks; the aggregate
// is what keeps this safe, not any single track. This margin is scoped to L2
// (the audition-seam claim) ONLY — it does not extend to the counter-based
// zero legs, which is exactly why L2c exists as its own positive control.
//
// ⚠️ L2 IS LOAD-BEARING FOR THE AUDITION SEAM; L2c IS LOAD-BEARING FOR THE
// COUNTER SEAM — NEITHER SUBSTITUTES FOR THE OTHER. A ZERO FROM A BLIND
// DETECTOR LOOKS EXACTLY LIKE A PASS, on either seam independently. L2 proves
// in-run that `note.audition`'s `reason` field CAN report `instrumentNotReady`
// (hammering each track's own cold prepare immediately after
// `track.setInstrument`, measured cold window 43…86 ms). L2c proves
// `engine.auPrepareStats`'s counters CAN move for a real prepare/release. If
// EITHER fails, the legs that depend on that seam are inconclusive, not green.
//
// THE TWO SEAMS. (1) `note.audition`'s `reason` field — `auditionAudibility`
// (AudioEngine.swift:1313, unverified post-bs-3a, not re-resolved here — see
// the coordinate-hygiene note above) reads
// `auRegistry.preparedInstrument(forTrack:) == nil` synchronously and reports
// `instrumentNotReady`. ⚠️ PRIORITY-ORDERED (`!isRunning` and `noRenderer` are
// checked first), so a single sample can mask a concurrent not-ready — this is
// why L2 asks "did `instrumentNotReady` EVER appear in this window", never
// "what was the reason at time T". Used ONLY by L2 in this file now. (2)
// `engine.auPrepareStats` — the registry's own lifetime prepare/release
// counters, read directly, no priority ordering, no sampling window. This is
// the PRIMARY seam for every zero-delta and discriminating leg from L2c
// onward (m23-br-2).
//
// WHAT THIS GATE CANNOT PROVE:
//   • That the settle-poll (200 ms quiet, 3000 ms cap) always outlasts a
//     future, slower-machine storm. It is derived from THIS machine's
//     measured 9…80 ms storm span with a stated margin, not a law — re-derive
//     if a future run reads a settle timeout warning that a slower machine
//     would explain.
//   • Anything about third-party AUv2 instruments or effects. GM/DLS sound
//     banks and Apple-manufactured 'aufx' effects only — a real third-party
//     AUv2 (Surge XT) wedges the main actor for minutes (m23-av).
//   • Pitch-correctness of the converted output. That needs a loopback
//     RECORDING, not a control-plane read; it is still uncovered (m20-d note).
//   • Anything at rates other than 48 k ↔ 44.1 k on BlackHole.
//
// AUDIBLE? NO. Output is pinned to BlackHole (a silent virtual device) before
// any transport starts, and the pin is app-local — the macOS default output is
// read before and after and never moved. The bonus effect leg (L13, see the
// m23-br-2 addendum) runs in a SEPARATE staging session that also pins
// BlackHole before doing anything, even though it never starts the transport.
//
// THE ONE THING THIS WRITES: BlackHole's nominal sample rate, restored to 48000
// in a `finally` with the read-back verified. The wedge log is read for its
// SIZE only and never opened for writing.
//
// HOW TO RUN — there is a BUILD STEP for the device-rate helper, shared with
// m20-d. The binary is gitignored, so on a fresh checkout this aborts (exit 2)
// until you compile it:
//
//     swiftc -O scripts/gates/m20d-bhrate.swift -o scripts/gates/m20d-bhrate
//     node scripts/gates/m20e-flip-path.mjs
//
// Staging: DAW_CONTROL_PORT=17695. The user's live app on 17600 is never a
// target — `startStaging` asserts this.
import { sleep, buildOrAbort, startStaging, stopStaging, connect, ROOT } from "./_staging.mjs";
import { execFileSync } from "node:child_process";
import { existsSync, statSync, readFileSync } from "node:fs";
import path from "node:path";

const GATE = "m20e-flip-path";
const UID = "BlackHole2ch_UID";
const PROJECT_RATE = 48000;
const STAGED_DEVICE_RATE = 44100;
const RESTORE_RATE = 48000;
const N_TRACKS = 8;              // 8 hosted tracks ⇒ ~44 observations in the storm
const STAGING_LOG = `/tmp/daw-gate-out/${GATE}/staging.log`;
// Read-only. Under the USER's Library — never truncated, deleted or created.
const WEDGE_LOG = `${process.env.HOME}/Library/Logs/DAWPro/main-actor-wedge.log`;

// Shared with m20-d: SOURCE is committed (`m20d-bhrate.swift`), the compiled
// binary is a build artifact and is not. It can only ever resolve BlackHole —
// the UID is a compile-time constant with no argument that overrides it, so it
// cannot reach the user's real devices.
const BHRATE = path.join(ROOT, "scripts", "gates", "m20d-bhrate");

// ── m23-bq-2: plateau measurement constants — see `measureResumePlateau`'s
// doc comment for the full derivation. ─────────────────────────────────────
// "Did not meaningfully advance": an order of magnitude below one ~30 Hz
// playhead-publish step (β·33 ms ≈ 0.066 beats at 120 BPM) and two orders
// above float-repeat jitter, so it cannot mistake "same publish" for "next
// publish" — see the doc comment for the ratio argument.
const EPS_BEATS = 0.005;
// Unchanged from the superseded `waitForTransportAdvance` — kept ONLY for the
// printed "resumed after Nms" line, never asserted on since m23-bq-2.
const ADVANCE_EPS_BEATS = 0.05;
// How long each `resume*` leg watches AFTER the mark, buffer/rate this
// assumes 512 frames @ 48 kHz native (557–558 frames pulled while the device
// sits at 44.1 kHz, per L6's own quantum check) — a bigger buffer inflates
// BOTH the legitimate gap and the sampling floor by roughly one buffer
// period, same as `RecoveryPlayheadTests`' own buffer-size caveat.
// MEASURED clean-tree worst plateau (3 runs × 4 legs, this machine,
// 2026-08-02): 63–66 ms (L4), 35–37 ms (L6), 99–102 ms (L7 flip↑, the
// consistent worst leg), 35 ms (L7 2nd rebuild) — never censored. 3000 ms is
// ~30× that worst observed (102 ms) and comfortably past the theoretical
// worst case for the two recoverEngine-driven legs (`continuationHorizon
// Seconds(8)` = 114 ms + up to 48 ms segment A per m23-bs-1 + one ~33 ms
// republish tick ≈ 195 ms) — so a genuine multi-second freeze (the class
// m20-e's original filing measured up to ~6.5 s on a DIFFERENT,
// sustained-note fixture) cannot be mistaken for one still resolving.
// Override with DAWPRO_M20E_RESUME_WINDOW_MS for a characterization run —
// the m23-bq mutant's plateau SCALES WITH HOW LONG THE PREVIOUS SESSION HAD
// BEEN RUNNING (bq-1's own finding, reproduced here: this file's own L4 leg
// measured a 10371 ms plateau, and by L7(flip↑) — after this file's OWN
// full-window polling had let the session run far longer — the plateau
// exceeded even a 15000 ms characterization window). The shipped 3000 ms
// window does not need to outlast that: see `assertResumePlateauCeiling`'s
// doc for why a CENSORED reading already over the ceiling is still a FAIL.
const RESUME_WINDOW_MS = Number(process.env.DAWPRO_M20E_RESUME_WINDOW_MS || 3000);
// DERIVED, not guessed: ~3× the worst CLEAN plateau observed across 3 runs
// (102 ms, L7 flip↑) and ~1.5× the THEORETICAL worst case for a
// recoverEngine-driven resume at this gate's N_TRACKS=8 (see RESUME_WINDOW_MS's
// comment for the 195 ms derivation). Nowhere near tight against the mutant:
// the smallest defect plateau measured in this file's own mutant
// characterization run was 10371 ms — ~35× this ceiling — so there is no
// realistic risk of the two bands touching.
const RESUME_PLATEAU_CEILING_MS = Number(process.env.DAWPRO_M20E_RESUME_CEILING_MS || 300);

let pass = 0, fail = 0, skipped = 0;
const ck = (name, cond, extra) => {
  if (cond) { pass++; console.log("PASS " + name); }
  else { fail++; console.log("FAIL " + name + (extra !== undefined ? " :: " + extra : "")); }
};
const skip = (name, reason) => { skipped++; console.log("SKIP " + name + " :: " + reason); };

if (!existsSync(BHRATE)) {
  console.log(`ABORT — device-rate helper missing: ${BHRATE}`);
  console.log("       build it:  swiftc -O scripts/gates/m20d-bhrate.swift -o scripts/gates/m20d-bhrate");
  process.exit(2);
}
const rate = (...args) => execFileSync(BHRATE, args, { encoding: "utf8" }).trim();
const readBackOf = s => { const m = /read-back=([0-9.]+)/.exec(s); return m ? Number(m[1]) : NaN; };
const wedgeSize = () => { try { return statSync(WEDGE_LOG).size; } catch { return null; } };

let ws;
let n = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `fp${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 25000);
    const h = ev => {
      const m = JSON.parse(ev.data);
      if (m.id !== i) return;
      clearTimeout(t); ws.removeEventListener("message", h); res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id: i, command, params }));
  });
}

const devicesOf = r => r.result?.devices ?? [];
const defaultUID = ds => (ds.find(d => d.isDefault) ?? {}).uid ?? null;
const bhOf = ds => ds.find(d => d.uid === UID) ?? {};

const tracks = [];

/// Graph + device + transport in one reading. The graph rate is stamped per
/// render callback by the instrumented Tier-1 blocks; it is 0 when nothing
/// rendered, so `callbacks` is checked wherever the rate is asserted.
async function stats(label) {
  const p = (await cmd("engine.performanceStats")).result ?? {};
  const o = (await cmd("project.overview")).result ?? {};
  const d = devicesOf(await cmd("output.listDevices"));
  const s = {
    sampleRate: p.sampleRate, quantum: p.quantumFrames, callbacks: p.callbackCount,
    frames: p.renderedFrames, beat: o.transport?.positionBeats,
    deviceRate: bhOf(d).sampleRate, pinned: bhOf(d).isSelected === true,
  };
  console.log(`  [stats ${label}] graph=${s.sampleRate} quantum=${s.quantum} device=${s.deviceRate} `
    + `pinned=${s.pinned} beat=${s.beat?.toFixed(2)} callbacks=${s.callbacks}`);
  return s;
}

// ═══════════════════════════════════════════════════════════════════════════
// m23-br-2 — `engine.auPrepareStats` helpers. See the header addendum for the
// full rationale; these are the ONE home for reading, comparing and settling
// the four monotone counters, so every leg below applies the same rules.
// ═══════════════════════════════════════════════════════════════════════════

function formatCounterLine(prefix, s) {
  return `  [${prefix}] instrumentPrepares=${s.instrumentPrepares} instrumentReleases=${s.instrumentReleases} `
    + `effectPrepares=${s.effectPrepares} effectReleases=${s.effectReleases} `
    + `tracks=${(s.tracks ?? []).length} effects=${(s.effects ?? []).length}`;
}

/// ONE read of `engine.auPrepareStats`, printed and returned verbatim. The
/// four counters are MONOTONE LIFETIME TOTALS with no reset seam (unlike
/// `engine.performanceStats(reset:)`) — the idiom is deliberately
/// read → act → read → subtract, which is what every leg below does via
/// `counterDelta`.
async function prepareCounters(label) {
  const r = await cmd("engine.auPrepareStats");
  const s = r.result ?? {};
  console.log(formatCounterLine(`counters ${label}`, s));
  return s;
}

/// FIELD BY FIELD, never `JSON.stringify(a) === JSON.stringify(b)` — object
/// key order on the wire is NOT stable (see the m23-br-2 header addendum: two
/// byte-different serializations of IDENTICAL data were observed with
/// `instrumentReleases`/`effectPrepares` swapped position between encodes).
/// Array order IS pinned (the registry sorts both `tracks` and `effects` by
/// id), so comparing the four scalar counters is sufficient.
function countersEqual(a, b) {
  return a.instrumentPrepares === b.instrumentPrepares
    && a.instrumentReleases === b.instrumentReleases
    && a.effectPrepares === b.effectPrepares
    && a.effectReleases === b.effectReleases;
}

/// The four deltas, printed every time — a red leg always shows its raw
/// before/after/delta numbers, never just PASS/FAIL.
function counterDelta(before, after) {
  const d = {
    instrumentPrepares: after.instrumentPrepares - before.instrumentPrepares,
    instrumentReleases: after.instrumentReleases - before.instrumentReleases,
    effectPrepares: after.effectPrepares - before.effectPrepares,
    effectReleases: after.effectReleases - before.effectReleases,
  };
  console.log(`      Δ instrumentPrepares=${d.instrumentPrepares} instrumentReleases=${d.instrumentReleases} `
    + `effectPrepares=${d.effectPrepares} effectReleases=${d.effectReleases}`);
  return d;
}

const isAllZero = d => d.instrumentPrepares === 0 && d.instrumentReleases === 0
  && d.effectPrepares === 0 && d.effectReleases === 0;

/// SETTLE before the second read — see the header addendum's "SETTLE BEFORE
/// THE SECOND READ" paragraph for the full reasoning: a read taken while an
/// async prepare/release Task is still in flight would report a partial
/// delta, indistinguishable from "a smaller storm" unless something polls to
/// quiescence first. Polls `engine.auPrepareStats` itself (cheap — one round
/// trip, no note.audition fan-out) until all four counters hold still for
/// `quietMs`, capped at `maxMs`. `quietMs=200` sits ~2.5× past the worst
/// measured storm span (80 ms, see header); `maxMs=3000` matches this file's
/// historical hammer windows, so a genuinely wedged prepare cannot hang the
/// gate silently — it times out and returns whatever was last read, still
/// printed, so a caller reading a suspiciously non-zero delta can tell it
/// apart from a settle that actually converged.
async function settleCounters(label, { maxMs = 3000, quietMs = 200, pollMs = 40 } = {}) {
  const t0 = Date.now();
  let last = (await cmd("engine.auPrepareStats")).result ?? {};
  let lastChangedAt = Date.now();
  while (Date.now() - t0 < maxMs) {
    await sleep(pollMs);
    const next = (await cmd("engine.auPrepareStats")).result ?? {};
    if (!countersEqual(last, next)) {
      last = next;
      lastChangedAt = Date.now();
    } else if (Date.now() - lastChangedAt >= quietMs) {
      break;
    }
  }
  const quietFor = Date.now() - lastChangedAt;
  const timedOut = Date.now() - t0 >= maxMs && quietFor < quietMs;
  console.log(`  [settle ${label}] quiet for ${quietFor}ms, ${Date.now() - t0}ms elapsed (cap ${maxMs}ms)`
    + (timedOut ? " ⚠️ TIMED OUT WITHOUT SETTLING — counters were still moving at the cap" : ""));
  console.log(formatCounterLine(`counters ${label} (settled)`, last));
  return last;
}

/// The audio-quality claims that survive from the retired `hammer()` — a
/// plain `mixer.masterAnalysis` loop, no `note.audition` fan-out. Kept only
/// where a leg still needs it (L3, L5, L7 param-mutation legs); see the
/// header addendum for which claim each surviving call carries.
async function meterProbe(label, ms) {
  const t0 = Date.now();
  let meters = 0, minPeak = Infinity, maxPeak = -Infinity;
  while (Date.now() - t0 < ms) {
    try {
      const m = await cmd("mixer.masterAnalysis");
      const p = m.result?.peakDB;
      if (Number.isFinite(p)) { meters++; minPeak = Math.min(minPeak, p); maxPeak = Math.max(maxPeak, p); }
    } catch { /* counted by absence */ }
  }
  console.log(`  [meter ${label}] n=${meters} peak ${minPeak === Infinity ? "n/a" : minPeak.toFixed(1)}`
    + `…${maxPeak === -Infinity ? "n/a" : maxPeak.toFixed(1)} dB over ${ms}ms`);
  return { meters, minPeak, maxPeak };
}

/// m23-bq-2 — SUPERSEDES `waitForTransportAdvance`. That helper returned the
/// instant `positionBeats` first read `> start + 0.05` past the mark, and its
/// four callers asserted only `.ok`, never a ceiling on `.ms`. Filed m23-bq-2:
/// the m23-bq freeze (`AudioEngine.recoverEngine`/`rebuildEngine` anchoring a
/// resume against a stale render clock — the mutant below reproduces it by
/// flipping `AudioEngine.swift:3975`'s `renderClockTrusted: false` to `true`,
/// anchored on `fromBeat: resume, tempoMap: anchor.tempoMap` because the
/// mutated text alone matches three sites — see the header)
/// can publish ONE small tick past that threshold and then hold there for the
/// rest of the frozen span — the roadmap filing measured a 0.065-beat seam
/// bump on the defective tree, bigger than the 0.05 gate, so the old check
/// read "advanced" on a playhead that was, in the sense that matters, still
/// frozen.
///
/// THE FIX: poll `positionBeats` densely for a FIXED window that runs well
/// past the expected legitimate gap, and report the LONGEST run of
/// consecutive samples that does not move — the PLATEAU — instead of the time
/// to the first tick. `resume*`'s `advanced`/`ms`/`from`/`to` fields are kept,
/// UNCHANGED semantics, for the printed summary only; `plateauMs` is what the
/// four call sites assert a ceiling on.
///
/// ⚠️ A fixed window is a deliberate trade against the superseded function's
/// unbounded (up to 20 s) wait: `player.isPlaying` is still deliberately NOT
/// consulted (m20-b measured `engine.isRunning == false` with
/// `player.isPlaying == true` after a config change, a known false positive),
/// so there is no cheaper "is it still recovering" signal to poll instead.
/// `RESUME_WINDOW_MS` is sized off the MEASURED clean-tree numbers in the
/// header, with margin stated there — not off this comment's guess.
///
/// SAMPLING CADENCE — WHY IT CANNOT ALIAS (the m23-bs-2 sampler-aliasing
/// law: "a sampler whose interval is close to the period of what it samples
/// aliases onto one phase and reports a confident wrong number"). `transport
/// .positionBeats` is not computed on demand: it is the value cached by
/// `AudioEngine.startPlayheadTask` (`AudioEngine.swift:3705`), which
/// republishes at a fixed ~30 Hz (`Task.sleep(for: .milliseconds(33))`). A
/// HEALTHY, unfrozen transport therefore shows the exact SAME float across
/// every poll landing inside one ~33 ms publish interval — quantization, not
/// a freeze. This file's control round trips run at ~0.2–1 ms/RTT on this
/// machine with no sleep between calls (a slower machine is diagnosed rather
/// than trusted — a wire-hiccup fallback below is counted and printed); at
/// that cadence a single 33 ms interval spans dozens of samples, so a 33 ms
/// plateau cannot hide between two polls. `EPS_BEATS` sits an order of
/// magnitude below one publish step (β·33 ms ≈ 0.066 beats at this fixture's
/// 120 BPM) and two orders above the float-repeat jitter of re-reading an
/// unchanged double, so it cannot mistake "same publish" for "next publish"
/// in either direction — the interval this samples at is far from the period
/// it is measuring, which is precisely what the law warns against getting
/// close to.
///
/// RIGHT-CENSORING. A plateau still open when `RESUME_WINDOW_MS` closes is a
/// LOWER BOUND, not a completed measurement — `censored: true` flags this so
/// the caller can skip-and-report (m23-bl/m23-bu-2 shape) instead of trusting
/// a number that only LOOKS like a finished one.
async function measureResumePlateau(label, { windowMs = RESUME_WINDOW_MS } = {}) {
  const start = (await cmd("project.overview")).result?.transport?.positionBeats ?? 0;
  const t0 = Date.now();
  const samples = [{ t: 0, beat: start }];
  let rttSum = 0, rttMax = 0, fallbacks = 0;
  while (Date.now() - t0 < windowMs) {
    const rt0 = Date.now();
    const raw = (await cmd("project.overview")).result?.transport?.positionBeats;
    // A well-formed reply missing positionBeats silently re-inserts the PREVIOUS
    // sample, which extends whatever run is in progress and inflates plateauMs —
    // a wire hiccup misread as an engine freeze. Counted and printed so a non-zero
    // reading is visible reason to distrust this measurement, never absorbed silently.
    const b = raw ?? samples[samples.length - 1].beat;
    if (raw === undefined) fallbacks++;
    const rtt = Date.now() - rt0;
    rttSum += rtt; rttMax = Math.max(rttMax, rtt);
    samples.push({ t: Date.now() - t0, beat: b });
  }
  const rttCount = samples.length - 1;
  const rttMeanMs = rttCount > 0 ? rttSum / rttCount : 0;

  // The old metric — printed only, see the doc comment.
  const advanceIdx = samples.findIndex((s, i) => i > 0 && s.beat > start + ADVANCE_EPS_BEATS);
  const advance = advanceIdx >= 0
    ? { ok: true, ms: samples[advanceIdx].t, from: start, to: samples[advanceIdx].beat }
    : { ok: false, ms: windowMs, from: start, to: samples[samples.length - 1].beat };

  // The plateau scan: the longest run of consecutive samples within
  // EPS_BEATS of the run's own first value.
  let runStart = 0, longest = { ms: 0, startIdx: 0, endIdx: 0 };
  for (let i = 1; i < samples.length; i++) {
    if (Math.abs(samples[i].beat - samples[runStart].beat) >= EPS_BEATS) {
      const ms = samples[i - 1].t - samples[runStart].t;
      if (ms > longest.ms) longest = { ms, startIdx: runStart, endIdx: i - 1 };
      runStart = i;
    }
  }
  const tailMs = samples[samples.length - 1].t - samples[runStart].t;
  const censored = tailMs >= longest.ms;   // the longest run never broke before the window closed
  if (censored) longest = { ms: tailMs, startIdx: runStart, endIdx: samples.length - 1 };

  console.log(`  [resume ${label}] ${rttCount} samples over ${windowMs}ms window `
    + `(RTT mean=${rttMeanMs.toFixed(2)}ms max=${rttMax}ms) `
    + `advance=${advance.ok ? advance.ms + "ms" : "NONE in window"} `
    + `plateau=${longest.ms}ms${censored ? " ⚠️ CENSORED (open at window close)" : ""} `
    + `beat ${samples[longest.startIdx].beat.toFixed(3)}→${samples[longest.endIdx].beat.toFixed(3)}`
    + (fallbacks > 0 ? ` ⚠️ ${fallbacks} FALLBACK READ(S) — untrustworthy, see doc comment` : ""));

  return { ...advance, plateauMs: longest.ms, censored, rttMeanMs, rttMaxMs: rttMax, samples: rttCount, fallbacks };
}

/// The ONE home for the m23-bq-2 ceiling assertion, so all four `resume*`
/// legs apply it identically.
///
/// ⚠️ CENSORING IS NOT ALWAYS AMBIGUOUS — a censored plateau is a LOWER
/// BOUND, and a lower bound that ALREADY exceeds the ceiling proves the true
/// (unknown, possibly larger) plateau exceeds it too; censoring there only
/// hides HOW FAR over, never WHETHER. So only a censored reading whose
/// observed portion is still under the ceiling is genuinely undecidable —
/// THAT is the case that skips-and-reports (m23-bl/m23-bu-2), never a
/// censored reading that is already over. Getting this backwards was a real
/// bug caught while characterizing the mutant at m23-bq-2: with the
/// characterization window (15 s) the L7(flip↑) leg's plateau exceeded the
/// window (14823 ms, ⚠️ CENSORED) while the SHIPPED ceiling is far smaller —
/// treating every censored reading as an inconclusive skip would have let
/// that leg (and, at the shipped 3 s window, potentially ALL FOUR under a
/// long-enough-running defect) report SKIP instead of the FAIL it plainly
/// is, defeating the whole point of a red-baseline mutant proof.
///
/// ⚠️ A SECOND wrinkle, same shape, found the same way: a censored-but-under-
/// ceiling reading is NOT always ambiguous either. At the SHIPPED window
/// (3000ms), the L6/L7(2nd rebuild) legs typically resume within ~35–40ms of
/// the mark, then run flat for the rest of a multi-second hammer window
/// simply because nothing ELSE moves the playhead off that (correctly)
/// steady value — the tail run can be the LAST completed interval AND still
/// win the "longest run" scan, so `censored` reads true on a perfectly
/// healthy engine. Distinguishing feature: `advance.ok` is true (the
/// transport plainly moved off `start` earlier in the window) — the open
/// tail is just "nothing changed after the resume," not "still possibly
/// frozen." Only a censored-under-ceiling reading that ALSO never advanced
/// is genuinely undecided (it could be a resume that hasn't happened yet, or
/// one so close to the window edge the plateau scan can't tell) — that is
/// the one case left that skips-and-reports.
function assertResumePlateauCeiling(labelPrefix, result, ceilingMs) {
  if (result.censored && result.plateauMs <= ceilingMs && result.ok) {
    ck(`${labelPrefix} ⚠️ m23-bq-2 CEILING — the resume plateau (longest freeze observed across `
       + `${RESUME_WINDOW_MS}ms after the mark) stayed at or under ${ceilingMs}ms `
       + `(mutant: AudioEngine.swift:3975 renderClockTrusted false→true — see header) `
       + `[open tail after a confirmed advance — benign, see doc comment]`,
       true, `plateau=${result.plateauMs}ms censored=${result.censored} advance=${result.ms}ms`);
    return;
  }
  if (result.censored && result.plateauMs <= ceilingMs) {
    skip(`${labelPrefix} m23-bq-2 plateau ceiling (${ceilingMs}ms)`,
      `measurement CENSORED — the longest plateau found so far (${result.plateauMs}ms, still under `
      + `the ${ceilingMs}ms ceiling) was still open when the ${RESUME_WINDOW_MS}ms window closed, `
      + `AND the transport never advanced past ${ADVANCE_EPS_BEATS} beats in this window either. `
      + `This run cannot tell whether it was about to resume (pass) or is genuinely still frozen `
      + `past the ceiling (fail) — genuinely undecided, investigate before trusting this leg.`);
    return;
  }
  ck(`${labelPrefix} ⚠️ m23-bq-2 CEILING — the resume plateau (longest freeze observed across `
     + `${RESUME_WINDOW_MS}ms after the mark) stayed at or under ${ceilingMs}ms `
     + `(mutant: AudioEngine.swift:3975 renderClockTrusted false→true — see header)`
     + (result.censored ? " [reading is a LOWER BOUND, still open at window close — the true "
        + "plateau is >= this and already exceeds the ceiling]" : ""),
     result.plateauMs <= ceilingMs, `plateau=${result.plateauMs}ms censored=${result.censored}`);
}

// ── L0: stage the loopback at the project rate BEFORE anything is built ─────
const wedgeBefore = wedgeSize();
console.log("device rate before staging:", rate());
const baseStaged = rate(String(PROJECT_RATE));
console.log(`staged -> ${baseStaged}`);
ck("L0 loopback staged at 48000 (both flips are measured against this baseline)",
   readBackOf(baseStaged) === PROJECT_RATE, baseStaged);
ck("L0 the wedge log is readable (its SIZE is the zero-growth leg's baseline)",
   wedgeBefore !== null, String(wedgeBefore));

buildOrAbort({ label: "building staging binary (m20e)…" });
startStaging({ gate: GATE, detached: true, logPath: STAGING_LOG });

let systemDefault = null;
try {
  ws = await connect();
  await sleep(1500);

  // ── L1: pin the loopback BEFORE any transport starts ──────────────────────
  let r = await cmd("output.listDevices");
  const initial = devicesOf(r);
  systemDefault = defaultUID(initial);
  ck("L1 a system default exists (the baseline the safety leg is measured against)",
     systemDefault !== null, JSON.stringify(initial));
  ck("L1 the loopback is present and the app reads it at 48000",
     bhOf(initial).sampleRate === PROJECT_RATE, JSON.stringify(bhOf(initial)));

  await cmd("project.new", { discardChanges: true });
  r = await cmd("output.setDevice", { uid: UID });
  ck("L1 output pinned to the loopback (nothing below may reach the speakers)",
     r.ok && bhOf(devicesOf(r)).isSelected === true, r.error);

  // ── L2: THE AUDITION-SEAM ANTI-BLINDNESS LEG ──────────────────────────────
  // Build the fixture and, for each track, hammer its OWN cold prepare with
  // zero delay after `track.setInstrument`. Every "zero re-prepares" leg below
  // asserts an absence; this proves the AUDITION seam (`note.audition`'s
  // `reason` field) can see the thing it is (elsewhere) asserting the absence
  // of. Measured cold window 43…86 ms. ⚠️ m23-br-2: this does NOT certify the
  // COUNTER seam `engine.auPrepareStats` — that is L2c, right below.
  let coldNotReady = 0;
  const coldPerTrack = [];
  for (let i = 0; i < N_TRACKS; i++) {
    r = await cmd("track.add", { kind: "instrument", name: `Flip${i}` });
    const id = (r.result?.track ?? r.result)?.id;
    if (!id) { ck(`L2 track ${i} added`, false, JSON.stringify(r)); break; }
    tracks.push(id);
    await cmd("track.setInstrument", { trackId: id, soundBank: { source: "gm", program: 16 + i } });
    const t0 = Date.now();
    let seen = 0;
    while (Date.now() - t0 < 500) {
      const a = await cmd("note.audition", { trackId: id, pitches: [60], velocity: 1, durationMs: 10 });
      if (a.result?.reason === "instrumentNotReady") seen++;
    }
    coldPerTrack.push(seen);
    coldNotReady += seen;
    // Repeating notes, NOT one long sustain. `recoverEngine` re-anchors and
    // `startPlayers` only schedules notes whose ONSET is still ahead, so a note
    // that began before the resume point is never re-sounded — measured: a
    // 128-beat held chord floored the master tap at −80 from the first flip
    // onward and never came back, which would make every meter leg unreadable.
    const notes = [];
    for (let b = 0; b < 200; b++) {
      notes.push({ pitch: 48 + (i % 12), startBeat: b, lengthBeats: 0.95, velocity: 100 });
    }
    // `atBeat`, NOT `startBeat` — `clip.addMIDI` rejects unknown keys, so the
    // wrong name is a refusal, not a default.
    r = await cmd("clip.addMIDI", { trackId: id, atBeat: 0, lengthBeats: 200, name: `Pulse${i}`, notes });
    if (!r.ok) ck(`L2 clip added on track ${i}`, false, JSON.stringify(r.error));
  }
  ck("L2 the fixture has every hosted track", tracks.length === N_TRACKS, tracks.length);
  console.log(`  cold-prepare not-ready per track: ${JSON.stringify(coldPerTrack)}`);
  ck("L2 ⚠️ THE AUDITION SEAM IS NOT BLIND — the registry seam reported instrumentNotReady "
     + "during the cold prepares (every ZERO leg on THIS seam is meaningless without this)",
     coldNotReady > 0, `${coldNotReady} observations across ${N_TRACKS} tracks`);

  // ── L2c: m23-br-2 — THE COUNTER'S OWN ANTI-BLINDNESS LEG ──────────────────
  // L2 (above) proves the AUDITION seam can see `instrumentNotReady`. It says
  // nothing about whether `engine.auPrepareStats`'s counters move — a
  // DIFFERENT observable, read off the registry directly rather than
  // inferred through `auditionAudibility`'s priority ordering. Every "delta
  // === 0" leg from L3 onward now asserts an absence on THIS seam, so this
  // seam gets its OWN positive control first — the exact defect m23-bq-2
  // paid for, reproduced here rather than assumed away. Same command shape
  // as the L2 fixture loop (GM sound bank only, never a third-party AU — a
  // real AUv2 wedges the main actor for minutes, m23-av) but on a track kept
  // OUT of `tracks[]`, so it cannot perturb any leg below that indexes into
  // that array.
  let counterL2cBefore = await prepareCounters("L2c before extra track");
  r = await cmd("track.add", { kind: "instrument", name: "CounterCheck" });
  const counterTrackId = (r.result?.track ?? r.result)?.id;
  ck("L2c extra track added", !!counterTrackId, JSON.stringify(r));
  r = await cmd("track.setInstrument", { trackId: counterTrackId, soundBank: { source: "gm", program: 40 } });
  ck("L2c setInstrument accepted", r.ok, JSON.stringify(r.error));
  let counterL2cAfterAdd = await settleCounters("L2c after prepare");
  let deltaL2cAdd = counterDelta(counterL2cBefore, counterL2cAfterAdd);
  ck("L2c ⚠️ THE COUNTER IS NOT BLIND — instrumentPrepares rose by exactly 1 for a real prepare",
     deltaL2cAdd.instrumentPrepares === 1, JSON.stringify(deltaL2cAdd));
  const counterL2cEntry = (counterL2cAfterAdd.tracks ?? []).find(t => t.trackId === counterTrackId);
  ck("L2c the new track appears in tracks[] with a keyDigest",
     !!counterL2cEntry && typeof counterL2cEntry.keyDigest === "string" && counterL2cEntry.keyDigest.length > 0,
     JSON.stringify(counterL2cEntry));

  // The "fresh prepare" control above (`attempted[id] == nil`) is NOT the
  // arithmetic the m20-d mutant actually produces. Every zero-delta leg from
  // L3 onward asserts absence on the RE-PREPARE path — a track that is
  // ALREADY hosted, whose key changes under it (`AUHostRegistry.swift:670`:
  // `if instruments[id] != nil { releaseInstrument(forTrack: id) }`, then
  // re-prepare) — so `instrumentPrepares` AND `instrumentReleases` both rise
  // for the SAME action, on the SAME track. Advisor review flagged that the
  // control above cannot distinguish that arithmetic from a registry that
  // only counts releases on teardown (`track.remove`) — a config-change
  // release would then read as a false zero downstream, and every "delta
  // === 0" leg below would still pass for the wrong reason. Re-key the SAME
  // track (still off `tracks[]`) with a different GM program while hosted,
  // and require BOTH counters to move by exactly 1 AND the keyDigest to
  // change — m23-br-1 measured this exact shape ("2 prepares / 1 release,
  // moved digest") for a program-change re-key.
  const counterL2cDigestBefore = counterL2cEntry.keyDigest;
  r = await cmd("track.setInstrument", { trackId: counterTrackId, soundBank: { source: "gm", program: 41 } });
  ck("L2c re-key setInstrument accepted", r.ok, JSON.stringify(r.error));
  let counterL2cAfterRekey = await settleCounters("L2c after re-key");
  let deltaL2cRekey = counterDelta(counterL2cAfterAdd, counterL2cAfterRekey);
  ck("L2c ⚠️ THE COUNTER IS NOT BLIND TO RE-PREPARE — instrumentPrepares rose by exactly 1 for a re-key on an already-hosted track",
     deltaL2cRekey.instrumentPrepares === 1, JSON.stringify(deltaL2cRekey));
  ck("L2c ⚠️ THE COUNTER IS NOT BLIND TO RE-PREPARE — instrumentReleases rose by exactly 1 for the SAME re-key (release-then-prepare, not just teardown)",
     deltaL2cRekey.instrumentReleases === 1, JSON.stringify(deltaL2cRekey));
  const counterL2cEntryRekey = (counterL2cAfterRekey.tracks ?? []).find(t => t.trackId === counterTrackId);
  ck("L2c re-key moved the keyDigest",
     !!counterL2cEntryRekey && counterL2cEntryRekey.keyDigest !== counterL2cDigestBefore,
     `before=${counterL2cDigestBefore} after=${counterL2cEntryRekey?.keyDigest}`);

  r = await cmd("track.remove", { trackId: counterTrackId });
  ck("L2c extra track removed", r.ok, JSON.stringify(r.error));
  let counterL2cAfterRemove = await settleCounters("L2c after release");
  let deltaL2cRemove = counterDelta(counterL2cAfterRekey, counterL2cAfterRemove);
  ck("L2c ⚠️ THE COUNTER IS NOT BLIND — instrumentReleases rose by exactly 1 for a teardown release (orthogonal to the re-key release above)",
     deltaL2cRemove.instrumentReleases === 1, JSON.stringify(deltaL2cRemove));

  // ── L3: baseline, device and graph both at the project rate ───────────────
  await cmd("transport.seek", { beats: 0 });
  await cmd("transport.play");
  await sleep(2500);
  let s = await stats("L3 baseline");
  ck("L3 render callbacks actually happened (a 0 reading is not evidence)",
     (s.callbacks ?? 0) > 0 && (s.frames ?? 0) > 0, JSON.stringify(s));
  ck("L3 graph at the project rate with the device also at 48000 (anti-vacuity pair)",
     s.sampleRate === PROJECT_RATE && s.deviceRate === PROJECT_RATE, JSON.stringify(s));
  ck("L3 the pin is still held (audio is going to the loopback, not the speakers)", s.pinned);
  // This run's own native pull size — device rate == graph rate here, so no
  // converter. Asserted against in L6, never hard-coded.
  const nativeQuantum = s.quantum;
  // m23-br-2: the notReady===0 claim moves to an exact counter delta. The
  // retired hammer's ONLY other job here was the master-tap liveness claim,
  // which the counter cannot make — that survives on the leaner `meterProbe`.
  const counterL3Before = await prepareCounters("L3 before quiescent window");
  const meterL3 = await meterProbe("L3 quiescent @48k", 2500);
  const counterL3After = await settleCounters("L3 after quiescent window");
  const deltaL3 = counterDelta(counterL3Before, counterL3After);
  ck("L3 ⚠️ m23-br-2 — no re-prepare while nothing has changed (exact counter delta)",
     isAllZero(deltaL3), JSON.stringify(deltaL3));
  ck("L3 the master tap is live and above the floor (meters flow)",
     meterL3.meters > 0 && meterL3.maxPeak > -40, `${meterL3.maxPeak} dB over ${meterL3.meters} reads`);

  // ── L4: FLIP DOWN, no mutation ────────────────────────────────────────────
  const counterL4Before = await prepareCounters("L4 before flip");
  console.log(`flip -> ${STAGED_DEVICE_RATE}:`, rate(String(STAGED_DEVICE_RATE)));
  const resume1 = await measureResumePlateau("after flip↓");
  ck("L4 ⚠️ PLAYBACK RESUMES after the flip (position advances again) — CORROBORATING against "
     + "the m20-d graphRate mutant, which resumed too",
     resume1.ok, `${resume1.from.toFixed(2)} → ${resume1.to.toFixed(2)} in ${resume1.ms} ms`);
  assertResumePlateauCeiling("L4", resume1, RESUME_PLATEAU_CEILING_MS);
  s = await stats("L4 device@44100, no mutation");
  ck("L4 the device really moved to 44100 (anti-vacuity — a silently failed write "
     + "makes every rate leg below vacuous)",
     s.deviceRate === STAGED_DEVICE_RATE, s.deviceRate);
  ck("L4 render callbacks survived the flip", (s.callbacks ?? 0) > 0, JSON.stringify(s));
  ck("L4 CORROBORATING — graph still 48000 with no rebuild yet (the mutant reads "
     + "48000 here too: the graph object has not been replaced)",
     s.sampleRate === PROJECT_RATE, s.sampleRate);
  // m23-br-2: this leg's retired hammer call existed ONLY to prove
  // notReady===0 — no meter claim was ever attached to it — so it is DROPPED
  // outright rather than shrunk to a meterProbe. The ~3000ms
  // `measureResumePlateau` call above already settles the counters far past
  // the measured storm span (9…80ms); `settleCounters` below is the honest
  // re-statement of that as an explicit check, not a bare assumption that it
  // held.
  const counterL4After = await settleCounters("L4 after flip, no mutation");
  const deltaL4 = counterDelta(counterL4Before, counterL4After);
  ck("L4 ⚠️ m23-br-2 — the flip ALONE re-prepares nothing (exact counter delta; the storm is "
     + "latent until the next tracksDidChange — see header)",
     isAllZero(deltaL4), JSON.stringify(deltaL4));

  // ── L5: ★ THE DISCRIMINATING RE-PREPARE LEG ★ ─────────────────────────────
  // A parameter-only mutation: `tracksDidChange` with NO rebuild. This is the
  // first re-entry into `syncAudioUnitInstruments` (AudioEngine.swift:1573)
  // after the flip, where the pre-m20-d key recomputation released every
  // hosted instrument. m23-br-2: the discriminator is now the EXACT counter
  // delta rather than a hammered sample count (mutant expectation TBD — see
  // header); the master-tap "never floored" claim survives on its own since
  // it is an audio-quality claim the counter cannot make.
  const counterL5Before = await prepareCounters("L5 before param mutation");
  r = await cmd("track.setVolume", { trackId: tracks[0], volume: 0.9 });
  ck("L5 parameter-only mutation accepted (forces tracksDidChange, no rebuild)", r.ok, r.error);
  const meterL5 = await meterProbe("L5 param mutation @ device 44100", 4000);
  const counterL5After = await settleCounters("L5 after param mutation");
  const deltaL5 = counterDelta(counterL5Before, counterL5After);
  ck("L5 ⚠️ m23-br-2 — ZERO AU RE-PREPARES across the first tracksDidChange after the flip "
     + "(exact counter delta; mutant TBD — orchestrator's own mutant run, see header)",
     isAllZero(deltaL5), JSON.stringify(deltaL5));
  ck("L5 the master tap never floored — no placeholder-silence gap "
     + "(CORROBORATING: the historical hammer-sampled mutant's storm was too brief to floor it "
     + "either — see header)",
     meterL5.maxPeak > -40, `peak ${meterL5.minPeak}…${meterL5.maxPeak} dB`);
  s = await stats("L5 after param mutation");
  ck("L5 graph rate unmoved by the mutation, device still 44100 (anti-vacuity pair)",
     s.sampleRate === PROJECT_RATE && s.deviceRate === STAGED_DEVICE_RATE, JSON.stringify(s));

  // ── L6: ★ THE DISCRIMINATING GRAPH-RATE LEG (m20-d's, re-proven live) ★ ────
  // A teardown-class change replaces the engine and rebuilds the graph. That is
  // where the pre-m20-d code re-read the device: mutant reads 44100 / quantum
  // 512 here, the real tree holds 48000 / quantum 557.
  const counterL6Before = await prepareCounters("L6 before teardown");
  r = await cmd("track.add", { kind: "audio", name: "Scratch" });
  const scratch = (r.result?.track ?? r.result)?.id;
  r = await cmd("track.remove", { trackId: scratch });
  ck("L6 teardown-class change accepted (forces the engine rebuild)", r.ok, r.error);
  // m23-br-2: this leg's retired hammer carried no claim but notReady===0 —
  // DROPPED, not shrunk. `measureResumePlateau` a few lines below still gives
  // a genuine settle window before the counters here are trusted.
  const counterL6After = await settleCounters("L6 after teardown");
  const deltaL6 = counterDelta(counterL6Before, counterL6After);
  ck("L6 ⚠️ m23-br-2 — no re-prepare across the rebuild (exact counter delta; the mutant's key "
     + "already moved at L5 — see header)",
     isAllZero(deltaL6), JSON.stringify(deltaL6));
  const resume2 = await measureResumePlateau("after rebuild@44.1k");
  ck("L6 CORROBORATING — playback resumes after the rebuild (rebuildEngine's OWN "
     + "renderClockTrusted call site, :1336, is untouched by the bq-2 mutant — expected "
     + "to stay green under it; see the header's discrimination table)", resume2.ok,
     `${resume2.from.toFixed(2)} → ${resume2.to.toFixed(2)} in ${resume2.ms} ms`);
  assertResumePlateauCeiling("L6", resume2, RESUME_PLATEAU_CEILING_MS);
  s = await stats("L6 after rebuild, device@44100");
  ck("L6 render callbacks actually happened (a 0 reading is not evidence)",
     (s.callbacks ?? 0) > 0, JSON.stringify(s));
  ck("L6 the device is still at 44100 under the rebuild (anti-vacuity)",
     s.deviceRate === STAGED_DEVICE_RATE, s.deviceRate);
  ck("L6 ⚠️ THE FLIP: a REBUILT graph still runs at 48000 with the device at 44100 "
     + "(mutant read 44100)",
     s.sampleRate === PROJECT_RATE, s.sampleRate);
  // Same fact seen mechanically: a 48 kHz graph feeding a 44.1 kHz device is
  // pulled for MORE frames per device callback, by exactly the rate ratio.
  // Compared against THIS run's own native pull, never a hard-coded 512 — that
  // would pass on any larger IO buffer for a reason unrelated to the flip.
  // ⚠️ NOT independent evidence: it is a second view of the L6 rate reading.
  const expected = nativeQuantum * (PROJECT_RATE / STAGED_DEVICE_RATE);
  console.log(`  quantum: native=${nativeQuantum} converted=${s.quantum} expected≈${expected.toFixed(1)}`);
  ck("L6 the output-edge converter is engaged — pull size scales by 48000/44100 "
     + "(mutant read the native size: no converter, graph == device)",
     Number.isFinite(s.quantum) && Math.abs(s.quantum - expected) <= 2,
     `${s.quantum} vs ≈${expected.toFixed(1)}`);

  // ── L7: FLIP BACK UP, both mutation classes again ─────────────────────────
  console.log(`flip -> ${PROJECT_RATE}:`, rate(String(PROJECT_RATE)));
  const resume3 = await measureResumePlateau("after flip↑");
  ck("L7 CORROBORATING — playback resumes after the second flip (this flip drives "
     + "recoverEngine again, the SAME call site as L4 — this leg reddens under the bq-2 "
     + "mutant; see the header's discrimination table)", resume3.ok,
     `${resume3.from.toFixed(2)} → ${resume3.to.toFixed(2)} in ${resume3.ms} ms`);
  assertResumePlateauCeiling("L7(flip↑)", resume3, RESUME_PLATEAU_CEILING_MS);
  s = await stats("L7 device back at 48000");
  ck("L7 the device really moved back to 48000 (anti-vacuity)",
     s.deviceRate === PROJECT_RATE, s.deviceRate);

  const counterL7ParamBefore = await prepareCounters("L7 before param mutation");
  r = await cmd("track.setVolume", { trackId: tracks[0], volume: 0.85 });
  ck("L7 parameter-only mutation accepted", r.ok, r.error);
  const meterL7Param = await meterProbe("L7 param mutation @ device 48000", 4000);
  const counterL7ParamAfter = await settleCounters("L7 after param mutation");
  const deltaL7Param = counterDelta(counterL7ParamBefore, counterL7ParamAfter);
  ck("L7 ⚠️ m23-br-2 — ZERO AU RE-PREPARES across the first tracksDidChange after the flip "
     + "BACK (exact counter delta; mutant TBD — orchestrator's own mutant run, see header)",
     isAllZero(deltaL7Param), JSON.stringify(deltaL7Param));
  ck("L7 the master tap is still live and above the floor", meterL7Param.maxPeak > -40,
     `peak ${meterL7Param.minPeak}…${meterL7Param.maxPeak} dB`);

  const counterL7TeardownBefore = await prepareCounters("L7 before second teardown");
  r = await cmd("track.add", { kind: "audio", name: "Scratch2" });
  const scratch2 = (r.result?.track ?? r.result)?.id;
  r = await cmd("track.remove", { trackId: scratch2 });
  ck("L7 second teardown-class change accepted", r.ok, r.error);
  // m23-br-2: same rationale as L6 — this hammer carried no claim but
  // notReady===0, DROPPED rather than shrunk.
  const counterL7TeardownAfter = await settleCounters("L7 after second teardown");
  const deltaL7Teardown = counterDelta(counterL7TeardownBefore, counterL7TeardownAfter);
  ck("L7 ⚠️ m23-br-2 — no re-prepare across the second rebuild (exact counter delta)",
     isAllZero(deltaL7Teardown), JSON.stringify(deltaL7Teardown));
  const resume4 = await measureResumePlateau("after second rebuild");
  ck("L7 CORROBORATING — playback resumes after the second rebuild (rebuildEngine's "
     + "OWN call site again, same as L6 — expected to stay green under the bq-2 mutant; "
     + "see the header's discrimination table)", resume4.ok,
     `${resume4.from.toFixed(2)} → ${resume4.to.toFixed(2)} in ${resume4.ms} ms`);
  assertResumePlateauCeiling("L7(2nd rebuild)", resume4, RESUME_PLATEAU_CEILING_MS);
  s = await stats("L7 final");
  // ⚠️ BOTH of these pass in the mutant too — its last rebuild happened with
  // the device back at 48 kHz, so the broken build converges on the same final
  // state. Read them as "the run ended consistent", never as the flip proof.
  ck("L7 CORROBORATING — graph 48000 and the device agrees again at the END of the "
     + "run (the mutant converges here too: see the final-state trap in the header)",
     s.sampleRate === PROJECT_RATE && s.deviceRate === PROJECT_RATE, JSON.stringify(s));
  ck("L7 CORROBORATING — the pull size is back to this run's native size "
     + "(converter disengaged; the mutant also read the native size here)",
     Math.abs(s.quantum - nativeQuantum) <= 2, `${s.quantum} vs ${nativeQuantum}`);
  ck("L7 the pin was never lost across four device events", s.pinned, JSON.stringify(s));

  // ── L8: storm-DEATH regression — the watchdog never had to save anything ──
  const w = (await cmd("engine.watchdogStatus")).result ?? {};
  console.log(`  watchdog ${JSON.stringify(w)}`);
  ck("L8 CORROBORATING — the engine never self-healed: restartCount 0 "
     + "(a storm that killed the render side would show here; the mutant also read 0)",
     w.restartCount === 0, JSON.stringify(w));
  ck("L8 the render heartbeat is alive and the main actor answered on the main-actor tier",
     w.engineRunning === true && w.mainActor?.responsive === true, JSON.stringify(w));

  // ── L9: the m20-j safety property ─────────────────────────────────────────
  r = await cmd("output.listDevices");
  ck("L9 SYSTEM DEFAULT UNMOVED across the whole gate",
     defaultUID(devicesOf(r)) === systemDefault,
     `${systemDefault} -> ${defaultUID(devicesOf(r))}`);
  await cmd("transport.stop");

  // ── L9b: PLATEAU-DETECTOR ANTI-BLINDNESS CONTROL (m23-bq-2) ────────────────
  // Every "plateau small" ceiling leg above asserts an ABSENCE (no long
  // freeze) — a detector that always reported plateauMs≈0, or one whose
  // sampling stalled and missed the freeze, would make all four ceiling
  // passes meaningless. `transport.stop()` just above supplies a GENUINE,
  // deliberate freeze for free: `AudioEngine.stopPlayback` (:947) pushes ONE
  // final beat and then cancels the playhead task outright, so
  // `positionBeats` is frozen bit-for-bit from that instant on — this is not
  // a simulated freeze, it is the same mechanism (no more publishes) that
  // makes the m23-bq mutant's freeze readable at all. `censored: true` here
  // is the EXPECTED reading (the plateau never breaks because nothing
  // publishes again), so this is the one call site that asserts ON
  // censoring rather than skipping it.
  const stopped = await measureResumePlateau("L9b anti-blindness (transport stopped)",
                                              { windowMs: 1000 });
  ck("L9b ⚠️ THE DETECTOR IS NOT BLIND — a genuinely, deliberately frozen transport "
     + "(stopped) reads as a plateau spanning (most of) the 1000ms observation window",
     stopped.censored && stopped.plateauMs >= 900,
     `plateau=${stopped.plateauMs}ms censored=${stopped.censored} of 1000ms window`);

  r = await cmd("output.setDevice", {});
  ck("L9 pin released", r.ok && devicesOf(r).every(d => !d.isSelected), r.error);
} catch (e) {
  fail++;
  console.log("FAIL gate threw :: " + (e?.stack ?? e?.message ?? e));
} finally {
  try { ws?.close(); } catch {}
  await sleep(500);
  try { stopStaging(GATE); } catch (e) { console.log("stopStaging: " + e?.message); }
  await sleep(600);

  // ── L10: zero wedge-log growth. SIZE delta only, read-only. ───────────────
  const wedgeAfter = wedgeSize();
  console.log(`  wedge log ${WEDGE_LOG}: ${wedgeBefore} -> ${wedgeAfter} bytes`);
  ck("L10 CORROBORATING — zero main-actor wedge-log growth (the mutant also grew by 0)",
     wedgeBefore !== null && wedgeAfter === wedgeBefore, `${wedgeBefore} -> ${wedgeAfter}`);

  // ── L11: the staging log. ⚠️ CONSTANT FIELD, printed not asserted. ────────
  // The roadmap asked for "absence of the HostedAUInstrument.swift:156
  // renegotiation line". Measured 0 in BOTH arms with the app writing 0 bytes
  // total, so it is reported as a number and never as a pass — a check that
  // cannot fail does not belong in the pass count. What IS asserted is the
  // presence of any renegotiation-FAILURE or recovery-FAILURE line, which are
  // genuine defect signals with a real chance of firing.
  let log = "";
  try { log = readFileSync(STAGING_LOG, "utf8"); } catch { /* absent == empty */ }
  const count = re => (log.match(re) ?? []).length;
  const reneg = count(/HostedAUInstrument: renegotiated render format/g);
  const renegFailed = count(/HostedAUInstrument: rate renegotiation .* failed/g);
  const recoveryFailed = count(/configuration-change recovery failed/g);
  console.log(`  staging log: ${log.length} bytes · renegotiated=${reneg} (CONSTANT FIELD — `
    + `0 in both arms, see header) · renegFailed=${renegFailed} · recoveryFailed=${recoveryFailed}`);
  ck("L11 no rate-renegotiation FAILURE and no config-change recovery FAILURE in the log",
     renegFailed === 0 && recoveryFailed === 0, `${renegFailed} / ${recoveryFailed}`);

  // ── L12: the ONE written setting, restored and VERIFIED by read-back ──────
  const restored = rate(String(RESTORE_RATE));
  console.log("device rate restored ->", restored);
  ck("L12 loopback nominal rate restored to 48000 (read-back verified)",
     readBackOf(restored) === RESTORE_RATE, restored);
}

// ═══════════════════════════════════════════════════════════════════════════
// L13 runs against its OWN websocket (`ws13`), separate from the module-level
// `ws`/`cmd()` used by the primary session above (which is already closed by
// the time L13 starts) — these three helpers are `cmd()`/`prepareCounters()`/
// `settleCounters()`'s twins, parameterized on the socket instead of closing
// over the module-level one.
// ═══════════════════════════════════════════════════════════════════════════
let l13n = 0;
function l13cmd(socket, command, params = {}) {
  return new Promise((res, rej) => {
    const i = `l13-${++l13n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 25000);
    const h = ev => {
      const m = JSON.parse(ev.data);
      if (m.id !== i) return;
      clearTimeout(t); socket.removeEventListener("message", h); res(m);
    };
    socket.addEventListener("message", h);
    socket.send(JSON.stringify({ id: i, command, params }));
  });
}
async function l13PrepareCounters(socket, label) {
  const r = await l13cmd(socket, "engine.auPrepareStats");
  const s = r.result ?? {};
  console.log(formatCounterLine(`counters ${label}`, s));
  return s;
}
async function l13SettleCounters(socket, label, { maxMs = 3000, quietMs = 200, pollMs = 40 } = {}) {
  const t0 = Date.now();
  let last = (await l13cmd(socket, "engine.auPrepareStats")).result ?? {};
  let lastChangedAt = Date.now();
  while (Date.now() - t0 < maxMs) {
    await sleep(pollMs);
    const next = (await l13cmd(socket, "engine.auPrepareStats")).result ?? {};
    if (!countersEqual(last, next)) {
      last = next;
      lastChangedAt = Date.now();
    } else if (Date.now() - lastChangedAt >= quietMs) {
      break;
    }
  }
  const quietFor = Date.now() - lastChangedAt;
  console.log(`  [settle ${label}] quiet for ${quietFor}ms, ${Date.now() - t0}ms elapsed (cap ${maxMs}ms)`);
  console.log(formatCounterLine(`counters ${label} (settled)`, last));
  return last;
}

// ── L13: m23-br-2 BONUS — EFFECT counters, moved over the wire for the FIRST
// time. `effectPrepares`/`effectReleases` are covered by Swift tests
// (`AUPrepareStatsTests`) but had never crossed the wire before this leg —
// no gate, no round trip. Deliberately placed AFTER L12's device-rate
// restore, and in a COMPLETELY SEPARATE staging session (its own build-free
// launch/connect/teardown), so that if AU hosting wedges here it can neither
// poison the primary legs' pass/fail counts above (already computed) nor
// leave the loopback's nominal rate unrestored (already restored above,
// independent of anything that happens below). Apple-manufactured 'aufx'
// effect only, resolved from `fx.listAudioUnits` — never a third-party AU
// (m23-av). If none is listed this leg SKIPS with a printed reason rather
// than silently certifying (m23-bl).
try {
  startStaging({ gate: GATE, detached: true, logPath: STAGING_LOG });
  const ws13 = await connect();
  await sleep(1500);
  let l13r = await l13cmd(ws13, "output.setDevice", { uid: UID });
  ck("L13 output pinned to the loopback (paranoia — this session never plays audio anyway)",
     l13r.ok, JSON.stringify(l13r.error));
  await l13cmd(ws13, "project.new", { discardChanges: true });

  const auList = (await l13cmd(ws13, "fx.listAudioUnits")).result?.audioUnits ?? [];
  const appleFx = auList.find(u => u.manufacturer === "appl");
  if (!appleFx) {
    skip("L13 effect counters (fx.add/fx.remove round trip)",
      `no Apple-manufactured 'aufx' effect listed — ${auList.length} total installed`);
  } else {
    console.log(`  L13 using ${appleFx.name} (${appleFx.type}/${appleFx.subType}/${appleFx.manufacturer})`);
    let addTrackR = await l13cmd(ws13, "track.add", { kind: "audio", name: "FxCheck" });
    const fxTrackId = (addTrackR.result?.track ?? addTrackR.result)?.id;
    ck("L13 host track added", !!fxTrackId, JSON.stringify(addTrackR));

    const counterL13Before = await l13PrepareCounters(ws13, "L13 before fx.add");
    const addR = await l13cmd(ws13, "fx.add", {
      trackId: fxTrackId, kind: "audioUnit",
      audioUnit: { type: appleFx.type, subType: appleFx.subType, manufacturer: appleFx.manufacturer },
    });
    ck("L13 fx.add accepted", addR.ok, JSON.stringify(addR.error));
    const fxEffectId = addR.result?.effectId;
    const counterL13AfterAdd = await l13SettleCounters(ws13, "L13 after fx.add");
    const deltaL13Add = counterDelta(counterL13Before, counterL13AfterAdd);
    ck("L13 ⚠️ m23-br-2 BONUS — effectPrepares rose by exactly 1 for a real effect prepare",
       deltaL13Add.effectPrepares === 1, JSON.stringify(deltaL13Add));
    // ⚠️ `EngineAUPrepareStats.EffectEntry` carries `effectId`/`keyDigest`/
    // `status` ONLY — no `trackId` (the registry keys effects by effectID
    // alone). Look it up by `effectId`.
    const fxEntry = (counterL13AfterAdd.effects ?? []).find(e => e.effectId === fxEffectId);
    ck("L13 the effect appears in effects[] with a keyDigest",
       !!fxEntry && typeof fxEntry.keyDigest === "string" && fxEntry.keyDigest.length > 0,
       JSON.stringify(fxEntry));

    const remR = await l13cmd(ws13, "fx.remove", { trackId: fxTrackId, effectId: fxEffectId });
    ck("L13 fx.remove accepted", remR.ok, JSON.stringify(remR.error));
    const counterL13AfterRemove = await l13SettleCounters(ws13, "L13 after fx.remove");
    const deltaL13Remove = counterDelta(counterL13AfterAdd, counterL13AfterRemove);
    ck("L13 ⚠️ m23-br-2 BONUS — effectReleases rose by exactly 1 for a real effect release",
       deltaL13Remove.effectReleases === 1, JSON.stringify(deltaL13Remove));
  }

  await l13cmd(ws13, "output.setDevice", {});
  try { ws13.close(); } catch {}
} catch (e) {
  fail++;
  console.log("FAIL L13 effect counters threw :: " + (e?.stack ?? e?.message ?? e));
} finally {
  await sleep(500);
  try { stopStaging(GATE); } catch (e) { console.log("stopStaging (L13): " + e?.message); }
}

console.log(`ORCH_M20E pass=${pass} fail=${fail} skipped=${skipped}`);
if (skipped) {
  console.log(`⚠️ ${skipped} leg(s) SKIPPED — either a plateau measurement was CENSORED (see the `
    + "SKIP lines above), or L13 found no Apple-manufactured effect installed. A skip is neither "
    + "pass nor fail; it must be investigated, not read as a pass (m23-bl/m23-bu-2).");
}
process.exit(fail ? 1 : 0);
