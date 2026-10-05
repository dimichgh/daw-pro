// m34-u — VOICE MODE + GLIDE, IN PIXELS.
//
// m34-t shipped `voiceMode` (poly / mono / **legato**) and `glideTime` with no
// control anywhere: the only way to reach a slur was to ask an AI agent. This
// probe is the "a UI phase is not done until someone has LOOKED at it" half of
// closing that — it stages all four states the card can be in and captures each
// one, so a human (and the next agent) can COUNT chips and READ a warning
// rather than take a green unit test's word for pixels it cannot see.
//
// ⭐ THE STATE THAT MATTERS MOST IS THE INERT ONE. `glideTime` is structurally
// dead under `poly` — the engine resolves it away at the `ScalarParams`
// boundary — so a glide set on a chord-playing sampler does nothing at all.
// `instrument.describeSampler` already publishes `glideEffective` and warns;
// this asserts the CARD agrees with that verb, in both directions, and then
// photographs the disagreement-free state so the dimming can be seen.
//
// Port law: staging 17695 ONLY. 17600 is the user's app and is never a target.
import { readFileSync } from "node:fs";
import {
  launchStaging, stopStaging, STAGING_PORT, LIVE_PORT, assertStagingPort, ROOT,
} from "./_staging.mjs";

const GATE = "m34u-voice-glide";
const SCRATCH = process.env.M34U_SCRATCH
  || "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/81c0176f-63e9-4bcc-b292-849ad93b3062/scratchpad";
const SHOTS = `${SCRATCH}/m34u-shots`;

assertStagingPort(STAGING_PORT);
if (STAGING_PORT === LIVE_PORT) { console.log("FAIL port law"); process.exit(1); }

// ── ONE HOME for the copy: parsed out of the Swift source, never retyped. A
// probe that hardcodes the strings it is checking checks nothing.
const model = readFileSync(`${ROOT}/Sources/DAWAppKit/SamplerEditorModel.swift`, "utf8");
const labelOf = (kase) => {
  const m = model.match(new RegExp(`case \\.${kase}: return "([^"]+)"`));
  if (!m) throw new Error(`could not parse the ${kase} label out of SamplerEditorModel.swift`);
  return m[1];
};
const LABELS = { poly: labelOf("poly"), mono: labelOf("mono"), legato: labelOf("legato") };
console.log(`labels (parsed): ${JSON.stringify(LABELS)}`);

