/**
 * fx-ring-mod.test.ts — the m39-m ring modulator's MCP surface.
 *
 * NO NEW TOOL ships with m39-m, and that is a contract rather than an omission
 * (creative-effects design rule 6.0.11): a new effect KIND rides the existing
 * fx_add / fx_set_param / fx_describe / automation_add_lane surface, so the
 * wire command count and the MCP tool count must both be UNCHANGED by this
 * item. What CAN silently go missing when a kind is added to shared schemas and
 * shared prose is what this file pins:
 *
 *   1. `ringMod` is accepted by `fxKindSchema` and forwarded VERBATIM. A kind
 *      missing from the enum is rejected at the MCP boundary with a schema
 *      error and never reaches the app — which reads to an agent as "the DAW
 *      does not have one".
 *   2. Its five params forward verbatim through `fx_add`'s `params` and
 *      `fx_set_param`, including a SUB-1 `carrierHz` (the range floor is 0.5,
 *      and a 0…N assumption or an integer coercion would quietly break it).
 *   3. ⭐ THE DESCRIPTIONS CARRY THE THREE THINGS AN AGENT CANNOT INFER:
 *      WHAT the effect produces (sidebands at |f − fc| and f + fc, not a
 *      filtered version of the input), that a sub-audio carrier is a TREMOLO
 *      whose pulse rate depends on `mix`, and — the honest one — that the clangorous
 *      fold-back is DELIBERATE. An agent that does not know the third will
 *      hear the effect working correctly and "fix" it.
 *   4. `carrierHz` is named as an automatable lane, because "phase stays
 *      continuous across a change" is the property that makes it one and
 *      nothing else on this surface says so.
 *
 * The stub-bridge pattern is fx-dj-filter.test.ts's, verbatim.
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
  client = new Client({ name: "fx-ring-mod-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
});

beforeEach(() => {
  calls = [];
  queuedResult = { effectId: "rm-1", effects: [] };
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

test("fx_add accepts kind ringMod and forwards it verbatim", async () => {
  await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "ringMod" },
  });
  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "fx.add");
  assert.equal(calls[0]!.params.kind, "ringMod");
  assert.equal(calls[0]!.params.trackId, "track-1");
});

test("fx_add forwards every ringMod param, a SUB-1 carrier included", async () => {
  // ⭐ The 0.75 is the point. `carrierHz`'s range FLOOR is 0.5 — the only
  // built-in param whose useful low end is below 1 — so a schema that coerced
  // to an integer, or a `Math.max(1, …)` guard anywhere on the path, would
  // quietly turn a slow tremolo into a 1 Hz one and nothing would report it.
  const params = {
    carrierHz: 0.75,
    mix: 0.42,
    waveform: 3,
    inputHighCutHz: 4000,
    stereoSpreadDeg: 135,
  };
  await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "ringMod", params },
  });
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params.params, params);
});

test("fx_set_param forwards a fractional ringMod carrier unmodified", async () => {
  await client.callTool({
    name: "fx_set_param",
    arguments: { trackId: "track-1", effectId: "rm-1", name: "carrierHz", value: 1.5 },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "fx.setParam");
  assert.equal(calls[0]!.params.name, "carrierHz");
  assert.equal(calls[0]!.params.value, 1.5);
});

test("fx_describe accepts ringMod as a kind", async () => {
  queuedResult = { kinds: [] };
  await client.callTool({ name: "fx_describe", arguments: { kind: "ringMod" } });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "fx.describe");
  assert.equal(calls[0]!.params.kind, "ringMod");
});

test("an unknown or mis-cased effect kind is still rejected at the MCP boundary", async () => {
  // The positive control for the tests above: they would also pass if the enum
  // had been replaced by a free-form string. It has not.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const miscased: any = await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "ringmod" },
  });
  assert.ok(miscased.isError, "a mis-cased kind must be rejected at the boundary");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const invented: any = await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "frequencyShifter" },
  });
  assert.ok(invented.isError, "an invented kind must be rejected at the boundary");
  assert.equal(calls.length, 0, "nothing reached the bridge");
});

test("fx_add's kind schema teaches WHAT a ring modulator produces", async () => {
  // An agent asked for "a metallic, bell-like sound" has to know this is not a
  // filter and not a distortion. The sideband law is the whole explanation and
  // there is no way to derive it from the parameter names.
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /ringMod/, "the kind is named");
  assert.match(kind, /\|f - carrierHz\|/, "the lower sideband law is stated");
  assert.match(kind, /f \+ carrierHz/, "the upper sideband law is stated");
  assert.match(kind, /INHARMONIC/, "the audible consequence is stated, not just the arithmetic");
  assert.match(kind, /BIT-EXACT BYPASS/, "mix 0's bit-exactness is stated");
});

test("fx_add's kind schema states the tremolo rate AND its dependence on mix", async () => {
  // ⭐ The single most likely "this is broken" report from a first-time user:
  // set 2 Hz, count the pulses, and find they do not match what the docs said.
  // ⚠️ AND THE DOCS WERE WRONG FIRST: an earlier draft asserted the doubled
  // rate unconditionally. The rendered demo measured 2.00 Hz at the default
  // mix, and `RingModTests` L4f now pins 2 / 2 / 4 Hz at mix 0.25 / 0.5 / 1.0.
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /TREMOLO RATE DEPENDS ON `mix`/);
  assert.match(kind, /at mix 0\.5 \(the DEFAULT\) or below it pulses at the CARRIER rate/);
  assert.match(kind, /2 Hz at mix 1 is four a second/,
    "both ends of the rule are quantified, not hand-waved");
});

test("fx_add's kind schema is HONEST that the clangorous fold-back is deliberate", async () => {
  // ⚠️ Without this, an agent hearing inharmonic tones above the carrier will
  // "fix" the effect's defining character — and the fix it would reach for
  // (oversampling) is the one the design explicitly forbids.
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /FOLD-BACK IS THE FEATURE, NOT/);
  assert.match(kind, /deliberately not oversampled away/);
  assert.match(kind, /inputHighCutHz/);
  assert.match(kind, /4000/, "an actionable value for a cleaner result is given");
});

test("fx_add's kind schema names the waveform indices and their band-limiting", async () => {
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /0 sine \/ 1 triangle \/ 2 square \/ 3 saw/);
  assert.match(kind, /band-limited/,
    "an agent has no other way to know the rich shapes are alias-free");
});

test("ringMod is offered on the master chain and named by fx_describe", async () => {
  // The master-chain list is in the TOOL description, a different surface from
  // the kind schema above — a kind can be in one and missing from the other.
  const addTool = await describeTool("fx_add");
  assert.match(addTool, /bitCrusher\|djFilter\|ringMod/);
  const describe = await describeTool("fx_describe");
  assert.match(describe, /ringMod/);
  assert.match(describe, /inharmonic/, "fx_describe repeats the one fact that defines it");
});

test("automation_add_lane's target schema names ringMod's carrier as a drawable lane", async () => {
  // `carrierHz` earns its place on this list because its PHASE is continuous
  // across a change — without that, an automated carrier would click on every
  // point and the lane would be a trap rather than a feature.
  const target = await describeParam("automation_add_lane", "target");
  assert.match(target, /ringMod/);
  assert.match(target, /phase stays continuous/);
});
