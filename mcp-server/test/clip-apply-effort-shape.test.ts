/**
 * clip-apply-effort-shape.test.ts — breath pad P1's `clip_apply_effort_shape`.
 *
 * Same stub-bridge pattern as controller-lane.test.ts: the REAL `McpServer`
 * from `src/server.ts` is driven over an in-memory transport with
 * `DawBridge.prototype.send` monkeypatched, so no live app is required.
 *
 * ⭐ THE TEST THIS FILE EXISTS FOR is the SILENT-STRIP round trip. The zod
 * objects in `server.ts` are closed (`registerTool` applies `.strict()`, and
 * there is no `.passthrough()` anywhere in the file), which means a key the
 * tool DESCRIPTION advertises but the SCHEMA omits is dropped by the SDK before
 * the handler runs — the tool then returns a perfectly successful result
 * computed from the default. That defect shipped in this repo earlier in this
 * round, on three parameters at once. So: every optional parameter is sent at
 * once with a distinguishable value, and the recorded bridge frame is asserted
 * to carry ALL of them. A schema that dropped one would still return success.
 */

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { DawBridge } from "../src/bridge.js";

interface RecordedCall {
  command: string;
  params: Record<string, unknown>;
}

let calls: RecordedCall[];
let queuedResult: unknown;
let queuedError: Error | undefined;

DawBridge.prototype.send = async function (
  command: string,
  params: Record<string, unknown> = {}
): Promise<unknown> {
  calls.push({ command, params });
  if (queuedError) {
    const err = queuedError;
    queuedError = undefined;
    throw err;
  }
  return queuedResult;
};

const { server } = await import("../src/server.js");

let client: Client;

