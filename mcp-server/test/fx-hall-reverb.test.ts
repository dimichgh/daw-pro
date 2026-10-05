/**
 * fx-hall-reverb.test.ts — the m39-l hall reverb's MCP surface.
 *
 * NO NEW TOOL ships with m39-l, and that is a contract rather than an omission
 * (creative-effects design rule 6.0.11): a new effect KIND rides the existing
 * fx_add / fx_set_param / fx_describe / automation_add_lane surface, so the
 * wire command count and the MCP tool count must both be UNCHANGED by this
 * item. What CAN silently go missing when a kind is added to shared schemas
 * and shared prose is what this file pins:
 *
 *   1. `hallReverb` is accepted by `fxKindSchema` and forwarded VERBATIM. A
 *      kind missing from the enum is rejected at the MCP boundary with a
 *      schema error and never reaches the app — which reads to an agent as
 *      "the DAW does not have one".
 *   2. All FOURTEEN params forward verbatim through `fx_add`'s `params` and
 *      `fx_set_param`, including a NEGATIVE `earlyLateBalance` (its range
 *      crosses zero on purpose, and any `Math.abs` or unsigned assumption
 *      anywhere on the path would silently delete the "close" half of the
 *      control).
 *   3. ⭐ THE HARD ONE: WE NOW SHIP TWO REVERBS, AND NOTHING IN THE PARAMETER
 *      NAMES TELLS AN AGENT WHICH TO REACH FOR. `reverb.roomSize` reads like
 *      a size control and is a DECAY control; an agent asked for "a bigger
 *      room" will otherwise turn it and get a longer tail in the same small
 *      room, with nothing anywhere to contradict it. Both surfaces —
 *      `fxKindSchema` and the `fx_describe` tool text — must carry that, or
 *      an agent reading one and an agent reading the other disagree. That is
 *      this tree's named characteristic failure: the record says X, the source
 *      says Y, and nothing compares them.
 *   4. ⛔ `.reverb` IS DOCUMENTED HONESTLY AND NOT DEPRECATED. The word
 *      "deprecated" must NOT appear against it: deprecation creates a
 *      second-class effect agents route around while real projects still
 *      render through it, and Freeverb's small, bright, dense room is a
 *      genuinely good sound the hall does not replicate.
 *   5. The two things an agent cannot infer from the numbers: that
 *      `highDecayMultiplier` defaults BELOW 1 on purpose, and that
 *      `sizeMeters` gives a Doppler glide when automated under a live tail.
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
  client = new Client({ name: "fx-hall-reverb-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
});

beforeEach(() => {
  calls = [];
  queuedResult = { effectId: "hr-1", effects: [] };
});

async function describeTool(name: string): Promise<string> {
  const { tools } = await client.listTools();
  const tool = tools.find((t) => t.name === name);
  assert.ok(tool, `${name} must be registered`);
  return tool.description ?? "";
}

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

test("fx_add accepts kind hallReverb and forwards it verbatim", async () => {
  await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "hallReverb" },
  });
  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "fx.add");
  assert.equal(calls[0]!.params.kind, "hallReverb");
  assert.equal(calls[0]!.params.trackId, "track-1");
});

test("fx_add forwards all 14 hallReverb params, a NEGATIVE earlyLateBalance included", async () => {
  // ⭐ The -0.55 is the point. `earlyLateBalance` crosses zero deliberately:
  // negative is "standing near the source" and positive is "back in the
  // hall", and they are different sounds rather than more and less of one.
  // Any unsigned assumption on the path — a Math.abs, a Math.max(0, …), a
  // "percentage" coercion — would delete half the control and report success.
  const params = {
    mix: 0.62,
    decaySeconds: 6.5,
    sizeMeters: 34,
    preDelayMs: 85,
    width: 1.15,
    diffusion: 0.42,
    earlyLateBalance: -0.55,
    lowDecayMultiplier: 2.75,
    highDecayMultiplier: 0.22,
    lowCrossoverHz: 140,
    highCrossoverHz: 9500,
    modRateHz: 1.9,
    modDepthMs: 2.4,
    freeze: 0,
  };
  assert.equal(Object.keys(params).length, 14, "this test stopped covering every param");
  await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "hallReverb", params },
  });
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params.params, params);
});

test("fx_set_param forwards a negative hallReverb earlyLateBalance unmodified", async () => {
  await client.callTool({
    name: "fx_set_param",
    arguments: {
      trackId: "track-1",
      effectId: "hr-1",
      name: "earlyLateBalance",
      value: -0.9,
    },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "fx.setParam");
  assert.equal(calls[0]!.params.name, "earlyLateBalance");
  assert.equal(calls[0]!.params.value, -0.9);
});

test("fx_describe accepts hallReverb as a kind", async () => {
  queuedResult = { kinds: [] };
  await client.callTool({ name: "fx_describe", arguments: { kind: "hallReverb" } });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "fx.describe");
  assert.equal(calls[0]!.params.kind, "hallReverb");
});

test("an unknown or mis-cased hallReverb spelling is still rejected at the MCP boundary", async () => {
  // The positive control for the tests above: they would also pass if the enum
  // had been replaced by a free-form string. It has not.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const miscased: any = await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "hallreverb" },
  });
  assert.ok(miscased.isError, "a mis-cased kind must be rejected at the boundary");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const invented: any = await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "plateReverb" },
  });
  assert.ok(invented.isError, "an invented kind must be rejected at the boundary");
  assert.equal(calls.length, 0, "nothing reached the bridge");
});

test("fx_add's kind schema tells an agent WHICH of the two reverbs to reach for", async () => {
  // ⭐ THE ONE THAT MATTERS. Two reverbs now ship and `reverb.roomSize` reads
  // like a size control while being a decay control. Without this, an agent
  // asked for "a bigger room" turns `roomSize`, gets a longer tail in the same
  // small room, and has nothing anywhere to tell it otherwise.
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /hallReverb/, "the kind is named");
  assert.match(kind, /HOW IT DIFFERS FROM `reverb`/);
  assert.match(kind, /ACTUAL size in metres/);
  assert.match(kind, /decay in SECONDS/);
  // And the honest correction on the OLD kind, on the SAME surface.
  assert.match(kind, /HOW LONG THE TAIL RINGS/);
  assert.match(kind, /compile-time constants/,
    "the mechanism is given, not just the conclusion");
});

test("⛔ `.reverb` is documented honestly and NOT deprecated, on both surfaces", async () => {
  // Deprecation was considered and REJECTED (design §5.2): it creates a
  // second-class effect agents route around while real projects still render
  // through it, and it invites someone to "finish the job" by changing
  // behaviour. This pins the absence, which no other test does.
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /NOT DEPRECATED|NOT deprecated|Not deprecated/);
  assert.doesNotMatch(kind, /`reverb` is deprecated/);
  const describe = await describeTool("fx_describe");
  assert.doesNotMatch(describe, /`reverb` is deprecated/);
  assert.match(describe, /NOT deprecated|Not deprecated/);
});

test("fx_add's kind schema states the two things an agent cannot infer", async () => {
  const kind = await describeParam("fx_add", "kind");
  // (1) `highDecayMultiplier` defaults BELOW 1 on purpose. A reader seeing a
  // 0.1–1 range with a 0.5 default would reasonably "correct" it to 1.
  assert.match(kind, /defaults to 0\.5, NOT 1/);
  assert.match(kind, /metal tank/, "the consequence is named in the words a listener uses");
  // (2) `sizeMeters` automates smoothly but pitch-shifts a live tail.
  assert.match(kind, /DOPPLER GLIDE/);
  assert.match(kind, /smooth, not a click/,
    "it must be distinguished from the delay's integer-snap defect");
});

test("hallReverb is offered on the master chain and named by fx_describe", async () => {
  // The master-chain list is in the TOOL description, a different surface from
  // the kind schema above — a kind can be in one and missing from the other.
  const addTool = await describeTool("fx_add");
  assert.match(addTool, /ringMod\|flanger\|hallReverb/);
  const describe = await describeTool("fx_describe");
  assert.match(describe, /hallReverb/);
  assert.match(describe, /8-line FDN hall/,
    "fx_describe repeats the one phrase that identifies it");
});

test("automation_add_lane's target schema lists hallReverb, with its two caveats", async () => {
  const target = await describeParam("automation_add_lane", "target");
  assert.match(target, /hallReverb/);
  assert.match(target, /Doppler glide/, "the sizeMeters caveat travels with the lane advice");
  assert.match(target, /`hold` lane rather than a ramp/,
    "freeze is a switch and a ramp would trip it on the way past");
});
