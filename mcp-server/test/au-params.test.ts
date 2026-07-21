/**
 * au-params.test.ts — round-trip coverage for au_describe_params/au_set_param
 * (design-au-parameter-surface, the hosted-AU parameter surface).
 *
 * Same stub-bridge pattern as vc.test.ts/connection-info.test.ts: unlike
 * integration.test.ts (real spawned DAWApp + real control WebSocket), this
 * suite monkeypatches `DawBridge.prototype.send` before any tool call runs,
 * so the REAL `McpServer` from `src/server.ts` is driven over an in-memory
 * transport (the audit-tools.test.ts precedent) with no live app required.
 * Asserts:
 *   - au_describe_params forwards trackId/effectId/offset/maxParams/addresses
 *     verbatim to au.describeParams, with omitted optional params coming
 *     through as undefined (never stray literals)
 *   - au_describe_params requires trackId; being read-only it registers via
 *     `server.registerTool` directly (the fx_describe precedent), so an
 *     unrecognized extra argument is silently stripped by zod's default
 *     "strip" mode rather than rejected (m16-e strictness is scoped to
 *     mutating tools only)
 *   - au_set_param forwards trackId/effectId/address/value verbatim to
 *     au.setParam, requires trackId/address/value, and — because it's a
 *     MUTATING tool registered through the m16-e strict wrapper — rejects an
 *     unrecognized extra argument at the MCP boundary before ever reaching
 *     the bridge
 *   - a stubbed success result round-trips back through each tool unchanged
 *   - a stubbed app-side error surfaces as an MCP tool error (isError: true)
 *     carrying the app's own message verbatim, never swallowed
 */

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { DawBridge } from "../src/bridge.js";

// ---------------------------------------------------------------------------
// Stub the bridge BEFORE any tool call runs.
// ---------------------------------------------------------------------------

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
  client = new Client({ name: "au-params-test-client", version: "0.0.0" });
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

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function parseJSON(result: any): any {
  const first = result.content[0];
  assert.ok(first && first.type === "text", `expected a text content item, got: ${JSON.stringify(result.content)}`);
  return JSON.parse(first.text as string);
}

const TRACK_ID = "11111111-1111-4111-8111-111111111111";
const EFFECT_ID = "22222222-2222-4222-8222-222222222222";

// ---------------------------------------------------------------------------
// au_describe_params
// ---------------------------------------------------------------------------