before(async () => {
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  client = new Client({ name: "effort-shape-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
});

beforeEach(() => {
  calls = [];
  queuedResult = undefined;
  queuedError = undefined;
});

/**
 * The frame that ACTUALLY crosses the wire. The tool handlers here destructure
 * and rebuild an object literal, so an omitted optional arrives at
 * `bridge.send` as an explicit `undefined` key — which `JSON.stringify` then
 * drops. Asserting on the raw stub argument would be asserting on a JS detail
 * one layer above the thing under test; this is the JSON the app would receive.
 */
function wireFrame(call: RecordedCall): Record<string, unknown> {
  return JSON.parse(JSON.stringify(call.params));
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function parseJSON(result: any): any {
  const first = result.content[0];
  assert.ok(first && first.type === "text", `expected a text content item, got: ${JSON.stringify(result.content)}`);
  return JSON.parse(first.text as string);
}

// ---------------------------------------------------------------------------
// 1. The minimal call
// ---------------------------------------------------------------------------

test("clip_apply_effort_shape forwards clipId + pattern to clip.applyEffortShape", async () => {
  const clipId = randomUUID();
  const stubbed = {
    id: clipId,
    name: "Sax",
    patternId: "messaDiVoce",
    patternName: "Messa di voce",
    scope: "note",
    notesTouched: 3,
    phraseCount: 1,
    notesWithVibrato: 3,
    minEffort: 1,
    maxEffort: 1,
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_apply_effort_shape",
    arguments: { clipId, pattern: "messaDiVoce" },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "clip.applyEffortShape");
  assert.deepEqual(wireFrame(calls[0]!), { clipId, pattern: "messaDiVoce" });
  assert.deepEqual(parseJSON(result as any), stubbed, "the app's response round-trips verbatim");
});

// ---------------------------------------------------------------------------
// 2. ⭐ THE ANTI-STRIP ROUND TRIP
// ---------------------------------------------------------------------------

test("EVERY documented parameter survives the closed zod schema and reaches the wire", async () => {
  const clipId = randomUUID();
  const noteIds = [randomUUID(), randomUUID()];
  queuedResult = { id: clipId };

  // Distinguishable, in-range, and deliberately NOT the Swift defaults — a
  // parameter that were stripped would arrive as its default and be invisible
  // in a success response, which is exactly how the earlier defect hid.
  const sent = {
    clipId,
    pattern: "hairpinCrescendo",
    noteIds,
    amount: 0.75,
    maxGapBeats: 0.5,
    loudnessDepth: 0.4,
    swellDepth: 0.3,
    peakValue: 120,
    expressionCC: 2,
    attackSettleSeconds: 0.09,
    expressionSpacingSeconds: 0.03,
    vibratoOnsetSeconds: 0.4,
    vibratoRateHz: 6.25,
    vibratoDepthCents: 15,
    vibratoBloomSeconds: 0.9,
    vibratoReleaseSeconds: 0.11,
    sharpenCents: 7,
    bendSpacingSeconds: 0.01,
    bendRangeSemitones: 12,
  };

  await client.callTool({ name: "clip_apply_effort_shape", arguments: sent });

  assert.equal(calls.length, 1);
  assert.deepEqual(
    wireFrame(calls[0]!),
    sent,
    "a key the schema omits is SILENTLY STRIPPED by the SDK — this frame must carry all of them"
  );
  // Belt and braces: an explicit key-set comparison, so a failure names the
  // missing key rather than dumping two objects.
  assert.deepEqual(
    Object.keys(wireFrame(calls[0]!)).sort(),
    Object.keys(sent).sort(),
    "the wire frame's key set must equal the sent key set"
  );
});

// ---------------------------------------------------------------------------
// 2b. ⭐ THE SAME ROUND TRIP FOR THE RING (breath pad P2)
// ---------------------------------------------------------------------------

test("the P2 ring parameters survive the closed zod schema and reach the wire", async () => {
  const clipId = randomUUID();
  queuedResult = { id: clipId };

  // The RING form: no `pattern` at all (the app refuses both together), a dot
  // at a deliberately non-default angle and radius, and a custom ring order.
  // ⛔ THIS IS THE TEST THE P1 DEFECT WOULD HAVE REPRODUCED. `ringAngle`
  // missing from the schema means the app receives no angle, refuses with
  // "say which gesture", and an agent reading only the tool description would
  // have no way to see why — the description would be advertising a key the
  // SDK deletes on the way past.
  const sent = {
    clipId,
    ringAngle: 157.5,
    ringRadius: 0.8,
    ring: ["hairpinCrescendo", "hairpinDiminuendo", "messaDiVoce"],
    amount: 0.9,
  };

  await client.callTool({ name: "clip_apply_effort_shape", arguments: sent });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.applyEffortShape");
  assert.deepEqual(
    wireFrame(calls[0]!),
    sent,
    "a key the schema omits is SILENTLY STRIPPED by the SDK — this frame must carry all three"
  );
  // Named individually so a failure says WHICH one vanished, and with the
  // VALUE checked as well: a key that survived as `undefined` would still pass
  // a bare `in` test after JSON round-tripping drops it.
  const frame = wireFrame(calls[0]!);
  assert.equal(frame.ringAngle, 157.5, "ringAngle was stripped or altered");
  assert.equal(frame.ringRadius, 0.8, "ringRadius was stripped or altered");
  assert.deepEqual(
    frame.ring,
    ["hairpinCrescendo", "hairpinDiminuendo", "messaDiVoce"],
    "ring was stripped or altered"
  );
  assert.ok(!("pattern" in frame), "the ring form must not invent a pattern");
});

// ---------------------------------------------------------------------------
// 2c. ⭐ THE SAME ROUND TRIP FOR THE DOT PATH (breath pad P3)
// ---------------------------------------------------------------------------

test("the P3 path parameters survive the closed zod schema and reach the wire", async () => {
  const clipId = randomUUID();
  queuedResult = { id: clipId };

  // Every P3 key at once, all deliberately NOT their Swift defaults. A stripped
  // key arrives at the app as its default: `pathSeed` would silently become 0
  // and the user would get a DIFFERENT wander back with a success response and
  // nothing to read that says so.
  const sent = {
    clipId,
    ringAngle: 157.5,
    path: "drift",
    pathSeed: 4294967295,
    scaleBeats: 12.5,
    octaves: 6,
    momentum: 0.8,
    angleSwing: 90,
    radiusSwing: 0.35,
  };

  await client.callTool({ name: "clip_apply_effort_shape", arguments: sent });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.applyEffortShape");
  assert.deepEqual(
    wireFrame(calls[0]!),
    sent,
    "a key the schema omits is SILENTLY STRIPPED by the SDK — this frame must carry all eight"
  );
  const frame = wireFrame(calls[0]!);
  assert.deepEqual(
    Object.keys(frame).sort(),
    Object.keys(sent).sort(),
    "the wire frame's key set must equal the sent key set"
  );
  // Per-key VALUE checks, because a key that survived as `undefined` would pass
  // a bare `in` test after the JSON round trip drops it.
  assert.equal(frame.path, "drift", "path was stripped or altered");
  assert.equal(frame.pathSeed, 4294967295, "pathSeed was stripped or altered");
  assert.equal(frame.scaleBeats, 12.5, "scaleBeats was stripped or altered");
  assert.equal(frame.octaves, 6, "octaves was stripped or altered");
  assert.equal(frame.momentum, 0.8, "momentum was stripped or altered");
  assert.equal(frame.angleSwing, 90, "angleSwing was stripped or altered");
  assert.equal(frame.radiusSwing, 0.35, "radiusSwing was stripped or altered");

  // ⭐ THE SEED IS THE ONE THAT MUST SURVIVE EXACTLY, and 2^32−1 is the number
  // that proves it: it is the documented cap, and a value that had been through
  // any float32 or int32 narrowing would come back as something else.
  assert.strictEqual(frame.pathSeed, 4294967295);

  // The orbit half, separately — its two keys are refused on a drift, so they
  // cannot be in the frame above and would otherwise never be round-tripped.
  calls = [];
  queuedResult = { id: clipId };
  const orbit = {
    clipId,
    ringAngle: 0,
    path: "orbit",
    revolutionBeats: 24.5,
    pathDirection: "counterclockwise",
  };
  await client.callTool({ name: "clip_apply_effort_shape", arguments: orbit });
  assert.equal(calls.length, 1);
  assert.deepEqual(wireFrame(calls[0]!), orbit, "the orbit keys must reach the wire too");
});

test("out-of-range P3 path values are rejected client-side, with a positive control", async () => {
  const clipId = randomUUID();

  for (const bad of [
    { path: "wander" }, // not one of the three
    { pathSeed: -1 },
    { pathSeed: 4294967296 }, // one past the documented 32-bit cap
    { pathSeed: 1.5 }, // must be an integer
    { revolutionBeats: 0.1 },
    { pathDirection: "widdershins" },
    { scaleBeats: 0 },
    { octaves: 0 },
    { octaves: 9 },
    { momentum: 1.5 },
    { angleSwing: 361 },
    { radiusSwing: -0.1 },
  ]) {
    const result = await client.callTool({
      name: "clip_apply_effort_shape",
      arguments: { clipId, ringAngle: 0, ...bad },
    });
    assert.equal(
      (result as { isError?: boolean }).isError,
      true,
      `expected ${JSON.stringify(bad)} to be refused by the schema`
    );
  }
  assert.equal(calls.length, 0, "none of them should have reached the app");

  // POSITIVE CONTROL: the boundary values are LEGAL, or the twelve refusals
  // above would prove only that the tool rejects everything with a path in it.
  queuedResult = { id: clipId };
  await client.callTool({
    name: "clip_apply_effort_shape",
    arguments: {
      clipId,
      ringAngle: 0,
      path: "drift",
      pathSeed: 4294967295,
      scaleBeats: 0.25,
      octaves: 8,
      momentum: 0,
      angleSwing: 0,
      radiusSwing: 1,
    },
  });
  assert.equal(calls.length, 1, "the boundary values are legal and must go through");
});

test("the path is DISCOVERABLE: the schema teaches reproducibility and the once-per-note limit", async () => {
  const tools = await client.listTools();
  const tool = tools.tools.find((t) => t.name === "clip_apply_effort_shape");
  assert.ok(tool, "the tool must be listed");
  const whole = JSON.stringify(tool);

  // The three things an agent cannot work out from the parameter names, and
  // which decide whether it uses the feature correctly.
  assert.ok(/ONCE PER NOTE/i.test(whole), "must say the dot is sampled once per note");
  assert.ok(
    /reproducib/i.test(whole) && /bounce/i.test(whole),
    "must say the wander is reproducible in a bounce, not merely 'random'"
  );
  assert.ok(
    /REFUSED|refused/.test(whole),
    "must say that a parameter belonging to another path is refused rather than ignored"
  );
  // And the response fields that answer "did it actually do anything?".
  assert.ok(/outrunsNotes/.test(whole), "must name outrunsNotes");
  assert.ok(/patternIds/.test(whole), "must name patternIds");
});

test("out-of-range ring values are rejected client-side, with a positive control", async () => {
  const clipId = randomUUID();

  for (const bad of [{ ringAngle: 361 }, { ringAngle: -1 }, { ringRadius: 1.5 }, { ring: [1, 2] }]) {
    const result = await client.callTool({
      name: "clip_apply_effort_shape",
      arguments: { clipId, ringAngle: 0, ...bad },
    });
    assert.equal(
      (result as { isError?: boolean }).isError,
      true,
      `expected ${JSON.stringify(bad)} to be refused by the schema`
    );
  }
  assert.equal(calls.length, 0, "none of them should have reached the app");

  // POSITIVE CONTROL: the same shape with IN-range values must go through, or
  // the four refusals above would prove only that the tool rejects everything.
  queuedResult = { id: clipId };
  await client.callTool({
    name: "clip_apply_effort_shape",
    arguments: { clipId, ringAngle: 360, ringRadius: 0, ring: ["flat"] },
  });
  assert.equal(calls.length, 1, "the boundary values 360 and 0 are LEGAL");
});

// ---------------------------------------------------------------------------
// 3. Optional params are ABSENT, not null, when omitted
// ---------------------------------------------------------------------------

test("omitted optionals do not appear in the wire frame at all", async () => {
  const clipId = randomUUID();
  queuedResult = { id: clipId };

  await client.callTool({
    name: "clip_apply_effort_shape",
    arguments: { clipId, pattern: "terraced", amount: 0.5 },
  });

  const params = wireFrame(calls[0]!);
  assert.deepEqual(Object.keys(params).sort(), ["amount", "clipId", "pattern"]);
  assert.ok(!("noteIds" in params), "an omitted array must not arrive as null");
  assert.ok(!("vibratoDepthCents" in params));
});

// ---------------------------------------------------------------------------
// 4. Client-side rejections — ZERO bridge calls
// ---------------------------------------------------------------------------

test("an unknown pattern is rejected at the MCP schema layer with no bridge call", async () => {
  const result = await client.callTool({
    name: "clip_apply_effort_shape",
    arguments: { clipId: randomUUID(), pattern: "airRunsOut" },
  });
  assert.equal((result as { isError?: boolean }).isError, true);
  assert.equal(calls.length, 0, "a schema-invalid call must never reach the app");
});

test("an out-of-range amount and an unknown key are rejected client-side", async () => {
  const clipId = randomUUID();

  const outOfRange = await client.callTool({
    name: "clip_apply_effort_shape",
    arguments: { clipId, pattern: "flat", amount: 1.5 },
  });
  assert.equal((outOfRange as { isError?: boolean }).isError, true);

  // `.strict()` is what turns a typo into an error instead of a silent default.
  const typo = await client.callTool({
    name: "clip_apply_effort_shape",
    arguments: { clipId, pattern: "flat", ammount: 0.5 },
  });
  assert.equal((typo as { isError?: boolean }).isError, true);

  assert.equal(calls.length, 0, "neither should have reached the app");
});

/**
 * ⚠️ CONTRACT CHANGE AT P2, RECORDED RATHER THAN QUIETLY DROPPED.
 *
 * Until P2, `pattern` was a REQUIRED `z.enum`, so `{clipId}` alone was refused
 * by the schema with zero bridge calls, and this file asserted exactly that.
 * `pattern` had to become optional for the ring form to exist, and zod's
 * `inputSchema` here is a raw SHAPE (see `registerTool`, which wraps it in
 * `z.object(...).strict()`), so there is no place to hang a `.refine()` that
 * could express "exactly one of pattern / ringAngle".
 *
 * The check therefore MOVED to the app, which refuses it with a sentence that
 * names both forms. That is a better place for it — one rule, in the language
 * the app speaks — but it means a call with neither now REACHES the bridge,
 * and this test pins the new behaviour so the move is visible rather than
 * looking like a lost assertion.
 */
test("a call with NEITHER pattern nor ringAngle now reaches the app, which refuses it by name", async () => {
  queuedError = new Error(
    "say which gesture: either 'pattern' (one of flat, messaDiVoce, …) or 'ringAngle' " +
      "(degrees, 0-360 — a dot on the ring, blending the two patterns it sits between)"
  );
  const result = await client.callTool({
    name: "clip_apply_effort_shape",
    arguments: { clipId: randomUUID() },
  });
  assert.equal(calls.length, 1, "the schema no longer stops this — the app does");
  assert.equal((result as { isError?: boolean }).isError, true);
  const text = JSON.stringify((result as { content: unknown }).content);
  assert.ok(text.includes("ringAngle"), `the refusal must name the ring form, got: ${text}`);
  assert.ok(text.includes("pattern"), `the refusal must name the pattern form, got: ${text}`);
});

// ---------------------------------------------------------------------------
// 5. App-side errors surface verbatim
// ---------------------------------------------------------------------------

test("an app-side refusal surfaces as a tool error carrying the app's own sentence", async () => {
  queuedError = new Error(
    "clip 'Drums' is not a MIDI clip — clip.applyEffortShape shapes MIDI notes"
  );
  const result = await client.callTool({
    name: "clip_apply_effort_shape",
    arguments: { clipId: randomUUID(), pattern: "flat" },
  });
  assert.equal((result as { isError?: boolean }).isError, true);
  const text = JSON.stringify((result as { content: unknown }).content);
  assert.ok(text.includes("not a MIDI clip"), `expected the app's message verbatim, got: ${text}`);
});

// ---------------------------------------------------------------------------
// 6. The description must not promise what the measurements forbid
// ---------------------------------------------------------------------------

test("the tool description names the measured sound-bank limits and the CC1 route", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "clip_apply_effort_shape");
  assert.ok(tool, "clip_apply_effort_shape must be registered");
  const description = tool!.description ?? "";

  // It must NAME the two measured limits rather than leaving an agent to
  // discover them from a warning after the fact.
  assert.ok(/LOUDNESS ONLY/i.test(description), "must state that the sound-bank path is loudness only");
  assert.ok(/CC 1/.test(description), "must name the CC 1 route that actually works");
  assert.ok(/5\.4 Hz/.test(description), "must carry the measured DLS vibrato rate");
  // The bend-range figure lives on the `bendRangeSemitones` PARAMETER
  // description, which an agent reads from the schema, so search the whole
  // registration rather than the headline alone.
  assert.ok(
    /2\.0155/.test(JSON.stringify(tool)),
    "must carry the measured AUSampler bend range somewhere an agent reads"
  );

  // ⛔ BANNED PHRASES. The measurement says CC 11 on a hosted AUSampler is
  // exactly a gain, so nothing here may sell brightness on that path. This is
  // the `legatoDescriptionsNeverPromiseWhatTheEngineCannotDo` idiom.
  const bright = description.match(/bright\w*/gi) ?? [];
  for (const hit of bright) {
    const at = description.indexOf(hit);
    const window = description.slice(Math.max(0, at - 120), at + 120);
    assert.ok(
      /never|only|not|Sampler capability/i.test(window),
      `"${hit}" appears without a limiting clause near it: …${window}…`
    );
  }
  // POSITIVE CONTROL for the scan above: the description really does mention
  // brightness (in the negative), so an empty match set would mean the regex
  // is broken rather than the text being clean.
  assert.ok(bright.length > 0, "expected the description to discuss brightness at all");
});

test("the ring is DISCOVERABLE: the schema teaches the angle of every pattern", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "clip_apply_effort_shape");
  const whole = JSON.stringify(tool);

  // An agent cannot use an angle it has to guess. Every default pattern's own
  // angle must be written down somewhere the schema carries.
  for (const [degrees, id] of [
    [0, "flat"],
    [45, "messaDiVoce"],
    [90, "lateBloom"],
    [135, "hairpinCrescendo"],
    [180, "hairpinDiminuendo"],
    [225, "terraced"],
    [270, "sforzandoPiano"],
    [315, "subToneEntry"],
  ] as [number, string][]) {
    assert.ok(
      new RegExp(`${degrees}\\s*=\\s*${id}`).test(whole),
      `the schema must say that ${degrees}° is ${id}`
    );
  }
  // And it must say that the two forms are exclusive, since that is the one
  // rule the schema itself cannot enforce.
  assert.ok(/EITHER/.test(whole), "must state that pattern and ringAngle are exclusive");
  // ⛔ The blend law must not be sold as something it is not: nearest-TWO, so
  // a distant pattern contributes nothing.
  assert.ok(/nearest-two/i.test(whole), "must say the blend is nearest-two");
});