let pass = 0, fail = 0;
const ck = (name, ok, detail = "") => {
  if (ok) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name} :: ${String(detail).slice(0, 300)}`); }
};

let ws, id = 0;
const cmd = (command, params = {}) => new Promise((res, rej) => {
  const i = `m34u${++id}`;
  const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 25000);
  const h = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id !== i) return;
    clearTimeout(t); ws.removeEventListener("message", h); res(m);
  };
  ws.addEventListener("message", h);
  ws.send(JSON.stringify({ id: i, command, params }));
});

// Six contiguous zones — enough that the ZONES list is a real list and the card
// is in its ordinary shape, few enough that the globals stay near the top of
// every capture.
const library = () => Array.from({ length: 6 }, (_, i) => ({
  path: `${SCRATCH}/zone${(i % 3) + 1}.wav`,
  rootPitch: 48 + i, minPitch: 48 + i, maxPitch: 48 + i,
}));

let trackId;

// Stages one {voiceMode, glideTime} pair through the WIRE (never through a
// debug setter — `debug.samplerEditor` deliberately exposes none), then reads
// the card's own state back and captures it.
//
// ⚠️⚠️ THE VERB IS `track.setInstrument` WITH A PARTIAL `sampler` PAYLOAD, and
// that is worth saying out loud because the first draft of this probe sent
// `instrument.setSamplerParam`. There is NO SUCH WIRE COMMAND — 0 hits across
// every file in `Sources/DAWControl/`, against 3 for `"track.setInstrument"` in
// `Commands.swift` as the positive control. What exists is the **MCP tool**
// `instrument_set_sampler_param` (`mcp-server/src/server.ts:3773`), and it is a
// thin wrapper that sends this same verb — `bridge.send("track.setInstrument",
// { trackId, sampler: { [param]: value } })` at server.ts:3838. So an MCP tool
// NAME is not a wire verb, and reaching for one as if it were is how this
// probe's first run went wrong: every send was refused, every capture
// photographed the untouched default card, and 19 checks failed at once only
// because the state assertions happened to be tight. **The `ok` flag was not
// being read**, which is the wire's own version of pairing `2>/dev/null` with a
// command whose emptiness you intend to interpret. It is asserted on every send
// now. The upside of landing on `track.setInstrument` anyway: card, wire and
// MCP all funnel through ONE method, so they cannot drift.
//
// Globals fall back to the CURRENT value when a key is absent
// (Commands.swift ~11380), so omitting `zones` leaves the library alone — and
// `zoneCount` is checked after each send to prove that rather than assume it.
const sendOK = async (label, command, params) => {
  const r = await cmd(command, params);
  if (!r.ok) throw new Error(`${label}: ${command} REFUSED :: ${JSON.stringify(r.error)}`);
  return r;
};
const shoot = async (name, voiceMode, glideTime) => {
  await sendOK(name, "track.setInstrument", {
    trackId, kind: "sampler", sampler: { voiceMode, glideTime },
  });
  const st = await cmd("debug.samplerEditor", {});
  ck(`[${name}] the partial payload left the 6-zone library alone`,
    st.result?.zoneCount === 6, `zoneCount=${st.result?.zoneCount}`);
  const d = await cmd("instrument.describeSampler", { trackId });

  // (1) The card is showing the state we asked for — never assumed.
  ck(`[${name}] card reads voiceMode=${voiceMode}`,
    st.result?.voiceMode === voiceMode, JSON.stringify(st.result)?.slice(0, 200));
  ck(`[${name}] card reads glideTime=${glideTime}`,
    Math.abs((st.result?.glideTime ?? -1) - glideTime) < 1e-9, `got ${st.result?.glideTime}`);

  // (2) ⭐ THE CARD AND THE WIRE MUST NOT BE ABLE TO DISAGREE. The verb's
  // `glideEffective` is the derived conjunction an AI agent reads; the card's
  // dim-the-knob decision must be the SAME boolean, not a second derivation
  // that happens to match today.
  const wireEffective = glideTime > 0 ? d.result?.glideEffective : false;
  ck(`[${name}] card's glideEffective == describeSampler's (${wireEffective})`,
    st.result?.glideEffective === wireEffective,
    `card=${st.result?.glideEffective} wire=${d.result?.glideEffective}`);

  const shot = await cmd("debug.captureUI", { path: `${SHOTS}/${name}.png` });
  ck(`[${name}] CAPTURED`, shot.ok, shot.error);
  console.log(`    ${name}: voiceMode=${st.result?.voiceMode} glide=${st.result?.glideTime} `
    + `effective=${st.result?.glideEffective} inert=${st.result?.glideInert} `
    + `wireWarnings=${JSON.stringify(d.result?.warnings ?? [])}`);
  return st.result;
};

try {
  const s = await launchStaging({ gate: GATE, settleMs: 1200 });
  ws = s.ws;
  console.log(`staging pid=${s.pid} port=${STAGING_PORT}`);

  let r = await cmd("project.new", {});
  ck("project.new", r.ok, r.error);
  r = await cmd("track.add", { name: "Voice Probe", kind: "instrument" });
  trackId = r.result?.id ?? r.result?.track?.id ?? r.result?.trackId;
  ck("track id returned", !!trackId, JSON.stringify(r.result)?.slice(0, 200));

  r = await sendOK("setup", "track.setInstrument", {
    trackId, kind: "sampler", sampler: { zones: library() },
  });
  ck("sampler library set", r.ok, r.error);
  r = await cmd("debug.samplerEditor", { open: true, trackId });
  ck("sampler editor OPEN", r.result?.visible === true, JSON.stringify(r.result)?.slice(0, 200));

  // ── The four states, in the order a user meets them.
  //
  // (a) The DEFAULT: chords, no glide. Nothing is dimmed, nothing warns — a
  //     permanently-lit warning slot teaches nothing.
  const a = await shoot("01-chords-glide-off", "poly", 0);
  ck("[default] no warning state", a?.glideInert === false, JSON.stringify(a));

  // (b) ⛔ THE INERT ONE. A glide stored while the sampler plays chords does
  //     NOTHING, anywhere. The knob dims and the amber line says so.
  const b = await shoot("02-chords-glide-INERT", "poly", 0.25);
  ck("[inert] the card knows the glide is dead", b?.glideInert === true, JSON.stringify(b));
  const dInert = await cmd("instrument.describeSampler", { trackId });
  ck("[inert] the WIRE warns too (the precedent this UI follows)",
    (dInert.result?.warnings ?? []).some((w) => w.includes("GLIDE IS")),
    JSON.stringify(dInert.result?.warnings));

  // (c) ONE NOTE — monophonic with a fresh attack per note. Glide comes alive.
  const c = await shoot("03-one-note-glide-live", "mono", 0.25);
  ck("[one note] glide is live", c?.glideEffective === true && c?.glideInert === false,
    JSON.stringify(c));

  // (d) SLURRED — the mode the user actually chose by ear. Glide live.
  const d4 = await shoot("04-slurred-glide-live", "legato", 0.25);
  ck("[slurred] glide is live", d4?.glideEffective === true && d4?.glideInert === false,
    JSON.stringify(d4));

  // (e) A LONG glide, to prove the readout crosses to seconds and the arc moves
  //     — a knob whose readout never changes unit is a knob nobody can tell is
  //     working.
  const e = await shoot("05-slurred-glide-long", "legato", 2.5);
  ck("[long] glide is live at the top of the range", e?.glideEffective === true, JSON.stringify(e));

  // (f) ⭐ FALSIFIABILITY: switching BACK to chords must re-light the warning on
  //     a glide that was live one command ago. Without this leg the checks above
  //     would pass on a card that never re-evaluated anything.
  const f = await shoot("06-back-to-chords-INERT", "poly", 2.5);
  ck("[back to chords] the warning RETURNS (the state really is re-derived)",
    f?.glideInert === true && f?.glideEffective === false, JSON.stringify(f));

  // (g) And clearing the glide under chords must put the warning away again —
  //     the other direction, so "always warns" cannot pass.
  const g = await shoot("07-chords-glide-cleared", "poly", 0);
  ck("[cleared] the warning goes away", g?.glideInert === false, JSON.stringify(g));

  console.log(`M34U pass=${pass} fail=${fail}`);
  console.log(`shots in ${SHOTS}`);
} catch (e) {
  fail++;
  console.log(`FAIL exception :: ${e.stack}`);
} finally {
  try { ws?.close(); } catch { /* ignore */ }
  stopStaging(GATE); // SIGTERM by EXACT pid from the pidfile; never pkill
}
process.exit(fail === 0 ? 0 : 1);
