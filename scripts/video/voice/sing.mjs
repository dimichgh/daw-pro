#!/usr/bin/env node
// CHAPTER "words onto the lead notes" + "the singer sings them".
//
// The Sing sheet is driven through debug.singScreens (the click's own model
// methods), photographed at each step, and its words are QUOTED from its echo
// (work/sheet-*.json) — never from a design doc. The take itself is started
// with sing.render, the wire twin of the sheet's [Sing it] (same coordinator;
// design §6 "one command surface"). ⚠ Consequence, MEASURED in source
// (DAWProApp.swift router.singJobSubmitted): a wire job shows on the progress
// card as "AGENT", not "SING". The narration says so rather than hiding it.
//
// ⛔ AIR STAYS AT ZERO (user ruling 2026-10-07): asserted from the echo before
// anything is sung; `air` is never sent.
import { writeFileSync } from "node:fs";
import { open, close, cmd, sleep, VOICE_HOME } from "./wire.mjs";
import { shot } from "./shoot.mjs";

const WORK = `${VOICE_HOME}/work`;
const state = JSON.parse((await import("node:fs")).readFileSync(`${WORK}/state.json`, "utf8"));
const SEED = 2611;
const melody = state.clips.melody;
const echo = async () => (await cmd("debug.singScreens", {})).sheet;
const dump = (name, obj) => writeFileSync(`${WORK}/${name}.json`, JSON.stringify(obj, null, 2));

await open();
try {
  await cmd("project.open", { path: state.project, discardChanges: true });
  await cmd("ui.showMixer", { show: false });

  // 1. the sheet on the lead melody, before any words
  await cmd("view.selectClip", { clipId: melody });
  await cmd("debug.stepSequencer", { mode: "notes" });
  await cmd("debug.singScreens", { screen: "sheet", clipId: melody });
  await sleep(800);
  const s0 = await echo();
  dump("sheet-0-empty", s0);
  if (!s0.open) throw new Error("the Sing sheet did not open");
  if ((s0.expression.air ?? 0) !== 0) throw new Error(`Air is ${s0.expression.air}, not zero — refusing`);
  await shot("s06-sheet-empty");

  // 2. the words, typed into WORDS (the field's own setter)
  await cmd("debug.singScreens", { screen: "sheetState", text: state.lyrics });
  await sleep(600);
  const s1 = await echo();
  dump("sheet-1-words", s1);
  console.log("chips:", s1.chips.length, "warnings:", JSON.stringify(s1.warnings), "height:", JSON.stringify(s1.height));
  await shot("s07-sheet-words");

  // 3. a harmony, a third above
  await cmd("debug.singScreens", { screen: "sheetState", parts: ["thirdAbove"] });
  await sleep(600);
  const s2 = await echo();
  dump("sheet-2-harmony", s2);
  console.log("harmony:", JSON.stringify(s2.harmony));
  await shot("s08-sheet-harmony");
  if ((s2.expression.air ?? 0) !== 0) throw new Error("Air moved off zero — refusing to sing");

  // 4. sing: the lead and the harmony in one take, on a fixed seed so every
  // rebuild hears the SAME take (a re-sung take would rot every measurement).
  await cmd("debug.singScreens", { close: true });
  const job = await cmd("sing.render", {
    clipId: melody, lyrics: state.lyrics, voiceId: "builtin-1", seed: SEED,
    parts: [{ kind: "harmony", interval: "third", direction: "above" }],
  }, 120000);
  dump("sing-plan", job);
  console.log("job", job.jobId, "estimated", job.plan?.estimatedSeconds, "s; parts", JSON.stringify(job.plan?.parts?.map((p) => [p.role, p.name, p.range?.sentence])));

  let st, shotTaken = false;
  for (let i = 0; i < 600; i++) {
    st = await cmd("sing.jobStatus", { jobId: job.jobId });
    if (!shotTaken && st.state === "running" && (st.progress ?? 0) > 0.15) {
      await shot("s09-singing");           // the REAL progress card, mid-job
      shotTaken = true;
    }
    if (["landed", "done", "failed", "cancelled"].includes(st.state)) break;
    await sleep(2000);
  }
  dump("sing-status-landed", st);
  console.log("state", st.state, st.stageText, st.error ? JSON.stringify(st.error) : "");
  if (!["landed", "done"].includes(st.state)) throw new Error(`the take did not land: ${st.state}`);
  // wait for the checks (notes, words) so the result is final
  for (let i = 0; i < 120 && st.state === "landed"; i++) { await sleep(2000); st = await cmd("sing.jobStatus", { jobId: job.jobId }); }
  dump("sing-status-final", st);
  console.log("final", st.state, JSON.stringify(st.result?.noteAccuracy), JSON.stringify(st.result?.wordCheck));

  const ov = await cmd("project.overview", {});
  const parts = st.parts || [];
  const leadPart = parts.find((p) => p.role === "lead");
  const harmPart = parts.find((p) => p.role === "harmony");
  state.sung = {
    seed: SEED, jobId: job.jobId,
    vocalTrack: leadPart?.trackId ?? st.result?.trackId, vocalClip: leadPart?.clipId ?? st.result?.clipId,
    harmonyTrack: harmPart?.trackId, harmonyClip: harmPart?.clipId,
    tracks: ov.tracks.map((t) => ({ id: t.id, name: t.name, kind: t.kind })),
  };
  await cmd("view.selectClip", { clipId: state.sung.vocalClip });
  await shot("s10-sung");
  await cmd("project.save", { path: state.project });
  writeFileSync(`${WORK}/state.json`, JSON.stringify(state, null, 2));
  console.log(JSON.stringify(state.sung, null, 2));
} catch (err) {
  // ⛔ WITHOUT THIS, AN ERROR EXITS 0: the finally below calls process.exit,
  // which ends the process before Node reports the rejection. MEASURED
  // 2026-10-11: tune.mjs died after one still and printed "exit 0".
  console.error("⛔", err?.stack || err);
  process.exitCode = 1;
} finally {
  close();
  process.exit(process.exitCode ?? 0);
}