// ---------------------------------------------------------------------------
// 2d. ⭐ THE SAME ROUND TRIP FOR THE AIR BUDGET (breath pad P4)
// ---------------------------------------------------------------------------

test("the P4 air parameters survive the closed zod schema and reach the wire", async () => {
  const clipId = randomUUID();
  queuedResult = { id: clipId };

  // Every air key at once, all deliberately NOT their Swift defaults. A stripped
  // key arrives at the app as its default — and for THIS feature that is the
  // worst possible failure shape: `airEnforced` dropped means the tool reports
  // success, the composer believes the budget is on, and nothing was ever
  // constrained. The response would look completely correct.
  const sent = {
    clipId,
    pattern: "hairpinDiminuendo",
    airEnforced: true,
    airCapacitySeconds: 11.5,
    airConsumptionExponent: 2.25,
    airRefillSecondsPerSecond: 1.75,
    airMinBreathSeconds: 0.4,
    airReserveFraction: 0.4,
  };

  await client.callTool({ name: "clip_apply_effort_shape", arguments: sent });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.applyEffortShape");
  assert.deepEqual(
    wireFrame(calls[0]!),
    sent,
    "a key the schema omits is SILENTLY STRIPPED by the SDK — this frame must carry all six"
  );
  const frame = wireFrame(calls[0]!);
  assert.deepEqual(
    Object.keys(frame).sort(),
    Object.keys(sent).sort(),
    "the wire frame's key set must equal the sent key set"
  );
  // Per-key VALUE checks: a key that survived as `undefined` would pass a bare
  // `in` test after the JSON round trip drops it.
  assert.strictEqual(frame.airEnforced, true, "airEnforced was stripped or altered");
  assert.equal(frame.airCapacitySeconds, 11.5, "airCapacitySeconds was stripped or altered");
  assert.equal(frame.airConsumptionExponent, 2.25, "airConsumptionExponent was stripped or altered");
  assert.equal(frame.airRefillSecondsPerSecond, 1.75, "airRefillSecondsPerSecond was stripped or altered");
  assert.equal(frame.airMinBreathSeconds, 0.4, "airMinBreathSeconds was stripped or altered");
  assert.equal(frame.airReserveFraction, 0.4, "airReserveFraction was stripped or altered");

  // ⭐ `airEnforced: false` must reach the wire too. `false` is the DEFAULT, so
  // a schema or handler that treated it as "absent" would be invisible here —
  // and the app distinguishes "the caller asked, with it off" (which earns an
  // advisory saying what the budget WOULD have done) from "the caller never
  // mentioned air" (which does not).
  calls = [];
  queuedResult = { id: clipId };
  await client.callTool({
    name: "clip_apply_effort_shape",
    arguments: { clipId, pattern: "flat", airEnforced: false },
  });
  assert.equal(calls.length, 1);
  assert.deepEqual(wireFrame(calls[0]!), { clipId, pattern: "flat", airEnforced: false });
  assert.strictEqual(wireFrame(calls[0]!).airEnforced, false, "an explicit false was dropped");
});

