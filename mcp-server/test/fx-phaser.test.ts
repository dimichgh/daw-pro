/**
 * fx-phaser.test.ts — the m39-o phaser's MCP surface.
 *
 * NO NEW TOOL ships with m39-o, and that is a contract rather than an omission
 * (creative-effects design rule 6.0.11): a new effect KIND rides the existing
 * fx_add / fx_set_param / fx_describe / automation_add_lane surface, so the
 * wire command count and the MCP tool count must both be UNCHANGED by this
 * item. What CAN silently go missing when a kind is added to shared schemas and
 * shared prose is what this file pins:
 *
 *   1. `phaser` is accepted by `fxKindSchema` and forwarded VERBATIM. A kind
 *      missing from the enum is rejected at the MCP boundary with a schema
 *      error and never reaches the app — which reads to an agent as "the DAW
 *      does not have one".
 *   2. Its seven params forward verbatim through `fx_add`'s `params` and
 *      `fx_set_param`, including a NEGATIVE `feedback` (any `Math.abs`,
 *      `Math.max(0, …)` or unsigned assumption on the path would silently
 *      delete half the effect) and an ODD `stages` (which the APP snaps, so
 *      the MCP layer must pass it through untouched rather than "helping").
 *   3. ⭐⭐ THE DESCRIPTION CARRIES THE ONE THING AN AGENT CANNOT INFER AND
 *      WILL OTHERWISE GET WRONG: that a phaser is NOT a flanger. Both sweep,
 *      both "whoosh", the words are used interchangeably, and nothing in the
 *      parameter names tells an agent which to reach for. This is the same
 *      hazard fx-flanger.test.ts pins between `flanger` and `chorus`, one kind
 *      further along.
 *   4. ⭐ THE THREE HONEST WARNINGS: that `mix: 1` at `feedback: 0` is very
 *      nearly INAUDIBLE (an all-pass chain alone changes no frequency's
 *      level), that `centerHz` is NOT itself a notch frequency, and that
 *      `stages` SNAPS to even. Each one is a bug report waiting to happen.
 *   5. ⚠️ THE DERIVED-FIELD DISTINCTION, BOTH HALVES. `notchCount` and
 *      `firstNotchHz` are PER-INSTANCE echoes in fx_add / fx_set_param
 *      RESULTS and in project_snapshot — they are NOT in fx_describe, which
 *      returns static schema and no values at all. An agent that calls
 *      fx_describe looking for them finds nothing and concludes they do not
 *      exist.
 *
 * The stub-bridge pattern is fx-flanger.test.ts's, verbatim.
 */

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { DawBridge } from "../src/bridge.js";

interface RecordedCall {
  command: string;
  params: Record<string, unknown>;
}

let calls: RecordedCall[];
let queuedResult: unknown;

DawBridge.prototype.send = async function (
  command: string,
  params: Record<string, unknown> = {}
): Promise<unknown> {
  calls.push({ command, params });
  return queuedResult;
};

const { server } = await import("../src/server.js");

let client: Client;

before(async () => {
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  client = new Client({ name: "fx-phaser-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
});

beforeEach(() => {
  calls = [];
  queuedResult = { effectId: "ph-1", effects: [] };
});

/**
 * The description of ONE INPUT PARAMETER, as the MCP client receives it.
 * ⚠️ The per-kind teaching does NOT live in `fx_add`'s tool description — it
 * lives in `fxKindSchema`'s `.describe()`, which lands on
 * `inputSchema.properties.kind` (the finding fx-bit-crusher.test.ts records).
 */
async function describeParam(tool: string, param: string): Promise<string> {
  const { tools } = await client.listTools();
  const found = tools.find((t) => t.name === tool);
  assert.ok(found, `${tool} must be registered`);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const properties = (found.inputSchema as any).properties ?? {};
  assert.ok(properties[param], `${tool}.${param} must be in the input schema`);
  return JSON.stringify(properties[param]);
}

async function describeTool(name: string): Promise<string> {
  const { tools } = await client.listTools();
  const tool = tools.find((t) => t.name === name);
  assert.ok(tool, `${name} must be registered`);
  return tool.description ?? "";
}

test("fx_add accepts kind phaser and forwards it verbatim", async () => {
  await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "phaser" },
  });
  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "fx.add");
  assert.equal(calls[0]!.params.kind, "phaser");
  assert.equal(calls[0]!.params.trackId, "track-1");
});

