/**
 * fx-bit-crusher.test.ts — the m32-e bit-crusher's MCP surface.
 *
 * No new TOOL ships with m32-e: the kind rides the existing fx_add /
 * fx_set_param / fx_describe / automation_add_lane surface, exactly as
 * `bassEnhancer` did. So what needs a test is not a new registration but the
 * three things that CAN silently go missing when a kind is added to shared
 * schemas and shared prose:
 *
 *   1. `bitCrusher` is accepted by `fxKindSchema` and forwarded VERBATIM — a
 *      kind missing from the enum is rejected at the MCP boundary with a
 *      schema error and never reaches the app, which reads to an agent as
 *      "the DAW does not have one".
 *   2. Its params (including the two 0/1 booleans) forward verbatim through
 *      `fx_add`'s `params` and `fx_set_param`.
 *   3. ⭐ THE DESCRIPTIONS CARRY THE AUTHENTICITY DEFAULTS. This is the whole
 *      item: `antiAlias: 0` and `dither: 0` are deliberate, and an agent that
 *      does not know that will "helpfully" turn them on and miss the reference
 *      sound. The tool description is the ONLY manual an agent gets, so the
 *      teaching being present in it is a shippable property, not documentation
 *      polish.
 *
 * The stub-bridge pattern is fx-spectrum.test.ts's, verbatim.
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
  client = new Client({ name: "fx-bit-crusher-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
});

beforeEach(() => {
  calls = [];
  queuedResult = { effectId: "crush-1", effects: [] };
});

async function describeTool(name: string): Promise<string> {
  const { tools } = await client.listTools();
  const tool = tools.find((t) => t.name === name);
  assert.ok(tool, `${name} must be registered`);
  return tool.description ?? "";
}

/**
 * The description of ONE INPUT PARAMETER, as the MCP client receives it.
 *
 * ⚠️ MEASURED, not assumed, and the first draft of this file got it wrong: the
 * per-kind teaching does NOT live in `fx_add`'s tool description. It lives in
 * `fxKindSchema`'s `.describe()`, which lands on `inputSchema.properties.kind`
 * — 5 013 characters of it, against a tool description that names no kind's
 * params at all. Asserting against the tool description would have passed by
 * accident for the master-chain list and failed for everything else.
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

test("fx_add accepts kind bitCrusher and forwards it verbatim", async () => {
  await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "bitCrusher" },
  });
  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "fx.add");
  assert.equal(calls[0]!.params.kind, "bitCrusher");
  assert.equal(calls[0]!.params.trackId, "track-1");
});

test("fx_add forwards every bitCrusher param, booleans included, unmodified", async () => {
  const params = {
    bits: 12,
    downsampleHz: 26040,
    antiAlias: 0,
    dither: 0,
    mix: 1,
  };
  await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "bitCrusher", params },
  });
  assert.equal(calls.length, 1);
  // ⭐ The two switches ride as NUMBERS (0/1), the truePeak/pingPong precedent.
  // A client-side coercion to booleans here would be rejected by the app.
  assert.deepEqual(calls[0]!.params.params, params);
});

test("fx_set_param forwards a bitCrusher antiAlias flip as 0/1", async () => {
  await client.callTool({
    name: "fx_set_param",
    arguments: { trackId: "track-1", effectId: "crush-1", name: "antiAlias", value: 1 },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "fx.setParam");
  assert.equal(calls[0]!.params.name, "antiAlias");
  assert.equal(calls[0]!.params.value, 1);
});

test("fx_describe accepts bitCrusher as a kind", async () => {
  queuedResult = { kinds: [] };
  await client.callTool({ name: "fx_describe", arguments: { kind: "bitCrusher" } });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "fx.describe");
  assert.equal(calls[0]!.params.kind, "bitCrusher");
});

test("an unknown effect kind is still rejected at the MCP boundary", async () => {
  // The positive control for the two tests above: they would also pass if the
  // enum had been replaced by a free-form string. It has not.
  // The SDK returns an error RESULT here, it does not throw — `isError` is
  // this repo's own boundary-rejection assertion (fx-spectrum.test.ts:153).
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const miscased: any = await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "bitcrusher" },
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

test("fx_add's kind schema teaches that antiAlias and dither DEFAULT OFF on purpose", async () => {
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /bitCrusher/, "the kind is named");
  assert.match(kind, /26040/, "the SP-1200 rate is stated as a number");
  assert.match(
    kind,
    /antiAlias: 0/,
    "the authentic default is stated explicitly, not left to be inferred"
  );
  assert.match(
    kind,
    /DELIBERATE/,
    "an agent must be told the off defaults are a choice, not an oversight"
  );
  assert.match(
    kind,
    /OMITTING the reconstruction/,
    "the MECHANISM is stated, so the agent can reason about it rather than obey a rule"
  );
  // …and the master chain accepts it, so an agent crushing a whole beat is not
  // told to pick from a list the effect is missing from. That list is in the
  // TOOL description, a different surface from the one above.
  const tool = await describeTool("fx_add");
  assert.match(tool, /bassEnhancer\|bitCrusher/);
});

test("fx_describe's description names bitCrusher and its aliasing default", async () => {
  const description = await describeTool("fx_describe");
  assert.match(description, /bitCrusher/);
  assert.match(description, /aliasing IS the character/);
});

test("automation_add_lane's target schema lists bitCrusher as automatable", async () => {
  // Every one of its five params is automatable (slot order = the spec table),
  // so an agent must not read the kind's absence from this list as a refusal.
  const target = await describeParam("automation_add_lane", "target");
  assert.match(target, /bitCrusher/);
});