test("out-of-range P4 air values are rejected client-side, with a positive control", async () => {
  const clipId = randomUUID();

  for (const bad of [
    { airEnforced: "yes" }, // not a boolean
    { airCapacitySeconds: 0 },
    { airCapacitySeconds: 3601 },
    { airConsumptionExponent: -1 },
    { airConsumptionExponent: 9 },
    { airRefillSecondsPerSecond: -0.5 },
    { airMinBreathSeconds: 61 },
    { airReserveFraction: 1.5 },
    { airReserveFraction: -0.1 },
    // ⛔ §9.1 names `referenceEffort` and P4 deliberately does NOT ship it: it
    // is algebraically the same axis as `airCapacitySeconds`. `registerTool`
    // wraps the shape in `.strict()`, so an agent that read the design and tried
    // it is REFUSED rather than having it silently ignored.
    { referenceEffort: 0.6 },
    { air: { enforced: true } }, // the design's nested spelling is not the wire's
  ]) {
    calls = [];
    const result = (await client.callTool({
      name: "clip_apply_effort_shape",
      arguments: { clipId, pattern: "flat", ...bad },
    })) as { isError?: boolean };
    assert.ok(result.isError, `${JSON.stringify(bad)} should be refused client-side`);
    assert.equal(calls.length, 0, `${JSON.stringify(bad)} reached the bridge`);
  }

  // POSITIVE CONTROL: the boundary values themselves are accepted, so every
  // refusal above is about the VALUE and not about the key being unknown.
  calls = [];
  queuedResult = { id: clipId };
  const ok = (await client.callTool({
    name: "clip_apply_effort_shape",
    arguments: {
      clipId,
      pattern: "flat",
      airEnforced: true,
      airCapacitySeconds: 0.25,
      airConsumptionExponent: 0,
      airRefillSecondsPerSecond: 0,
      airMinBreathSeconds: 0,
      airReserveFraction: 1,
    },
  })) as { isError?: boolean };
  assert.ok(!ok.isError, "the documented boundaries must be accepted");
  assert.equal(calls.length, 1, "the boundary call must reach the bridge");
});

