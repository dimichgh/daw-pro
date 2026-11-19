#!/usr/bin/env node
// TIE EVERY PICTURE CHANGE TO A SENTENCE, NOT A STOPWATCH.
//
// ⛔⛔ WHY: an observer found the picture contradicting the narration in four of
// the film's ten stages. `assemble.py`'s `stills()` computed
//   n = max(1, round(total / cut))
// and divided the time EVENLY — it never looked at the words. In the `effects`
// stage that put "A saturator" over the PHASER card and "A phaser" over HALL
// REVERB: eight sentences of wildly different lengths (0.47 s to 3.69 s) cut on
// a fixed 2.133 s timer. The film was naming one effect while showing another,
// which for a demo is the worst class of error — it teaches the wrong thing.
//
// This script reads each stage's `cutOn` (sentence indices where the picture
// should change — written by hand in manifest.json so a human can audit the
// mapping) and converts them to SECONDS against the narration that was actually
// recorded, writing `cutAt` for assemble.py to consume.
//
// ⚠ THE TIMING MODEL IS CHARACTER-PROPORTIONAL, AND THAT IS A STATED
// APPROXIMATION, NOT A MEASUREMENT. One voice at one speaking rate delivers
// roughly a constant characters-per-second, so a sentence's share of the
// characters is a good estimate of its share of the seconds. It is accurate to
// a few tenths — far better than a fixed timer, and it CANNOT drift by whole
// sentences, which is the failure being fixed. Where a boundary must be exact,
// the honest upgrade is word timestamps from the transcription gate; this does
// not pretend to be that.
import fs from "node:fs";
import { execFileSync, spawnSync } from "node:child_process";

// VOICE FILM COPY of features/sync-cuts.mjs: the only change is WHERE it looks.
// Both the manifest and the narration live in this folder (VOICE_HOME).
const DIR = process.env.VOICE_HOME
  || new URL(".", import.meta.url).pathname.replace(/\/$/, "");
const FILM = DIR;
const MANIFEST = `${DIR}/manifest.json`;

const dur = (p) => Number(execFileSync("ffprobe", [
  "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", p,
]).toString().trim());

/** Split on sentence-final punctuation, keeping the punctuation. */
const sentences = (s) => s.match(/[^.!?]+[.!?]+/g)?.map((x) => x.trim()) ?? [s];

/** Where the speaker actually stopped, in seconds: [{start, end}, ...].
 *
 * ⭐⭐ THIS IS THE UPGRADE THIS FILE USED TO PROMISE AND NOT DELIVER. The
 * character-proportional estimate below is good to a few tenths, which is fine
 * for a long sentence and NOT fine for a run of short ones: an observer
 * measured the `effects` cards landing 0.47 s and 0.79 s late, so "a saturator"
 * played over the DYNAMIC EQ card and "a phaser" over the SATURATOR card —
 * the same class of defect this script was written to kill, one card over.
 *
 * A sentence boundary is not a statistical quantity. It is a PAUSE, and a pause
 * is directly measurable. So: estimate by characters, then SNAP to the nearest
 * real silence. -35 dB with a 70 ms floor catches the gaps between "A phaser."
 * and "A hall reverb." without splitting a word on its own stop consonant.
 */
function pauses(path) {
  // ⚠ silencedetect logs to STDERR at INFO level; `-v error` would return an
  // empty list that reads exactly like "this take has no pauses in it".
  const r = spawnSync("ffmpeg", [
    "-hide_banner", "-i", path, "-af", "silencedetect=noise=-35dB:d=0.07",
    "-f", "null", "-",
  ], { encoding: "utf8" });
  const text = (r.stderr || "") + (r.stdout || "");
  const out = [];
  let start = null;
  for (const line of text.split("\n")) {
    const a = line.match(/silence_start:\s*(-?[\d.]+)/);
    if (a) { start = Number(a[1]); continue; }
    const b = line.match(/silence_end:\s*(-?[\d.]+)/);
    if (b && start !== null) { out.push({ start, end: Number(b[1]) }); start = null; }
  }
  return out;
}

/** Assign EVERY sentence boundary to a pause, IN ORDER.
 *
 * ⛔⛔ NEAREST-PAUSE MATCHING IS WRONG AND IT FAILED LOUDLY. The first version
 * of this snapped each cut point to the nearest pause independently. In a run
 * of short sentences — "A saturator." "A phaser." "A hall reverb." — the
 * nearest pause to a boundary is often the one that starts the NEXT sentence,
 * so each cut stole its neighbour's boundary and the whole run shifted by one.
 * An observer measured the result: the saturator card went from 0.79 s late to
 * 0.96 s late, and the PHASER card ended up on screen for 0.2 s — six frames —
 * while the words being spoken were "a hall reverb". The change made the defect
 * it was written to fix measurably worse.
 *
 * Worse, the log said `snapped +0.17s to a real pause` either way. It asserted
 * that *a* pause was found, never that it was the *right* one — a check that
 * reports success identically whether it succeeded or failed.
 *
 * ⭐ THE FIX IS THAT BOUNDARIES AND PAUSES ARE BOTH ORDERED SEQUENCES, so this
 * is an alignment, not a lookup. Dynamic programming over all m boundaries and
 * n pauses picks the strictly-increasing assignment minimising total deviation
 * from the character-proportional estimate. Aligning EVERY boundary — not only
 * the ones a picture cuts on — is what stops one cut consuming another's pause.
 *
 * Returns an array of m entries: {t, how}.
 */