test("fx_add forwards every phaser param, a NEGATIVE feedback and an ODD stages included", async () => {
  // ⭐ Two values here are the point. `feedback: -0.66` is negative on purpose
  // — the negative half is a distinct sound, not a degenerate case, and any
  // unsigned assumption on the path would delete it and report success.
  // `stages: 7` is ODD on purpose: the APP snaps it to 8, and the MCP layer's
  // job is to forward the 7 UNTOUCHED so the snap happens in exactly one
  // place. A helpful client-side round here would be a second home for a law.
  const params = {
    rateHz: 2.75,
    centerHz: 640,
    depthOctaves: 1.75,
    stages: 7,
    feedback: -0.66,
    mix: 0.83,
    stereoPhaseDeg: 137,
  };
  await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "phaser", params },
  });
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params.params, params);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.equal((calls[0]!.params.params as any).stages, 7, "the odd value is NOT rounded here");
});

test("fx_set_param forwards a negative phaser feedback unmodified", async () => {
  await client.callTool({
    name: "fx_set_param",
    arguments: { trackId: "track-1", effectId: "ph-1", name: "feedback", value: -0.9 },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "fx.setParam");
  assert.equal(calls[0]!.params.name, "feedback");
  assert.equal(calls[0]!.params.value, -0.9);
});

test("fx_set_param forwards depthOctaves 0 — the FROZEN sweep, a real setting", async () => {
  // ⚠️ 0 is falsy in JS. A `value || default` anywhere on this path would
  // silently substitute the default and the sweep would keep moving, which is
  // the exact opposite of what was asked.
  await client.callTool({
    name: "fx_set_param",
    arguments: { trackId: "track-1", effectId: "ph-1", name: "depthOctaves", value: 0 },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params.value, 0);
});

test("fx_describe accepts phaser as a kind", async () => {
  queuedResult = { kinds: [] };
  await client.callTool({ name: "fx_describe", arguments: { kind: "phaser" } });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "fx.describe");
  assert.equal(calls[0]!.params.kind, "phaser");
});

test("an unknown or mis-cased phaser spelling is still rejected at the MCP boundary", async () => {
  // The positive control for the tests above: they would also pass if the enum
  // had been replaced by a free-form string. It has not.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const miscased: any = await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "Phaser" },
  });
  assert.ok(miscased.isError, "a mis-cased kind must be rejected at the boundary");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const invented: any = await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "wobbulator" },
  });
  assert.ok(invented.isError, "an invented kind must be rejected at the boundary");
  assert.equal(calls.length, 0, "nothing reached the bridge");
});

test("⭐⭐ fx_add's kind schema says a phaser is NOT a flanger, and why", async () => {
  // ⭐ THE CENTRAL ONE. Both kinds sweep, both "whoosh", the two words are used
  // interchangeably by people who mean one of them specifically, and NOTHING in
  // the parameter names tells an agent which to reach for. Without this, the
  // pick is a coin toss.
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /phaser/, "the kind is named");
  assert.match(kind, /IT IS NOT A FLANGER/);
  assert.match(kind, /DELAYED copy/, "the flanger's mechanism is named");
  assert.match(kind, /PHASE-SHIFTED copy/, "the phaser's mechanism is named");
  assert.match(kind, /DOZENS of evenly\s*"?\s*\+?\s*"?\s*spaced|DOZENS of evenly/,
    "the flanger's notch density is quantified");
  assert.match(kind, /`stages` \/ 2/, "the phaser's notch count is given as a formula");
  assert.match(kind, /UNEVENLY/, "the non-harmonic spacing is named");
  // And the routing advice, so the agent knows which word maps to which kind.
  assert.match(kind, /reach for\s*"?\s*\+?\s*"?\s*`flanger` instead|`flanger` instead/);
});