test("the air budget is DISCOVERABLE: the schema says it is off, why, and how to read the report", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "clip_apply_effort_shape");
  const whole = JSON.stringify(tool);

  // ⛔ The user ruling has to be visible to an agent, not just true in the code:
  // an agent that assumes the budget is on will mis-explain a part it did not
  // change.
  assert.ok(/[Dd]efault(s)? FALSE|DEFAULTS? TO FALSE/.test(whole),
    "the schema must say airEnforced defaults to false");
  assert.ok(/overrid/i.test(whole), "must say WHY it is off by default — it overrides what you wrote");

  // The legibility surface has to be findable, or the report is a file nobody
  // opens.
  assert.ok(/effortRequested/.test(whole), "must name effortRequested");
  assert.ok(/effortAllowed/.test(whole), "must name effortAllowed");
  assert.ok(/air\.applied|`air`/.test(whole), "must tell the agent to read the air block");

  // ⛔ The one-symptom-one-cause rule, stated where the agent picking a pattern
  // will see it.
  assert.ok(/air runs out/i.test(whole),
    "must say that 'air runs out' is deliberately not a selectable pattern");

  // POSITIVE CONTROL for the scans above: a phrase that is NOT in the tool must
  // come back absent, or `test()` is matching something structural.
  //
  // ⚠️ `referenceEffort` was the first sentinel here and the control FIRED —
  // correctly. The word IS in the tool, inside `airCapacitySeconds`'s
  // description, which explains why §9.1's `referenceEffort` is deliberately not
  // a parameter. That sentence is worth keeping (an agent that read the design
  // will look for the key), so the sentinel moved to a phrase nothing has any
  // reason to contain.
  assert.ok(!/airHumidity/.test(whole),
    "the probe matched a parameter that does not exist — it is not reading the tool");
  // ...and the referenceEffort explanation is itself pinned, since it is now
  // load-bearing for an agent following the design document.
  assert.ok(/referenceEffort/.test(whole),
    "the schema no longer explains why §9.1's referenceEffort is absent");
});

