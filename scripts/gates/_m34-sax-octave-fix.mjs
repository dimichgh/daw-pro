// Drop the sax part an octave into the tenor's actual body.
//
// ⚠️ THE DEFECT WAS THE WRITING, NOT THE ENGINE. The melody sat at MIDI 65-77
// (F4-F5), mean 71.2 — thirteen semitones above the middle of a tenor's warm
// register (Bb2-Bb4). A tenor up there is thin and piping, which is exactly what
// the user described. The library samples G#2-E6, so the high notes existed and
// played; they were simply the wrong register for the instrument.
// ⭐ "Available on the instrument" is not "idiomatic for the instrument".
//
// ⛔ Never calls instrument.listAudioUnits (it wedged this app earlier today).
import { existsSync, mkdirSync, statSync } from "node:fs";
import { sleep, buildOrAbort, startStaging, connect } from "./_staging.mjs";

const GATE = "m34-sax-octave-fix";
const OUT =
  "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad/sax-octave";
mkdirSync(OUT, { recursive: true });
const PROJECT = `${process.env.HOME}/Music/DAW Pro Dogfood/2026-08-31 Sax Solo Demo.dawproj`;
const TARGET = -14.0;

buildOrAbort({ label: "building staging binary…" });
startStaging({ gate: GATE });
const ws = await connect();

let n = 0;
function raw(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `oc${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 180000);
    const h = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id !== i) return;
      clearTimeout(t); ws.removeEventListener("message", h); res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id: i, command, params }));
  });
}
async function cmd(c, p = {}) {
  const r = await raw(c, p);
  if (!r.ok) throw new Error(`${c} REFUSED :: ${r.error ?? JSON.stringify(r.result)}`);
  return r.result;
}
const lufsOf = async () => (await cmd("render.measureLoudness", {})).measurement;
const NM = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"];
const nn = (m) => `${NM[m % 12]}${Math.floor(m / 12) - 1}`;

try {
  await cmd("project.open", { path: PROJECT });
  const ov = await cmd("project.overview");
  const sax = (ov.tracks ?? []).find((t) => /sax/i.test(t.name ?? ""));
  if (!sax) throw new Error("no /sax/i track");
  const clip = (sax.clips ?? [])[0];
  if (!clip) throw new Error("sax track has no clip");

  // ⚠️ READ UNFILTERED. clip.setNotes is a WHOLE-ARRAY REPLACE, so anything not
  // in the array I send is deleted. `totalNotes` vs `returnedNotes` is the check
  // that I am holding the whole clip.
  const got = await cmd("clip.getNotes", { clipId: clip.id });
  const notes = got.notes ?? [];
  const total = got.totalNotes ?? notes.length;
  if (notes.length !== total)
    throw new Error(`partial read (${notes.length} of ${total}) — a whole-array write would DELETE the rest`);
  console.log(`sax clip: ${notes.length} notes (unfiltered, totalNotes=${total})`);

  const before = notes.map((x) => x.pitch);
  console.log(`before: ${nn(Math.min(...before))}..${nn(Math.max(...before))}  mean MIDI ${(before.reduce((a,b)=>a+b,0)/before.length).toFixed(1)}`);

  const moved = notes.map((x) => ({ ...x, pitch: x.pitch - 12 }));
  const lo = Math.min(...moved.map((x) => x.pitch));
  if (lo < 44) throw new Error(`transpose would go below the library's lowest sample (${nn(lo)} < G#2) — refusing`);
  await cmd("clip.setNotes", { clipId: clip.id, notes: moved });

  const back = await cmd("clip.getNotes", { clipId: clip.id });
  const after = (back.notes ?? []).map((x) => x.pitch);
  if (after.length !== before.length) throw new Error(`note count changed ${before.length} -> ${after.length}`);
  console.log(`after:  ${nn(Math.min(...after))}..${nn(Math.max(...after))}  mean MIDI ${(after.reduce((a,b)=>a+b,0)/after.length).toFixed(1)}`);

  // The sax now shares the piano's register; pull the comp back so it supports
  // rather than competes.
  const piano = (ov.tracks ?? []).find((t) => /piano/i.test(t.name ?? ""));
  if (piano) { await cmd("track.setVolume", { trackId: piano.id, volume: 0.38 }); console.log("piano trimmed to 0.38 (it now shares the sax's register)"); }

  // Re-level through the chain at its MEASURED location.
  const snap = await cmd("project.snapshot");
  const chain = snap.masterEffects;
  if (!Array.isArray(chain)) throw new Error("snapshot.masterEffects missing — refusing to level blind");
  for (const e of chain) await cmd("fx.remove", { trackId: "master", effectId: e.id });
  await cmd("mixer.setMasterVolume", { volume: 1.0 });
  const neutral = await lufsOf();
  const g = await cmd("fx.add", { trackId: "master", kind: "gain" });
  const gid = g.effectId ?? g.effect?.id;
  if (!gid) throw new Error("fx.add gain returned no id");
  await cmd("fx.setParam", { trackId: "master", effectId: gid, name: "gainLinear",
    value: Math.max(0.02, Math.min(4.0, Math.pow(10, (TARGET - neutral.integratedLufs) / 20))) });
  await cmd("fx.add", { trackId: "master", kind: "limiter" });
  const m = await lufsOf();
  console.log(`level: neutral ${neutral.integratedLufs.toFixed(2)} → ${m.integratedLufs.toFixed(2)} LUFS, peak ${m.truePeakDbtp.toFixed(2)} dBTP`);
  if (Math.abs(m.integratedLufs - TARGET) > 1.5) throw new Error("level correction did not take");

  const p = `${OUT}/sax-down-an-octave.wav`;
  await cmd("render.mixdown", { path: p });
  if (!existsSync(p) || statSync(p).size < 100000) throw new Error("render failed");
  console.log(`\nrendered ${p} (${statSync(p).size} bytes)`);
  await cmd("project.save", { path: PROJECT });
  console.log("saved.");
} catch (e) {
  console.log("ABORTED :: " + (e?.message ?? String(e)));
  process.exitCode = 1;
} finally {
  try { ws.close(); } catch {}
  await sleep(300);
}
