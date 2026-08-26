// m26-i UI half — RENDER PROBE (not a gate; a hands-on instrument).
//
// The card built for m26-i was never rendered by anyone: the building agent
// correctly refused to bind 17600 (the user's live app). Every test, grep and
// screenshot in that round would look IDENTICAL if the card crashed on open or
// drew empty — so this drives a REAL app on staging 17695 and captures pixels.
//
// The fixture carries a DELIBERATE INTERIOR PITCH GAP (zones cover 0-47 and
// 60-84, leaving 48-59 empty). That is the case a naive min/max coverage
// report hides — it would print "0-84, covered" — and it is exactly the class
// of failure that cost an earlier session real time. If the header does not
// say a gap exists, the feature is broken no matter how green the suite is.
//
// Port law: staging 17695 ONLY. 17600 is the user's app and is never a target.
import {
  launchStaging, stopStaging, STAGING_PORT, LIVE_PORT, assertStagingPort,
} from "./_staging.mjs";

const GATE = "m26i-sampler-card";
const SCRATCH = process.env.M26I_SCRATCH
  || "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad";

assertStagingPort(STAGING_PORT);
if (STAGING_PORT === LIVE_PORT) { console.log("FAIL port law"); process.exit(1); }

let pass = 0, fail = 0;
const ck = (name, ok, detail = "") => {
  if (ok) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name} :: ${String(detail).slice(0, 300)}`); }
};

// The socket is a browser-style WebSocket (addEventListener/ev.data) — the
// corpus idiom, copied verbatim from m17a-insert-editors.mjs. Node's `.on`
// does not exist on it.
let ws, id = 0;
const cmd = (command, params = {}) => new Promise((res, rej) => {
  const i = `m26i${++id}`;
  const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 25000);
  const h = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id !== i) return;
    clearTimeout(t); ws.removeEventListener("message", h); res(m);
  };
  ws.addEventListener("message", h);
  ws.send(JSON.stringify({ id: i, command, params }));
});

try {
  const s = await launchStaging({ gate: GATE, settleMs: 1200 });
  ws = s.ws;
  console.log(`staging pid=${s.pid} port=${STAGING_PORT}`);

  let r = await cmd("project.new", {});
  ck("project.new", r.ok, r.error);

  r = await cmd("track.add", { name: "Sax Probe", kind: "instrument" });
  ck("track.add", r.ok, r.error);
  const trackId = r.result?.id ?? r.result?.track?.id ?? r.result?.trackId;
  ck("track id returned", !!trackId, JSON.stringify(r.result)?.slice(0, 200));

  // Three zones, an INTERIOR GAP between 47 and 60, distinct velocity layers
  // on the low island so the zone list has more rows than pitch islands.
  const zones = [
    { path: `${SCRATCH}/zone1.wav`, rootPitch: 36, minPitch: 0,  maxPitch: 47, minVelocity: 0,  maxVelocity: 63 },
    { path: `${SCRATCH}/zone2.wav`, rootPitch: 36, minPitch: 0,  maxPitch: 47, minVelocity: 64, maxVelocity: 127 },
    { path: `${SCRATCH}/zone3.wav`, rootPitch: 72, minPitch: 60, maxPitch: 84 },
  ];
  r = await cmd("track.setInstrument", { trackId, kind: "sampler", sampler: { zones } });
  ck("sampler with 3 zones + interior gap", r.ok, r.error);

  // --- the actual question: does the card open and draw? ---
  r = await cmd("debug.samplerEditor", { open: true, trackId });
  ck("card OPENS without throwing", r.ok, r.error);
  ck("card reports visible", r.result?.visible === true, JSON.stringify(r.result)?.slice(0, 400));
  console.log(`  state: ${JSON.stringify(r.result)?.slice(0, 600)}`);

  // The state response exposes `headline` + `gapCount` (NOT a `coverage`
  // object — my first probe asserted the wrong shape and failed against
  // working code, which is why the raw state is printed above).
  ck("zone count is 3", r.result?.zoneCount === 3, JSON.stringify(r.result)?.slice(0, 300));
  ck("INTERIOR GAP is counted", r.result?.gapCount === 1, `gapCount=${r.result?.gapCount}`);
  ck("INTERIOR GAP is stated in the visible headline",
    typeof r.result?.headline === "string" && /gap/i.test(r.result.headline),
    r.result?.headline);
  // Negative control: a sampler with NO hole must NOT claim a gap, or the
  // assertion above is satisfied by a constant.
  const contiguous = [
    { path: `${SCRATCH}/zone1.wav`, rootPitch: 36, minPitch: 0, maxPitch: 59 },
    { path: `${SCRATCH}/zone3.wav`, rootPitch: 72, minPitch: 60, maxPitch: 84 },
  ];
  await cmd("track.setInstrument", { trackId, kind: "sampler", sampler: { zones: contiguous } });
  const negative = await cmd("debug.samplerEditor", {});
  ck("NEGATIVE CONTROL: contiguous map reports 0 gaps",
    negative.result?.gapCount === 0 && !/gap/i.test(negative.result?.headline ?? "gap"),
    `gapCount=${negative.result?.gapCount} headline=${negative.result?.headline}`);
  // Restore the gapped fixture for the capture.
  await cmd("track.setInstrument", { trackId, kind: "sampler", sampler: { zones } });
  r = await cmd("debug.samplerEditor", {});

  r = await cmd("debug.captureUI", { path: `${SCRATCH}/m26i-card.png` });
  ck("card CAPTURED to png", r.ok, r.error);

  // Select a zone -> the per-zone inspector must populate. The editor state
  // response carries no zone list, so ids come from the read-only wire verb
  // that does page zones.
  const desc = await cmd("instrument.describeSampler", { trackId, offset: 0, limit: 10 });
  ck("describeSampler returns zones", (desc.result?.zones?.length ?? 0) > 0,
    JSON.stringify(desc.result)?.slice(0, 300));
  const zoneId = desc.result?.zones?.[0]?.id;
  if (zoneId) {
    r = await cmd("debug.samplerEditor", { zoneId });
    ck("zone selects", r.ok, r.error);
    r = await cmd("debug.captureUI", { path: `${SCRATCH}/m26i-card-zone.png` });
    ck("zone inspector captured", r.ok, r.error);
  } else {
    console.log("  note: no zone id in state response; skipped selection capture");
  }

  r = await cmd("debug.samplerEditor", { close: true });
  ck("card closes", r.ok && r.result?.visible === false, JSON.stringify(r.result)?.slice(0, 200));

  console.log(`M26I_PROBE pass=${pass} fail=${fail}`);
} catch (e) {
  fail++;
  console.log(`FAIL exception :: ${e.stack}`);
} finally {
  try { ws?.close(); } catch { /* ignore */ }
  stopStaging(GATE); // SIGTERM by EXACT pid from the pidfile; never pkill
  console.log("staging stopped (pidfile-exact)");
}
process.exit(fail === 0 ? 0 : 1);