// ---------------------------------------------------------------------------
// 2e. ⭐ THE SAME ROUND TRIP FOR PHYSIOLOGICAL HUMANISATION (breath pad P5)
// ---------------------------------------------------------------------------

test("the P5 humanisation parameters survive the closed zod schema and reach the wire", async () => {
  const clipId = randomUUID();
  queuedResult = { id: clipId };

  // Every P5 key at once, all deliberately NOT their Swift defaults — and for
  // THIS feature the defaults are all ZERO, which is the worst possible shape
  // for a silent strip: a dropped `tremorDepth` arrives as 0, the tool reports
  // success, and the render is byte-identical to not asking. There is nothing
  // in a successful response that would tell you.
  const sent = {
    clipId,
    pattern: "messaDiVoce",
    driftDepth: 0.07,
    driftScaleBeats: 12.5,
    driftOctaves: 6,
    tremorDepth: 0.045,
    tremorRateHz: 5.25,
    tremorEffortExponent: 1.75,
  };

  await client.callTool({ name: "clip_apply_effort_shape", arguments: sent });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.applyEffortShape");
  assert.deepEqual(
    wireFrame(calls[0]!),
    sent,
    "a key the schema omits is SILENTLY STRIPPED by the SDK — this frame must carry all six"
  );
  const frame = wireFrame(calls[0]!);
  assert.deepEqual(
    Object.keys(frame).sort(),
    Object.keys(sent).sort(),
    "the wire frame's key set must equal the sent key set"
  );
  // Per-key VALUE checks: a key that survived as `undefined` would pass a bare
  // `in` test after the JSON round trip drops it.
  assert.equal(frame.driftDepth, 0.07, "driftDepth was stripped or altered");
  assert.equal(frame.driftScaleBeats, 12.5, "driftScaleBeats was stripped or altered");
  assert.equal(frame.driftOctaves, 6, "driftOctaves was stripped or altered");
  assert.equal(frame.tremorDepth, 0.045, "tremorDepth was stripped or altered");
  assert.equal(frame.tremorRateHz, 5.25, "tremorRateHz was stripped or altered");
  assert.equal(frame.tremorEffortExponent, 1.75, "tremorEffortExponent was stripped or altered");

  // ⭐ An explicit ZERO must reach the wire too. Zero IS the default, so a
  // schema or handler that treated it as "absent" would be invisible in every
  // assertion above — and a caller who explicitly switches the tremor off is
  // saying something different from one who never mentioned it.
  calls = [];
  queuedResult = { id: clipId };
  await client.callTool({
    name: "clip_apply_effort_shape",
    arguments: { clipId, pattern: "flat", tremorDepth: 0, driftDepth: 0 },
  });
  assert.equal(calls.length, 1);
  assert.deepEqual(wireFrame(calls[0]!), {
    clipId,
    pattern: "flat",
    tremorDepth: 0,
    driftDepth: 0,
  });
  assert.strictEqual(wireFrame(calls[0]!).tremorDepth, 0, "an explicit 0 was dropped");
});

