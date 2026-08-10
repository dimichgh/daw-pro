// m23-fi PROBE (companion) — ARE THE ARROW KEYS REACHABLE AFTER A RUBBER BAND?
//
// ⚠️ A PROBE, NOT A GATE. Staging (17695) only.
//
// ═══ WHY A SECOND PROCESS AND NOT ANOTHER LEG ═══
// `_m23fi-onkeypress-census.mjs` measured the arrow mounts LIVE — but every one
// of its legs runs after an `act:"click"`, which bumps `arrangeKeyFocusNonce`
// and asserts focus on the arrange workspace. Adding a marquee leg to the end of
// that run read `keyFocusNonce = 6` and `arrangeWorkspaceFocused = true` BEFORE
// the band was drawn: the focus was left over from the earlier clicks, and
// `project.new` does not reset it. That leg could not have failed, which is
// exactly the vacuity shape this milestone keeps paying for.
//
// The question needs a COLD app: one whose very FIRST arrange gesture is a
// rubber band. `AppModel.applyArrangeMarquee` (DAWProApp.swift:952) deliberately
// does NOT bump the key-focus nonce — its own comment gives the reason
// (asserting key focus mid-drag would fight the piano roll for the key window on
// every band update) — while the ←/→ and ↑/↓ mounts hang off exactly that focus.
// So "the arrows work" may be conditional on having CLICKED at least once.
//
//   node scripts/gates/_m23fi-marquee-focus-probe.mjs
import {
  buildOrAbort, startStaging, stopStaging, STAGING_PORT, sleep,
} from "./_staging.mjs";

const GATE = "m23fimarquee";
const PORT = STAGING_PORT;
const OUT = "/tmp/m23fimarquee";
const PIDFILE = "/tmp/m23fimarquee-staging.pid";
const SETTLE = 700;

async function connect() {
  for (let i = 0; i < 60; i++) {
    try {
      const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
      await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error("x")); });
      let nextId = 1; const pending = new Map();
      ws.onmessage = (ev) => {
        let m; try { m = JSON.parse(ev.data); } catch { return; }
        const e = pending.get(m.id); if (!e) return; pending.delete(m.id);
        if (m.ok === false || m.error) e.reject(new Error(`${e.command}: ${JSON.stringify(m.error)}`));
        else e.resolve(m.result ?? m);
      };
      const req = (command, params = {}) => {
        const id = String(nextId++);
        return new Promise((resolve, reject) => {
          pending.set(id, { resolve, reject, command });
          ws.send(JSON.stringify({ id, command, params }));
          setTimeout(() => {
            if (pending.has(id)) { pending.delete(id); reject(new Error(`timeout ${command}`)); }
          }, 25000);
        });
      };
      return { ws, req };
    } catch { await sleep(500); }
  }
  throw new Error("no connect");
}

buildOrAbort({ label: "building staging binary (m23-fi marquee probe)…" });
const { pid } = startStaging({
  gate: GATE, port: PORT, pidfile: PIDFILE, outDir: OUT,
  detached: true, logPath: `${OUT}/staging.log`,
});
console.log(`staging pid ${pid} on :${PORT}`);
await sleep(4500);
const { ws, req } = await connect();