function alignBoundaries(estimates, gaps, tol = 1.6) {
  const m = estimates.length, n = gaps.length;
  if (!m) return [];
  if (!n) return estimates.map((e) => ({ t: e, how: "estimate (no pauses found)" }));

  const INF = Infinity;
  // cost[k][i] = best total deviation assigning boundary k to pause i.
  const cost = Array.from({ length: m }, () => new Array(n).fill(INF));
  const from = Array.from({ length: m }, () => new Array(n).fill(-1));
  for (let i = 0; i < n; i++) cost[0][i] = Math.abs(gaps[i].end - estimates[0]);
  for (let k = 1; k < m; k++) {
    let bestPrev = INF, bestIdx = -1;
    for (let i = 0; i < n; i++) {
      // Boundary k must use a pause strictly after boundary k-1's.
      if (i > 0 && cost[k - 1][i - 1] < bestPrev) { bestPrev = cost[k - 1][i - 1]; bestIdx = i - 1; }
      if (bestPrev === INF) continue;
      cost[k][i] = bestPrev + Math.abs(gaps[i].end - estimates[k]);
      from[k][i] = bestIdx;
    }
  }
  let end = -1, best = INF;
  for (let i = 0; i < n; i++) if (cost[m - 1][i] < best) { best = cost[m - 1][i]; end = i; }
  if (end < 0) return estimates.map((e) => ({ t: e, how: "estimate (no ordered assignment)" }));

  const pick = new Array(m);
  for (let k = m - 1, i = end; k >= 0; k--) { pick[k] = i; i = from[k][i]; }

  return estimates.map((e, k) => {
    const g = gaps[pick[k]];
    const d = g.end - e;
    // A pause that far from the estimate is more likely a mid-sentence breath
    // than this boundary; keep the estimate and SAY so rather than pretend.
    if (Math.abs(d) > tol) return { t: e, how: `estimate (nearest ordered pause ${d >= 0 ? "+" : ""}${d.toFixed(2)}s away)` };
    return { t: g.end, how: `aligned ${d >= 0 ? "+" : ""}${d.toFixed(2)}s` };
  });
}

const man = JSON.parse(fs.readFileSync(MANIFEST, "utf8"));
let changed = 0, skipped = [];

for (const st of man.stages) {
  const cutOn = st.cutOn;
  if (!cutOn || !cutOn.length) { delete st.cutAt; continue; }

  const vo = `${FILM}/vo/${st.id}.wav`;
  if (!fs.existsSync(vo)) { skipped.push(`${st.id}: no ${vo}`); continue; }

  const total = dur(vo);
  const sents = sentences(st.narration);
  // Cumulative character count up to the START of each sentence.
  const lens = sents.map((x) => x.length);
  const sum = lens.reduce((a, b) => a + b, 0);
  const startOf = [];
  let acc = 0;
  for (const L of lens) { startOf.push(acc / sum); acc += L; }

  const bad = cutOn.filter((i) => !Number.isInteger(i) || i < 1 || i >= sents.length);
  if (bad.length) {
    // ⛔ LOUD, NOT SILENT. An out-of-range index means the narration was edited
    // and the mapping was not — exactly the drift this file exists to prevent.
    console.error(`⛔ ${st.id}: cutOn ${JSON.stringify(bad)} out of range — ` +
                  `narration has ${sents.length} sentences (valid: 1..${sents.length - 1})`);
    process.exitCode = 1;
    continue;
  }
  const nShots = (st.shots || []).length;
  if (cutOn.length + 1 !== nShots) {
    console.error(`⛔ ${st.id}: ${cutOn.length} cut point(s) makes ${cutOn.length + 1} ` +
                  `segments but there are ${nShots} shot(s) — they must match`);
    process.exitCode = 1;
    continue;
  }

  const gaps = pauses(vo);
  // ⚠ ALIGN EVERY INTERNAL BOUNDARY (1 .. n-1), not just the ones in `cutOn`.
  // The alignment is only correct if it sees the whole sequence: a cut that
  // picks its pause in isolation will happily take the one belonging to the
  // sentence after it, which is exactly how a run of short sentences slipped
  // by one card.
  const idx = sents.map((_, i) => i).slice(1);
  const aligned = alignBoundaries(idx.map((i) => startOf[i] * total), gaps);
  const at = new Map(idx.map((i, k) => [i, aligned[k]]));

  st.cutAt = cutOn.map((i) => Number(at.get(i).t.toFixed(3)));
  changed++;
  console.log(`${st.id.padEnd(14)} ${total.toFixed(1)}s  ${sents.length} sentences, ${gaps.length} pauses`);
  for (const i of cutOn) {
    const a = at.get(i);
    console.log(`    ${(sents[i].slice(0, 30) + "…").padEnd(33)} ${a.t.toFixed(2)}s  (${a.how})`);
  }
}

if (skipped.length) {
  console.error(`\n⚠ ${skipped.length} stage(s) skipped — narration not recorded yet:`);
  for (const s of skipped) console.error(`   ${s}`);
}
if (process.exitCode === 1) {
  console.error("\n⛔ manifest NOT written — fix the mappings above first.");
  process.exit(1);
}
fs.writeFileSync(MANIFEST, JSON.stringify(man, null, 2) + "\n");
console.log(`\n✅ wrote cutAt for ${changed} stage(s)`);