test("out-of-range P5 humanisation values are rejected client-side, with a positive control", async () => {
  const clipId = randomUUID();

  for (const bad of [
    { driftDepth: -0.1 },
    { driftDepth: 1.1 },
    { driftScaleBeats: 0 },
    { driftScaleBeats: 5000 },
    { driftOctaves: 0 },
    { driftOctaves: 9 },
    { driftOctaves: 2.5 }, // must be an integer
    { tremorDepth: -0.01 },
    { tremorDepth: 1.5 },
    // ⛔ The tremor band is 0.2-20 Hz on ALL FOUR surfaces (zod, catalog,
    // Commands.swift, and BOTH Swift sanitizers). It was briefly 0.01-40 on the
    // wire while `BreathContour.Options` clamped to 0.2-20, which meant a
    // wire-legal 25 Hz advanced each note's PHASE at 25 Hz while the generator
    // oscillated at 20 Hz — a growing discontinuity at every onset, reported by
    // nothing. These four values are the corners of that gap.
    { tremorRateHz: 0 },
    { tremorRateHz: 0.05 },
    { tremorRateHz: 0.19 },
    { tremorRateHz: 25 },
    { tremorRateHz: 41 },
    { tremorEffortExponent: -1 },
    { tremorEffortExponent: 9 },
    // ⛔ §10.1's own spelling of the depth axis is NOT a wire key: the design
    // defines `tremorDepth` as a fraction of "effort travel", which measures
    // 0.16 dB (inaudible), so the build re-based it on the contour level and
    // did not ship a second, differently-scaled name for the same axis.
    { tremorTravelDepth: 0.03 },
    { humanisation: { tremorDepth: 0.03 } }, // no nested spelling either
  ]) {
    calls = [];
    const result = (await client.callTool({
      name: "clip_apply_effort_shape",
      arguments: { clipId, pattern: "flat", ...bad },
    })) as { isError?: boolean };
    assert.ok(result.isError, `${JSON.stringify(bad)} should be refused client-side`);
    assert.equal(calls.length, 0, `${JSON.stringify(bad)} reached the bridge`);
  }

  // POSITIVE CONTROL: the documented boundaries are accepted, so every refusal
  // above is about the VALUE and not about the key being unknown.
  calls = [];
  queuedResult = { id: clipId };
  const ok = (await client.callTool({
    name: "clip_apply_effort_shape",
    arguments: {
      clipId,
      pattern: "flat",
      driftDepth: 1,
      driftScaleBeats: 0.01,
      driftOctaves: 8,
      tremorDepth: 1,
      tremorRateHz: 20,
      tremorEffortExponent: 8,
    },
  })) as { isError?: boolean };
  assert.ok(!ok.isError, "the documented boundaries must be accepted");
  assert.equal(calls.length, 1, "the boundary call must reach the bridge");

  // ...and the BOTTOM of the tremor band too, so the four refusals above are
  // about being outside 0.2-20 and not about the low end being closed.
  calls = [];
  queuedResult = { id: clipId };
  const okLow = (await client.callTool({
    name: "clip_apply_effort_shape",
    arguments: { clipId, pattern: "flat", tremorDepth: 0.03, tremorRateHz: 0.2 },
  })) as { isError?: boolean };
  assert.ok(!okLow.isError, "0.2 Hz is the bottom of the band and must be accepted");
  assert.equal(calls.length, 1, "the low-boundary call must reach the bridge");
});

