// m17-a orchestrator gate — built-in insert effect editors (22 checks: wire fx.add no-auto-open,
// reverb card params == fx.describe, 10-set burst = ONE undo entry + revert, card==wire twin equivalence,
// MASTER gain card, one-editor-at-a-time, close verb). Staging: DAW_CONTROL_PORT=17695 .build/debug/DAWApp.
// Promoted from session scratchpad 2026-07-16 (m17-g). Wire error is a STRING; kill staging exact-PID only.
// m17-a orchestrator gate — disjoint scenarios: reverb card, master gain card,
// wire-add-no-popup, own undo burst, one-at-a-time via state reads.
// NOTE: capture/output paths point at /tmp/daw-gate-out — `mkdir -p /tmp/daw-gate-out` before running.
const SCRATCH = "/tmp/daw-gate-out/m17a";

async function connect() {
  for (let i = 0; i < 15; i++) {
    try {
      return await new Promise((res, rej) => {
        const ws = new WebSocket("ws://127.0.0.1:17695");
        ws.addEventListener("open", () => res(ws));
        ws.addEventListener("error", () => rej(new Error("refused")));
      });
    } catch { await new Promise(r => setTimeout(r, 1000)); }
  }
  throw new Error("could not connect after 15s");
}
const ws = await connect();
let n = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `o${++n}`;
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
let pass = 0, fail = 0;
const ck = (name, cond, extra) => {
  if (cond) { pass++; console.log("PASS " + name); }
  else { fail++; console.log("FAIL " + name + (extra !== undefined ? " :: " + extra : "")); }
};
const near = (a, b) => typeof a === "number" && Math.abs(a - b) < 1e-9;
function findEffect(snap, effectID) {
  const doc = snap.project ?? snap;
  const chains = [...(doc.tracks ?? []).map(t => t.effects ?? []), doc.masterEffects ?? []];
  for (const chain of chains) for (const e of chain) if (e.id === effectID) return e;
  return null;
}
const paramOf = (e, name) => (e?.params?.[name] ?? e?.parameters?.[name] ?? e?.[name]);

let r = await cmd("project.new");
ck("project.new ok", r.ok, r.error);

// Reverb param names from fx.describe (schema-driven, not hardcoded)
r = await cmd("fx.describe", { kind: "reverb" });
const rvParams = r.result?.kinds?.[0]?.params ?? [];
ck("fx.describe reverb has params", rvParams.length >= 1, JSON.stringify(r.result)?.slice(0, 120));
const P = rvParams[0];

// Wire add must NOT auto-open a card
r = await cmd("track.add", { kind: "audio", name: "OrchA" });
const tidA = (r.result?.track ?? r.result)?.id;
ck("track A ok", r.ok && !!tidA);
r = await cmd("fx.add", { trackId: tidA, kind: "reverb" });
const e1 = r.result?.effectId ?? r.result?.effect?.id;
ck("fx.add reverb ok", r.ok && !!e1, JSON.stringify(r.result)?.slice(0, 120));
r = await cmd("debug.effectEditor", {});
ck("wire fx.add did NOT auto-open a card", r.ok && r.result?.visible === false, JSON.stringify(r.result)?.slice(0, 150));

// Open reverb card via seam; capture for my pixel review
r = await cmd("debug.effectEditor", { trackId: tidA, effectId: e1, open: true });
ck("reverb card open", r.ok && r.result?.visible === true, JSON.stringify(r.result)?.slice(0, 150));
ck("card values expose describe params", rvParams.every(s => typeof r.result?.values?.[s.name] === "number"),
  JSON.stringify(r.result?.values));
r = await cmd("debug.captureUI", { path: `${SCRATCH}/orch-reverb-card.png` });
ck("reverb card captured", r.ok, r.error);

// Undo burst: 10 card-path sets = ONE undo entry; undo reverts
r = await cmd("edit.history");
const undoBefore = (r.result?.undo ?? []).length;
const beforeVal = (await cmd("debug.effectEditor", {})).result?.values?.[P.name];
const target = Math.min(P.max, Math.max(P.min, (P.min + P.max) / 2 + (P.max - P.min) * 0.17));
for (let i = 1; i <= 10; i++) {
  const v = P.min + (target - P.min) * (i / 10);
  r = await cmd("debug.effectEditor", { param: P.name, value: v });
  if (!r.ok) { ck(`burst set ${i}`, false, r.error); break; }
}
r = await cmd("edit.history");
const undoAfter = (r.result?.undo ?? []).length;
ck("10-set burst = exactly ONE new undo entry", undoAfter === undoBefore + 1, `${undoBefore} -> ${undoAfter}`);
r = await cmd("project.snapshot");
ck("param landed in snapshot", near(paramOf(findEffect(r.result, e1), P.name), target),
  `${paramOf(findEffect(r.result, e1), P.name)} vs ${target}`);
r = await cmd("edit.undo");
ck("undo ok", r.ok, r.error);
r = await cmd("project.snapshot");
ck("undo reverted the burst", near(paramOf(findEffect(r.result, e1), P.name), beforeVal),
  `${paramOf(findEffect(r.result, e1), P.name)} vs ${beforeVal}`);

// Twin equivalence on reverb (agent used EQ): card path vs fx.setParam
r = await cmd("track.add", { kind: "audio", name: "OrchB" });
const tidB = (r.result?.track ?? r.result)?.id;
r = await cmd("fx.add", { trackId: tidB, kind: "reverb" });
const e2 = r.result?.effectId ?? r.result?.effect?.id;
ck("twin reverb ok", r.ok && !!e2);
r = await cmd("fx.setParam", { trackId: tidB, effectId: e2, name: P.name, value: target });
ck("wire setParam ok", r.ok, r.error);
r = await cmd("debug.effectEditor", { param: P.name, value: target });
ck("card set ok", r.ok, r.error);
r = await cmd("project.snapshot");
const v1 = paramOf(findEffect(r.result, e1), P.name), v2 = paramOf(findEffect(r.result, e2), P.name);
ck("card path == wire path (value-compare)", near(v1, target) && near(v2, target), `${v1} / ${v2} vs ${target}`);

// Master chain: gain card (kind agent didn't live-test on master) + one-at-a-time
r = await cmd("fx.add", { trackId: "master", kind: "gain" });
const em = r.result?.effectId ?? r.result?.effect?.id;
ck("master gain add ok", r.ok && !!em, r.error);
r = await cmd("debug.effectEditor", { trackId: "master", effectId: em, open: true });
ck("master card open (replaces reverb card — one at a time)", r.ok && r.result?.visible === true
  && typeof r.result?.values?.gainLinear === "number", JSON.stringify(r.result)?.slice(0, 150));
r = await cmd("debug.effectEditor", { param: "gainLinear", value: 0.5 });
ck("master card set ok", r.ok, r.error);
r = await cmd("project.snapshot");
ck("master param landed", near(paramOf(findEffect(r.result, em), "gainLinear"), 0.5),
  paramOf(findEffect(r.result, em), "gainLinear"));
r = await cmd("debug.captureUI", { path: `${SCRATCH}/orch-master-gain-card.png` });
ck("master card captured", r.ok, r.error);
r = await cmd("debug.effectEditor", { close: true });
ck("close ok", r.ok && r.result?.visible === false);

console.log(`ORCH_GATE pass=${pass} fail=${fail}`);
ws.close();
process.exit(fail ? 1 : 0);