let exitCode = 0;
try {
  const sel = (p = {}) => req("debug.arrangeSelection", p);
  const clipState = async (id) => {
    const tracks = (await req("project.snapshot", {})).tracks ?? [];
    for (const t of tracks) {
      const c = (t.clips ?? []).find((x) => x.id === id);
      if (c) return { trackId: t.id, startBeat: c.startBeat };
    }
    return null;
  };

  await req("debug.windowFrame", { width: 1400, height: 1000 });
  const trackId = (await req("track.add", { kind: "instrument", name: "M" })).id;
  const clipId = (await req("clip.addMIDI", {
    trackId, atBeat: 0, lengthBeats: 4,
    notes: [{ pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 100 }],
  })).id;
  await sleep(600);

  // ── THE COLD READ. Nothing has clicked anything yet. ─────────────────────
  const cold = await sel({});
  console.log("\n════ COLD STATE (no arrange click has happened in this process) ════");
  console.log(`   keyFocusNonce            = ${cold.keyFocusNonce}   (want 0)`);
  console.log(`   arrangeWorkspaceFocused  = ${cold.keyPressProbe.arrangeWorkspaceFocused}`);
  if (cold.keyFocusNonce !== 0) {
    console.log("   ⚠️ NOT COLD — something already asserted focus; this probe proves nothing.");
    exitCode = 3;
  }

  // ── RUBBER BAND over the clip ────────────────────────────────────────────
  const geo = await req("debug.arrangeMarquee", {});
  const top = geo.laneTops?.[0] ?? 0;
  const ppb = geo.ppb || 40;
  await req("debug.arrangeMarquee", { act: "begin", x: -5, y: top + 2 });
  await req("debug.arrangeMarquee", { act: "changed", x: ppb * 6, y: top + geo.rowHeight - 2 });
  const ended = await req("debug.arrangeMarquee",
    { act: "end", x: ppb * 6, y: top + geo.rowHeight - 2 });
  await sleep(500);

  const s0 = await sel({});
  const b = await clipState(clipId);
  console.log("\n════ AFTER THE BAND ════");
  console.log(`   selected                 = ${s0.count} clip(s) (${ended.selectedIds?.length ?? 0} hit)`);
  console.log(`   keyFocusNonce            = ${s0.keyFocusNonce}   (a marquee must not bump it)`);
  console.log(`   arrangeWorkspaceFocused  = ${s0.keyPressProbe.arrangeWorkspaceFocused}`);

  // ── POST → and see whether the arrow mount is entered at all ─────────────
  await sel({ act: "postKey", key: "right" });
  await sleep(SETTLE);
  const s1 = await sel({});
  const a = await clipState(clipId);
  const entered = s1.keyPressProbe.arrangeHorizontalArrow
    !== s0.keyPressProbe.arrangeHorizontalArrow;
  console.log("\n════ ⭐ THE VERDICT — → with a MARQUEE-ONLY selection ════");
  console.log(`   arrow mount counter ${s0.keyPressProbe.arrangeHorizontalArrow} -> `
    + `${s1.keyPressProbe.arrangeHorizontalArrow}   entered = ${entered}`);
  console.log(`   clip startBeat ${b?.startBeat} -> ${a?.startBeat}   moved = ${b?.startBeat !== a?.startBeat}`);

  // ── POSITIVE CONTROL — the SAME key after ONE click ──────────────────────
  // Without this a `false` above could be the fixture (band never selected
  // anything, window not key, geometry off) rather than the focus condition.
  await sel({ act: "click", clipId });
  await sleep(400);
  const s2 = await sel({});
  await sel({ act: "postKey", key: "right" });
  await sleep(SETTLE);
  const s3 = await sel({});
  const c = await clipState(clipId);
  console.log("\n════ CONTROL — the identical key after ONE click (nonce bumped) ════");
  console.log(`   keyFocusNonce ${s2.keyFocusNonce}  arrangeWorkspaceFocused `
    + `${s2.keyPressProbe.arrangeWorkspaceFocused}`);
  console.log(`   arrow mount counter ${s2.keyPressProbe.arrangeHorizontalArrow} -> `
    + `${s3.keyPressProbe.arrangeHorizontalArrow}   entered = `
    + `${s3.keyPressProbe.arrangeHorizontalArrow !== s2.keyPressProbe.arrangeHorizontalArrow}`);
  console.log(`   clip startBeat ${a?.startBeat} -> ${c?.startBeat}`);
} catch (e) {
  console.error("PROBE ERROR", e);
  exitCode = 2;
} finally {
  try { ws.close(); } catch { /* already gone */ }
  stopStaging(GATE, PIDFILE);
}
process.exit(exitCode);