test("au_describe_params forwards every supplied param verbatim to au.describeParams", async () => {
  const stubbedPage = {
    trackId: TRACK_ID,
    effectId: EFFECT_ID,
    componentName: "AUDelay",
    hasParameterTree: true,
    totalCount: 1863,
    offset: 0,
    truncated: true,
    parameters: [
      {
        address: "281474976710659",
        identifier: "delayTime",
        displayName: "Delay Time",
        keyPath: "delayTime",
        unit: "seconds",
        unitName: null,
        minValue: 0,
        maxValue: 2,
        value: 1,
        writable: true,
        readable: true,
        valueStrings: null,
      },
    ],
    unknownAddresses: [],
  };
  queuedResult = stubbedPage;

  const result = await client.callTool({
    name: "au_describe_params",
    arguments: { trackId: TRACK_ID, effectId: EFFECT_ID, offset: 10, maxParams: 50 },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "au.describeParams");
  assert.deepEqual(calls[0]!.params, {
    trackId: TRACK_ID,
    effectId: EFFECT_ID,
    offset: 10,
    maxParams: 50,
    addresses: undefined,
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbedPage, "the app's response round-trips back verbatim");
});

test("au_describe_params: omitted optional params come through as undefined, not stray literals", async () => {
  queuedResult = { trackId: TRACK_ID, hasParameterTree: false, totalCount: 0, offset: 0, truncated: false, parameters: [], unknownAddresses: [], componentName: "SomeSynth" };

  await client.callTool({ name: "au_describe_params", arguments: { trackId: TRACK_ID } });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, {
    trackId: TRACK_ID,
    effectId: undefined,
    offset: undefined,
    maxParams: undefined,
    addresses: undefined,
  });
});

test("au_describe_params forwards an addresses filter verbatim (exact-get, mutually exclusive with paging)", async () => {
  queuedResult = { trackId: TRACK_ID, hasParameterTree: true, totalCount: 5, offset: 0, truncated: false, parameters: [], unknownAddresses: ["999"], componentName: "AULowpass" };

  await client.callTool({
    name: "au_describe_params",
    arguments: { trackId: TRACK_ID, addresses: ["123", "999"] },
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params.addresses, ["123", "999"]);
});

test("au_describe_params requires trackId (rejected at the schema layer, zero bridge calls)", async () => {
  const result = await client.callTool({ name: "au_describe_params", arguments: {} });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "a missing required trackId must be rejected before the bridge call");
  assert.equal(calls.length, 0);
});

test("au_describe_params is read-only (server.registerTool directly, the fx_describe precedent): an unrecognized argument is silently stripped, not rejected", async () => {
  queuedResult = { trackId: TRACK_ID, hasParameterTree: false, totalCount: 0, offset: 0, truncated: false, parameters: [], unknownAddresses: [], componentName: "SomeSynth" };

  const result = await client.callTool({
    name: "au_describe_params",
    arguments: { trackId: TRACK_ID, bogus: true },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError, "read-only tools use a non-strict schema (m16-e scopes strictness to mutating tools)");
  assert.equal(calls.length, 1, "the call still reaches the bridge, with the unrecognized key stripped");
  assert.ok(!("bogus" in calls[0]!.params), "the stray key never reaches bridge.send");
});

test("au_describe_params surfaces a bridge-side error as an MCP tool error, message verbatim", async () => {
  queuedError = new Error(
    "the master chain hosts built-in effects only — AU parameters apply to track inserts"
  );

  const result = await client.callTool({
    name: "au_describe_params",
    arguments: { trackId: "master" },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /master chain hosts built-in effects only/);
});

// ---------------------------------------------------------------------------
// au_set_param
// ---------------------------------------------------------------------------

test("au_set_param forwards trackId/effectId/address/value verbatim to au.setParam", async () => {
  const stubbedResult = {
    trackId: TRACK_ID,
    effectId: EFFECT_ID,
    parameter: {
      address: "281474976710659",
      identifier: "delayTime",
      displayName: "Delay Time",
      keyPath: "delayTime",
      unit: "seconds",
      unitName: null,
      minValue: 0,
      maxValue: 2,
      value: 1.5,
      writable: true,
      readable: true,
      valueStrings: null,
    },
  };
  queuedResult = stubbedResult;

  const result = await client.callTool({
    name: "au_set_param",
    arguments: { trackId: TRACK_ID, effectId: EFFECT_ID, address: "281474976710659", value: 1.5 },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "au.setParam");
  assert.deepEqual(calls[0]!.params, {
    trackId: TRACK_ID,
    effectId: EFFECT_ID,
    address: "281474976710659",
    value: 1.5,
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbedResult, "the app's post-set read-back round-trips verbatim");
});

test("au_set_param: omitted effectId comes through as undefined (targets the track's AU instrument)", async () => {
  queuedResult = {
    trackId: TRACK_ID,
    parameter: {
      address: "1",
      identifier: "cutoff",
      displayName: "Cutoff",
      keyPath: "cutoff",
      unit: "hertz",
      unitName: null,
      minValue: 20,
      maxValue: 20000,
      value: 800,
      writable: true,
      readable: true,
      valueStrings: null,
    },
  };

  await client.callTool({ name: "au_set_param", arguments: { trackId: TRACK_ID, address: "1", value: 800 } });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { trackId: TRACK_ID, effectId: undefined, address: "1", value: 800 });
});

test("au_set_param requires trackId, address, and value (rejected at the schema layer, zero bridge calls)", async () => {
  for (const arguments_ of [
    {},
    { trackId: TRACK_ID },
    { trackId: TRACK_ID, address: "1" },
    { address: "1", value: 1 },
  ]) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const result = (await client.callTool({ name: "au_set_param", arguments: arguments_ as any })) as any;
    assert.ok(result.isError, `expected a schema error for ${JSON.stringify(arguments_)}`);
  }
  assert.equal(calls.length, 0);
});

test("au_set_param rejects an unrecognized argument at the MCP boundary (never reaches the bridge, m16-e)", async () => {
  const result = await client.callTool({
    name: "au_set_param",
    arguments: { trackId: TRACK_ID, address: "1", value: 1, bogus: true },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an unrecognized key must be rejected before the bridge call");
  assert.equal(calls.length, 0, "the strict schema rejects before bridge.send is ever invoked");
});

test("au_set_param surfaces a bridge-side error (e.g. read-only parameter) verbatim", async () => {
  queuedError = new Error("parameter 'bypass' is not writable");

  const result = await client.callTool({
    name: "au_set_param",
    arguments: { trackId: TRACK_ID, address: "1", value: 1 },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /not writable/);
});
