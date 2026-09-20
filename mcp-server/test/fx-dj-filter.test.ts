/**
 * fx-dj-filter.test.ts — the m39-i DJ filter's MCP surface.
 *
 * NO NEW TOOL ships with m39-i, and that is a contract rather than an
 * omission (creative-effects design rule 6.0.11): a new effect KIND rides the
 * existing fx_add / fx_set_param / fx_describe / automation_add_lane surface,
 * so the wire command count and the MCP tool count must both be UNCHANGED by
 * this item. What CAN silently go missing when a kind is added to shared
 * schemas and shared prose is what this file pins:
 *
 *   1. `djFilter` is accepted by `fxKindSchema` and forwarded VERBATIM. A kind
 *      missing from the enum is rejected at the MCP boundary with a schema
 *      error and never reaches the app — which reads to an agent as "the DAW
 *      does not have one".
 *   2. Its five params forward verbatim through `fx_add`'s `params` and
 *      `fx_set_param`, including a NEGATIVE `position` (the bipolar half a
 *      0…1 assumption would quietly break).
 *   3. ⭐ THE DESCRIPTIONS CARRY THE TWO THINGS AN AGENT CANNOT INFER: which
 *      way the knob turns, and that the effect is a MOTION (automate
 *      `position`) rather than a setting. The tool/param descriptions are the
 *      only manual an agent gets, so that teaching is a shippable property.
 *   4. ⚠️ And the honest one: high resonance makes the filter QUIETER. An
 *      agent that does not know the normalisation is deliberate will read the
 *      level drop as a defect and "fix" it.
 *
 * The stub-bridge pattern is fx-bit-crusher.test.ts's, verbatim.
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
  client = new Client({ name: "fx-dj-filter-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
});

beforeEach(() => {
  calls = [];
  queuedResult = { effectId: "djf-1", effects: [] };
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

test("fx_add accepts kind djFilter and forwards it verbatim", async () => {
  await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "djFilter" },
  });
  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "fx.add");
  assert.equal(calls[0]!.params.kind, "djFilter");
  assert.equal(calls[0]!.params.trackId, "track-1");
});

test("fx_add forwards every djFilter param, NEGATIVE position included", async () => {
  // ⭐ The negative value is the point. `position` is the only bipolar param
  // on any built-in effect kind, so a schema or coercion that assumes 0…1 —
  // which every other kind's params would tolerate — breaks exactly here.
  const params = {
    position: -0.72,
    resonance: 0.85,
    slopeDbPerOct: 12,
    deadZoneWidth: 0.1,
    resonanceTrack: 0.5,
  };
  await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "djFilter", params },
  });
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params.params, params);
});

test("fx_set_param forwards a negative djFilter position unmodified", async () => {
  await client.callTool({
    name: "fx_set_param",
    arguments: { trackId: "track-1", effectId: "djf-1", name: "position", value: -0.9 },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "fx.setParam");
  assert.equal(calls[0]!.params.name, "position");
  assert.equal(calls[0]!.params.value, -0.9);
});

test("fx_describe accepts djFilter as a kind", async () => {
  queuedResult = { kinds: [] };
  await client.callTool({ name: "fx_describe", arguments: { kind: "djFilter" } });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "fx.describe");
  assert.equal(calls[0]!.params.kind, "djFilter");
});

test("an unknown or mis-cased effect kind is still rejected at the MCP boundary", async () => {
  // The positive control for the tests above: they would also pass if the enum
  // had been replaced by a free-form string. It has not.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const miscased: any = await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "djfilter" },
  });
  assert.ok(miscased.isError, "a mis-cased kind must be rejected at the boundary");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const invented: any = await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "isolator" },
  });
  assert.ok(invented.isError, "an invented kind must be rejected at the boundary");
  assert.equal(calls.length, 0, "nothing reached the bridge");
});

test("fx_add's kind schema teaches WHICH WAY the knob turns", async () => {
  // An agent asked for "a filter sweep that drops the bass out" has to pick a
  // SIGN, and there is no way to derive it. It is stated, in both directions,
  // with the word that disambiguates each one.
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /djFilter/, "the kind is named");
  assert.match(kind, /NEGATIVE sweeps a LOW-pass/, "the negative direction is stated");
  assert.match(kind, /POSITIVE sweeps a HIGH-pass/, "the positive direction is stated");
  assert.match(kind, /BASS leaves first/, "the audible consequence is stated, not just the mode");
  assert.match(kind, /TREBLE leaves first/);
  assert.match(kind, /BIT-EXACT BYPASS/, "the centre's bit-exactness is stated");
});

test("fx_add's kind schema teaches that the DJ filter is a MOTION, not a setting", async () => {
  // ⭐ The single most likely way an agent ships a disappointing result: park
  // `position` at one value and call it a DJ filter. The description names the
  // fix and the exact tool to reach for.
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /A MOTION, NOT A SETTING/);
  assert.match(kind, /automation_add_lane/, "the tool to use is named, not implied");
});

test("fx_add's kind schema is HONEST that high resonance costs level", async () => {
  // ⚠️ Without this, an agent measuring the output after raising resonance
  // sees an ~11.5 dB drop and "fixes" a deliberate protection.
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /HIGH RESONANCE MAKES THE WHOLE FILTER QUIETER/);
  assert.match(kind, /11\.5 dB/, "the cost is quantified, not hand-waved");
  assert.match(kind, /do not read it as a bug/);
});

test("fx_add's kind schema states the cutoff law as arithmetic an agent can run", async () => {
  const kind = await describeParam("fx_add", "kind");
  // Errata E4: negative is the LOW-pass side, so the falling-from-20 kHz law is
  // the one that takes |position|, and the rising-from-20 Hz law is the positive
  // one. These two lines are a direction pin as much as an arithmetic pin.
  assert.match(kind, /20000 \* 0\.001\^\|position\|/, "the low-pass law is stated");
  assert.match(kind, /20 \* 1000\^position/, "the high-pass law is stated");
  // And the modulation depth consequence, which is NOT the usual ±1.0.
  assert.match(kind, /\+\/-2\.0/, "full modulation depth on a bipolar param is stated");
});

test("djFilter is offered on the master chain and named by fx_describe", async () => {
  // The master-chain list is in the TOOL description, a different surface from
  // the kind schema above — a kind can be in one and missing from the other.
  const addTool = await describeTool("fx_add");
  assert.match(addTool, /bassEnhancer\|bitCrusher\|djFilter/);
  const describe = await describeTool("fx_describe");
  assert.match(describe, /djFilter/);
  assert.match(describe, /automate/, "fx_describe repeats the motion advice");
});

test("automation_add_lane's target schema names djFilter as the canonical sweep", async () => {
  // Every param but the discrete slope is automatable, and `position` is the
  // lane an agent should reach for first — so the kind must not be missing
  // from the list an agent reads as "what works today".
  const target = await describeParam("automation_add_lane", "target");
  assert.match(target, /djFilter/);
  assert.match(target, /canonical lane to draw/);
});
