/**
 * fx-flanger.test.ts — the m39-j flanger's MCP surface.
 *
 * NO NEW TOOL ships with m39-j, and that is a contract rather than an omission
 * (creative-effects design rule 6.0.11): a new effect KIND rides the existing
 * fx_add / fx_set_param / fx_describe / automation_add_lane surface, so the
 * wire command count and the MCP tool count must both be UNCHANGED by this
 * item. What CAN silently go missing when a kind is added to shared schemas and
 * shared prose is what this file pins:
 *
 *   1. `flanger` is accepted by `fxKindSchema` and forwarded VERBATIM. A kind
 *      missing from the enum is rejected at the MCP boundary with a schema
 *      error and never reaches the app — which reads to an agent as "the DAW
 *      does not have one".
 *   2. Its six params forward verbatim through `fx_add`'s `params` and
 *      `fx_set_param`, including a NEGATIVE `feedback` (this is the only
 *      built-in param whose range crosses zero on purpose, and any
 *      `Math.abs`, `Math.max(0, …)` or unsigned assumption anywhere on the
 *      path would silently delete half the effect).
 *   3. ⭐ THE DESCRIPTIONS CARRY THE THREE THINGS AN AGENT CANNOT INFER:
 *      that the sweep is UPWARD-ONLY from `delayMs` (so a `depthMs` larger
 *      than `delayMs` is SAFE, not a broken sweep — the §6.3.2 decision), that
 *      `feedback` is bipolar and NEGATIVE is a real character rather than a
 *      mistake, and — the honest one — that `feedback` CHANGES LEVEL, with the
 *      arithmetic, so an agent A/B-ing two settings knows the louder one is
 *      not automatically the better one.
 *   4. `flanger` is distinguished from `chorus`. They are both short modulated
 *      delays, both have `rateHz` and `depthMs`, and an agent asked for "a
 *      swirly pad" will otherwise pick by coin toss.
 *
 * The stub-bridge pattern is fx-ring-mod.test.ts's, verbatim.
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
  client = new Client({ name: "fx-flanger-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
});

beforeEach(() => {
  calls = [];
  queuedResult = { effectId: "fl-1", effects: [] };
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

test("fx_add accepts kind flanger and forwards it verbatim", async () => {
  await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "flanger" },
  });
  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "fx.add");
  assert.equal(calls[0]!.params.kind, "flanger");
  assert.equal(calls[0]!.params.trackId, "track-1");
});

test("fx_add forwards every flanger param, a NEGATIVE feedback included", async () => {
  // ⭐ The -0.72 is the point. `feedback` is the only built-in param whose
  // range crosses zero deliberately, and the negative half is a distinct
  // sound, not a degenerate case. Any unsigned assumption on the path — a
  // Math.abs, a Math.max(0, …), a "percentage" coercion — would delete half
  // the effect and report success.
  const params = {
    rateHz: 4.25,
    depthMs: 7.5,
    delayMs: 0.35,
    feedback: -0.72,
    mix: 0.93,
    stereoPhaseDeg: 150,
  };
  await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "flanger", params },
  });
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params.params, params);
});

test("fx_set_param forwards a negative flanger feedback unmodified", async () => {
  await client.callTool({
    name: "fx_set_param",
    arguments: { trackId: "track-1", effectId: "fl-1", name: "feedback", value: -0.9 },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "fx.setParam");
  assert.equal(calls[0]!.params.name, "feedback");
  assert.equal(calls[0]!.params.value, -0.9);
});

test("fx_describe accepts flanger as a kind", async () => {
  queuedResult = { kinds: [] };
  await client.callTool({ name: "fx_describe", arguments: { kind: "flanger" } });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "fx.describe");
  assert.equal(calls[0]!.params.kind, "flanger");
});

test("an unknown or mis-cased flanger spelling is still rejected at the MCP boundary", async () => {
  // The positive control for the tests above: they would also pass if the enum
  // had been replaced by a free-form string. It has not.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const miscased: any = await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "Flanger" },
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

test("fx_add's kind schema teaches the UPWARD-ONLY sweep, which is the §6.3.2 decision", async () => {
  // ⭐ Without this, an agent setting depthMs 8 against delayMs 1 has every
  // reason to expect a broken or clipped sweep — that is what a bipolar
  // flanger would do — and will pick timid values to avoid it.
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /flanger/, "the kind is named");
  assert.match(kind, /UPWARD-ONLY/);
  assert.match(kind, /never dips below the floor/);
  assert.match(kind, /`depthMs` larger than `delayMs` is SAFE/);
});

test("fx_add's kind schema states that feedback is BIPOLAR and that it changes LEVEL", async () => {
  // ⚠️ The honest one. An agent A/B-ing two feedback settings will otherwise
  // read "louder" as "better" — and positive feedback is up to +14.8 dB at
  // the top of its range, which is a level decision disguised as a tone one.
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /BIPOLAR AND IT CHANGES LEVEL/);
  assert.match(kind, /\(1-mix\) \+ mix\/\(1-feedback\)/, "the arithmetic is given, not hinted");
  assert.match(kind, /\+14\.8 dB/, "the worst case is quantified");
  assert.match(kind, /not a mistake/, "the negative half is named as a character, not an error");
});

test("fx_add's kind schema distinguishes flanger from chorus", async () => {
  // They share `rateHz` and `depthMs` and both are short modulated delays;
  // nothing in the parameter names tells an agent which to reach for.
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /HOW IT DIFFERS\s+FROM `chorus`|HOW IT DIFFERS FROM `chorus`/);
  assert.match(kind, /reads as detuning/, "the chorus's own character is named");
  assert.match(kind, /sharpens the peaks/, "the flanger's own character is named");
});

test("fx_add's kind schema gives the comb law and names the echo fx_describe returns", async () => {
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /1\/\(2\*delay\)/, "the notch law is stated");
  assert.match(kind, /firstNotchHzAtSweepFloor/,
    "the derived echo an agent can read back is named");
  assert.match(kind, /BIT-EXACT BYPASS/, "mix 0's bit-exactness is stated");
  assert.match(kind, /THROUGH-ZERO flanging is NOT this effect/,
    "the thing it deliberately is not is stated, so nobody files it as a bug");
});

test("flanger is offered on the master chain and named by fx_describe", async () => {
  // The master-chain list is in the TOOL description, a different surface from
  // the kind schema above — a kind can be in one and missing from the other.
  const addTool = await describeTool("fx_add");
  assert.match(addTool, /djFilter\|ringMod\|flanger/);
  const describe = await describeTool("fx_describe");
  assert.match(describe, /flanger/);
  assert.match(describe, /jet-plane whoosh/,
    "fx_describe repeats the one phrase that identifies it");
});

test("automation_add_lane's target schema lists flanger among the drawable built-ins", async () => {
  const target = await describeParam("automation_add_lane", "target");
  assert.match(target, /flanger/);
});