test("P5 is DISCOVERABLE: the schema says the defaults are null and names the measured tremor ceiling", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "clip_apply_effort_shape");
  const whole = JSON.stringify(tool);

  // ⛔ The null-default property is the one that makes each knob declinable
  // after the fact. An agent that does not know it is the default will not
  // realise that omitting the key reproduces the previous render exactly.
  assert.ok(
    /byte-identical/i.test(whole),
    "the schema must say that the humanisation defaults render byte-identically"
  );

  // ⛔ The measured ceiling, and the fact that the tremor is SUPPRESSED rather
  // than written-and-aliased. An agent that asks for a tremor on the GM sax and
  // is told nothing would conclude the feature is broken.
  assert.ok(/11\.719/.test(whole), "must carry the measured hosted-AU sampling rate");
  assert.ok(
    /4096/.test(whole),
    "must name OUR 4096-frame offline block as the cause, not the plugin"
  );
  assert.ok(
    /2\.14x|2\.14 ?x/i.test(whole),
    "must carry the measured 8 Hz image ratio rather than only asserting a limit exists"
  );

  // ⛔ BANNED: nothing may promise a tremor on a sound-bank track. This is the
  // `legatoDescriptionsNeverPromiseWhatTheEngineCannotDo` idiom.
  const tremorMentions = whole.match(/tremor/gi) ?? [];
  assert.ok(tremorMentions.length > 5, "positive control: the tool does discuss tremor");
  assert.ok(
    /NOT WRITTEN|not written|SUPPRESSED|suppressed/.test(whole),
    "must state that the tremor is not written on a hosted-AU track"
  );

  // POSITIVE CONTROL for the scans above: a phrase nothing has any reason to
  // contain must come back absent, or `test()` is matching something structural.
  assert.ok(
    !/tremorHumidity/.test(whole),
    "the probe matched a parameter that does not exist — it is not reading the tool"
  );
});
