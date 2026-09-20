/**
 * au-presets.test.ts — round-trip coverage for au_list_presets/au_load_preset
 * (m23-cw, the hosted-AU preset surface — the second half of the `au.*`
 * namespace, alongside au-params.test.ts's au_describe_params/au_set_param).
 *
 * Same stub-bridge pattern as au-params.test.ts/vc.test.ts: monkeypatches
 * `DawBridge.prototype.send` before any tool call runs, so the REAL
 * `McpServer` from `src/server.ts` is driven over an in-memory transport
 * (the audit-tools.test.ts precedent) with no live app required. Asserts:
 *   - au_list_presets forwards trackId/effectId verbatim to au.listPresets,
 *     with omitted effectId coming through as undefined (never a stray
 *     literal), and round-trips a stubbed response — including the
 *     `hasFactoryPresets:false` "publishes nothing" shape and the
 *     `source:"unlisted"` shape — unchanged
 *   - au_list_presets is read-only (registers via `server.registerTool`
 *     directly, the au_describe_params precedent): an unrecognized extra
 *     argument is silently stripped, not rejected
 *   - au_load_preset forwards trackId/effectId/presetNumber/presetName
 *     verbatim to au.loadPreset
 *   - au_load_preset's `presetNumber` schema has NO `minimum` — a NEGATIVE
 *     number (how a user preset is addressed) reaches the bridge intact,
 *     with zero schema rejection. This is the pin that protects the
 *     m23-cw brief's "do not add minimum: 0" against a future "hardening"
 *     pass that would make every user preset unreachable by number.
 *   - both presetNumber and presetName supplied, or neither, reach the
 *     bridge UNFILTERED — the XOR law lives in the DAW handler, not the
 *     MCP schema (the vc_convert_vocals clipId/path precedent)
 *   - au_load_preset is MUTATING (registers via the strict-schema wrapper,
 *     the au_set_param precedent): an unrecognized extra argument is
 *     rejected at the MCP boundary, before the bridge is ever called
 *   - a stubbed app-side error (the real HostedAUPresetError wording, e.g.
 *     `noPresets`) surfaces as an MCP tool error (isError: true) carrying
 *     the app's own message verbatim, never swallowed
 *   - each tool's description teaches the load-bearing, easy-to-flatten
 *     facts: `unlisted` is normal, the AU rewrites the preset name (so the
 *     read-back is authoritative), negative preset numbers are legal, an
 *     ambiguous name refusal names retry-by-number, and
 *     `hasFactoryPresets:false` is the MAJORITY path, not an edge case
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
  client = new Client({ name: "au-presets-test-client", version: "0.0.0" });
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
// au_list_presets
// ---------------------------------------------------------------------------

test("au_list_presets forwards trackId/effectId verbatim to au.listPresets and round-trips the result", async () => {
  const stubbedList = {
    trackId: TRACK_ID,
    effectId: EFFECT_ID,
    componentName: "AUMatrixReverb",
    supportsUserPresets: false,
    hasFactoryPresets: true,
    factoryPresets: [
      { number: 0, name: "Small Room" },
      { number: 8, name: "Cathedral" },
    ],
    userPresets: [{ number: -1, name: "My Patch" }],
    currentPreset: { number: 11, name: "Medium Hall 3", source: "factory" },
  };
  queuedResult = stubbedList;

  const result = await client.callTool({
    name: "au_list_presets",
    arguments: { trackId: TRACK_ID, effectId: EFFECT_ID },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "au.listPresets");
  assert.deepEqual(calls[0]!.params, { trackId: TRACK_ID, effectId: EFFECT_ID });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbedList, "the app's response round-trips back verbatim");
});

test("au_list_presets: omitted effectId comes through as undefined (targets the track's AU instrument)", async () => {
  queuedResult = {
    trackId: TRACK_ID,
    componentName: "SomeSynth",
    supportsUserPresets: false,
    hasFactoryPresets: false,
    factoryPresets: [],
    userPresets: [],
    currentPreset: null,
  };

  await client.callTool({ name: "au_list_presets", arguments: { trackId: TRACK_ID } });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { trackId: TRACK_ID, effectId: undefined });
});

test("au_list_presets round-trips the graceful-degradation shape (hasFactoryPresets:false, empty arrays, null currentPreset) as SUCCESS", async () => {
  const stubbedList = {
    trackId: TRACK_ID,
    componentName: "AUDelay",
    supportsUserPresets: false,
    hasFactoryPresets: false,
    factoryPresets: [],
    userPresets: [],
    currentPreset: null,
  };
  queuedResult = stubbedList;

  const result = await client.callTool({ name: "au_list_presets", arguments: { trackId: TRACK_ID } });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError, "a preset-less AU is a healthy host, not an error");
  assert.deepEqual(parseJSON(r), stubbedList);
});

test("au_list_presets round-trips the unlisted-current-preset shape (a project-reload restore, not corruption)", async () => {
  const stubbedList = {
    trackId: TRACK_ID,
    componentName: "AUMatrixReverb",
    supportsUserPresets: false,
    hasFactoryPresets: true,
    factoryPresets: [{ number: 8, name: "Cathedral" }],
    userPresets: [],
    currentPreset: { number: -1, name: "Cathedral", source: "unlisted" },
  };
  queuedResult = stubbedList;

  const result = await client.callTool({ name: "au_list_presets", arguments: { trackId: TRACK_ID } });

  assert.deepEqual(parseJSON(result as any).currentPreset, { number: -1, name: "Cathedral", source: "unlisted" });
});

test("au_list_presets requires trackId (rejected at the schema layer, zero bridge calls)", async () => {
  const result = await client.callTool({ name: "au_list_presets", arguments: {} });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "a missing required trackId must be rejected before the bridge call");
  assert.equal(calls.length, 0);
});

test("au_list_presets is read-only (server.registerTool directly, the au_describe_params precedent): an unrecognized argument is silently stripped, not rejected", async () => {
  queuedResult = {
    trackId: TRACK_ID,
    componentName: "SomeSynth",
    supportsUserPresets: false,
    hasFactoryPresets: false,
    factoryPresets: [],
    userPresets: [],
    currentPreset: null,
  };

  const result = await client.callTool({
    name: "au_list_presets",
    arguments: { trackId: TRACK_ID, bogus: true },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError, "read-only tools use a non-strict schema (m16-e scopes strictness to mutating tools)");
  assert.equal(calls.length, 1, "the call still reaches the bridge, with the unrecognized key stripped");
  assert.ok(!("bogus" in calls[0]!.params), "the stray key never reaches bridge.send");
});

test("au_list_presets surfaces a bridge-side error (e.g. the master-chain refusal) verbatim", async () => {
  queuedError = new Error(
    "the master chain hosts built-in effects only — AU parameters apply to track inserts"
  );

  const result = await client.callTool({ name: "au_list_presets", arguments: { trackId: "master" } });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /master chain hosts built-in effects only/);
});

// ---------------------------------------------------------------------------
// au_load_preset
// ---------------------------------------------------------------------------

test("au_load_preset forwards trackId/effectId/presetNumber verbatim to au.loadPreset and round-trips the post-load read-back", async () => {
  const stubbedLoad = {
    trackId: TRACK_ID,
    effectId: EFFECT_ID,
    componentName: "AUMatrixReverb",
    preset: { number: 8, name: "Cathedral", source: "factory" },
  };
  queuedResult = stubbedLoad;

  const result = await client.callTool({
    name: "au_load_preset",
    arguments: { trackId: TRACK_ID, effectId: EFFECT_ID, presetNumber: 8 },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "au.loadPreset");
  assert.deepEqual(calls[0]!.params, {
    trackId: TRACK_ID,
    effectId: EFFECT_ID,
    presetNumber: 8,
    presetName: undefined,
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbedLoad, "the app's post-load read-back round-trips verbatim");
});

test("au_load_preset forwards presetName verbatim when used instead of presetNumber", async () => {
  queuedResult = {
    trackId: TRACK_ID,
    componentName: "AUMatrixReverb",
    preset: { number: 8, name: "Cathedral", source: "factory" },
  };

  await client.callTool({ name: "au_load_preset", arguments: { trackId: TRACK_ID, presetName: "Cathedral" } });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, {
    trackId: TRACK_ID,
    effectId: undefined,
    presetNumber: undefined,
    presetName: "Cathedral",
  });
});

test("au_load_preset: a NEGATIVE presetNumber (a user preset) reaches the bridge intact — no `minimum` on the schema", async () => {
  queuedResult = { trackId: TRACK_ID, componentName: "SomePlugin", preset: { number: -1, name: "My Patch", source: "user" } };

  const result = await client.callTool({
    name: "au_load_preset",
    arguments: { trackId: TRACK_ID, presetNumber: -1 },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError, "a negative presetNumber must not be rejected at the schema boundary");
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params.presetNumber, -1, "the negative number reaches the bridge UNCHANGED");
});

test("au_load_preset: both presetNumber and presetName supplied reach the bridge unfiltered (the XOR law lives in the DAW handler, not the schema)", async () => {
  queuedError = new Error(
    "pass 'presetNumber' OR 'presetName', not both — they are two ways to name the same preset"
  );

  const result = await client.callTool({
    name: "au_load_preset",
    arguments: { trackId: TRACK_ID, presetNumber: 8, presetName: "Cathedral" },
  });

  assert.equal(calls.length, 1, "the schema does not pre-empt the both-supplied case; the app handler does");
  assert.deepEqual(calls[0]!.params, {
    trackId: TRACK_ID,
    effectId: undefined,
    presetNumber: 8,
    presetName: "Cathedral",
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /OR 'presetName', not both/);
});

test("au_load_preset: neither presetNumber nor presetName supplied still reaches the bridge, refused by the app", async () => {
  queuedError = new Error(
    "one of 'presetNumber' or 'presetName' is required — call au.listPresets to see what this plugin ships"
  );

  const result = await client.callTool({ name: "au_load_preset", arguments: { trackId: TRACK_ID } });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, {
    trackId: TRACK_ID,
    effectId: undefined,
    presetNumber: undefined,
    presetName: undefined,
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /call au\.listPresets/);
});

test("au_load_preset requires trackId (rejected at the schema layer, zero bridge calls)", async () => {
  const result = await client.callTool({ name: "au_load_preset", arguments: { presetNumber: 0 } });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.equal(calls.length, 0);
});

test("au_load_preset is MUTATING (the strict-schema wrapper, the au_set_param precedent): an unrecognized argument is rejected at the MCP boundary, never reaches the bridge", async () => {
  const result = await client.callTool({
    name: "au_load_preset",
    arguments: { trackId: TRACK_ID, presetNumber: 0, bogus: true },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an unrecognized key must be rejected before the bridge call");
  assert.equal(calls.length, 0, "the strict schema rejects before bridge.send is ever invoked");
});

test("au_load_preset surfaces the real noPresets refusal verbatim", async () => {
  queuedError = new Error(
    "this Audio Unit publishes no presets (no factory presets, no user presets) — set its parameters directly with au.describeParams/au.setParam, or open its own window with plugin.openUI"
  );

  const result = await client.callTool({ name: "au_load_preset", arguments: { trackId: TRACK_ID, presetNumber: 0 } });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /publishes no presets/);
  assert.match(r.content[0].text as string, /au\.describeParams\/au\.setParam/);
});

test("au_load_preset surfaces an ambiguousPresetName-style refusal verbatim, naming candidate numbers", async () => {
  queuedError = new Error(
    "preset name \"Default\" matches more than one preset (numbers 3, 17) — retry with presetNumber"
  );

  const result = await client.callTool({
    name: "au_load_preset",
    arguments: { trackId: TRACK_ID, presetName: "Default" },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /matches more than one preset/);
});

// ---------------------------------------------------------------------------
// Description content — the facts a calling agent would otherwise get wrong
// ---------------------------------------------------------------------------

test("au_list_presets' description teaches the graceful-degradation majority path and the number/source contract", async () => {
  const { tools } = await client.listTools();
  const tool = tools.find((t) => t.name === "au_list_presets");
  assert.ok(tool, "au_list_presets is registered");
  const description = tool!.description ?? "";
  assert.match(description, /15 of Apple's 23/, "names the measured majority-path ratio");
  assert.match(description, /hasFactoryPresets:false/, "names the success flag for a preset-less AU");
  assert.match(description, /unlisted/, "teaches the unlisted classification");
  assert.match(description, /Cathedral/, "gives the concrete unlisted-after-reload example");
  assert.match(description, />= 0/, "states the factory-preset sign contract");
  assert.match(description, /< 0/, "states the user-preset sign contract");
});

test("au_load_preset's description teaches the XOR requirement, negative numbers, name rewriting, and ambiguity retry", async () => {
  const { tools } = await client.listTools();
  const tool = tools.find((t) => t.name === "au_load_preset");
  assert.ok(tool, "au_load_preset is registered");
  const description = tool!.description ?? "";
  assert.match(description, /EXACTLY ONE/, "states the XOR requirement");
  assert.match(description, /NEGATIVE VALUES ARE LEGAL/, "states that negative preset numbers are legal");
  assert.match(description, /Medium Chamber/, "gives the measured name-rewrite example");
  assert.match(description, /read-back/i, "teaches that the response is a read-back, not an echo");
  assert.match(description, /retry with .*presetNumber/i, "tells the caller how to recover from an ambiguous name");
  assert.match(description, /au_list_presets/, "points the caller at au_list_presets first");
});