test("fx_add's kind schema warns that mix 1 at feedback 0 is nearly INAUDIBLE", async () => {
  // ⚠️ The most likely bug report this kind will ever attract: an agent sets
  // mix to 1 expecting "more effect", hears nothing, and reports the effect as
  // broken. It is not — an all-pass chain alone changes no frequency's level.
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /INAUDIBLE/);
  assert.match(kind, /that is correct, not a bug/);
  assert.match(kind, /nothing to hear/);
});

test("fx_add's kind schema warns that centerHz is NOT a notch frequency", async () => {
  // The second-most-likely surprise: "put a phaser notch at 400 Hz" reaches
  // for `centerHz`, and the lowest notch then lands at 53–166 Hz depending on
  // `stages`.
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /straddle the centre rather than starting at it/);
  assert.match(kind, /0\.41x it at 4 stages, 0\.13x at 12/);
});

test("fx_add's kind schema states that stages is EVEN-ONLY and SNAPS", async () => {
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /EVEN NUMBERS\s*"?\s*\+?\s*"?\s*ONLY|EVEN NUMBERS ONLY/);
  assert.match(kind, /SNAPPED/);
  assert.match(kind, /reported back/, "the agent is told to read the value back");
});

test("fx_add's kind schema says depthOctaves 0 FREEZES the sweep and is a real setting", async () => {
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /FREEZES/);
  assert.match(kind, /not a broken one|is a real setting/);
});

test("⚠️ the derived echoes are named as RESULT fields and EXCLUDED from fx_describe", async () => {
  // BOTH HALVES, because each failure mode is real and they are opposites:
  //   · omit the "they are in the result" half and an agent never looks
  //   · omit the "not in fx_describe" half and an agent calls fx_describe,
  //     finds no values, and concludes the feature does not exist
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /`notchCount` and `firstNotchHz`/);
  assert.match(kind, /EVERY fx_add and fx_set_param RESULT/,
    "the tools that DO carry the echoes are named EXPLICITLY — the shared schema " +
    "string is read from both fx_add and fx_describe, so 'the response' would be " +
    "ambiguous and, read from fx_describe, false");
  assert.match(kind, /project_snapshot/);
  assert.match(kind, /NOT in\s*"?\s*\+?\s*"?\s*fx_describe|NOT in fx_describe/);
  // ⭐ NEGATIVE HALF, with a positive control on the lookup itself: the echo
  // names must NOT appear in fx_describe's own TOOL description as things
  // fx_describe returns. The control proves the haystack is non-empty and the
  // matcher works, so a `=== -1` cannot be a mistyped accessor.
  const describeDoc = await describeTool("fx_describe");
  assert.ok(describeDoc.length > 200, "positive control: fx_describe's description is non-empty");
  assert.match(describeDoc, /phaser/, "positive control: fx_describe's gloss does mention phaser");
  assert.match(describeDoc, /NOT here in fx_describe, which carries\s*"?\s*\+?\s*"?\s*schemas and no values|NOT here in fx_describe/,
    "fx_describe's own gloss must say the echoes are not its to give");
});

test("fx_describe's per-kind gloss teaches the phaser/flanger distinction too", async () => {
  // An agent that calls fx_describe with no `kind` reads THIS text, not
  // fxKindSchema's. The distinction has to survive in both places or half the
  // callers never see it.
  const doc = await describeTool("fx_describe");
  assert.match(doc, /phaser/);
  assert.match(doc, /NOT a flanger/);
  assert.match(doc, /stages` \/ 2 notches|`stages` \/ 2/);
});

test("automation prose names phaser and flags stages as hold-only", async () => {
  // `stages` is discrete: a ramp across it would clear the all-pass state
  // every block. An agent drawing a lane has no way to know that.
  // ⚠️ THIS PROSE IS ON THE `target` PARAMETER, NOT THE TOOL DESCRIPTION — the
  // same finding fx-bit-crusher.test.ts records for `fx_add.kind`. A test that
  // read the tool description would report the teaching as missing when it is
  // simply one level down.
  const doc = await describeParam("automation_add_lane", "target");
  assert.match(doc, /phaser/);
  assert.match(doc, /`phaser`'s `stages` is\s*"?\s*\+?\s*"?\s*DISCRETE|`stages` is DISCRETE/);
  assert.match(doc, /`hold` interpolation, never a ramp/);
});
