/**
 * modulation.test.ts — round-trip coverage for the nine `mod_*` tools
 * (m39-e's MCP mirror): mod_describe_kinds, mod_add_source, mod_set_source,
 * mod_remove_source, mod_add_route, mod_set_route_depth, mod_remove_route,
 * mod_set_macro, mod_describe.
 *
 * Same stub-bridge pattern as au-presets.test.ts/view-surface.test.ts:
 * monkeypatches `DawBridge.prototype.send` before any tool call runs, so
 * the REAL `McpServer` from `src/server.ts` is driven over an in-memory
 * transport with no live app required. Asserts:
 *   - each tool forwards its wire-exact param set verbatim to its `mod.*`
 *     command and round-trips a stubbed response unchanged
 *   - mod_describe_kinds/mod_describe are READ-ONLY (registered directly via
 *     `server.registerTool`, the fx_describe precedent — both take only
 *     OPTIONAL params): an unrecognized extra argument is silently stripped,
 *     not rejected
 *   - the other seven are MUTATING (the strict-schema wrapper): an
 *     unrecognized extra argument is rejected at the MCP boundary, before
 *     the bridge is ever called
 *   - the nested `target` (discriminated union) and `params` objects reject
 *     an unrecognized key INSIDE them too — the m30-c nested-strict-gap
 *     precedent, so this suite is this family's contribution to that class
 *   - descriptions carry the required-verbatim teaching: the §7.2.0 polarity
 *     convention (mod_add_source's `steps`/`pulseWidth`/`bipolar`,
 *     mod_add_route's `.volume`/`depth`), the §7.3 depth-law worked
 *     examples (mod_add_route, mod_set_route_depth), and `mod_describe_kinds`
 *     named in all eight sibling descriptions (the fx_describe precedent)
 *   - a stubbed app-side refusal (e.g. `modulationTargetUnsupported`) and a
 *     stubbed warning-bearing success both round-trip verbatim
 */

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { DawBridge } from "../src/bridge.js";

function findRoot(startDir: string): string {
  let dir = startDir;
  for (let i = 0; i < 8; i++) {
    if (existsSync(join(dir, "package.json")) && existsSync(join(dir, "src", "server.ts"))) return dir;
    dir = dirname(dir);
  }
  throw new Error(`Could not locate mcp-server/ from ${startDir}`);
}

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
  client = new Client({ name: "modulation-test-client", version: "0.0.0" });
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
const SOURCE_ID = "22222222-2222-4222-8222-222222222222";
const ROUTE_ID = "33333333-3333-4333-8333-333333333333";
const EFFECT_ID = "44444444-4444-4444-8444-444444444444";

// ---------------------------------------------------------------------------
// mod_describe_kinds
// ---------------------------------------------------------------------------

test("mod_describe_kinds takes no required params and forwards to mod.describeKinds with no arguments", async () => {
  const stubbed = {
    polarity: "a step of 0 is OPEN, a step of 1 is CLOSED",
    depthLaw: "depth 0.1 across 8.81 octaves is +/-0.88 octaves",
    limits: { sourcesPerStrip: 16, routesPerStrip: 64, stepsPerSequencer: 64 },
    kinds: [],
    targets: {},
  };
  queuedResult = stubbed;

  const result = await client.callTool({ name: "mod_describe_kinds", arguments: {} });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "mod.describeKinds");
  assert.deepEqual(calls[0]!.params, {});
  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("mod_describe_kinds is read-only (server.registerTool directly, the fx_describe precedent): an unrecognized argument is silently stripped, not rejected", async () => {
  queuedResult = { polarity: "", depthLaw: "", limits: {}, kinds: [], targets: {} };

  const result = await client.callTool({ name: "mod_describe_kinds", arguments: { bogus: true } });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError, "read-only tools use a non-strict schema");
  assert.equal(calls.length, 1);
  assert.ok(!("bogus" in calls[0]!.params));
});

// ---------------------------------------------------------------------------
// mod_add_source
// ---------------------------------------------------------------------------

test("mod_add_source forwards trackId/kind/params/name verbatim to mod.addSource", async () => {
  queuedResult = {
    sourceId: SOURCE_ID,
    source: { id: SOURCE_ID, kind: "lfo", name: "LFO 1", params: { kind: "lfo", rateHz: 2 } },
    warnings: [],
  };

  const result = await client.callTool({
    name: "mod_add_source",
    arguments: { trackId: TRACK_ID, kind: "lfo", params: { rateHz: 2 }, name: "LFO 1" },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "mod.addSource");
  assert.deepEqual(calls[0]!.params, { trackId: TRACK_ID, kind: "lfo", params: { rateHz: 2 }, name: "LFO 1" });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.equal((parseJSON(result as any) as any).sourceId, SOURCE_ID);
});

test("mod_add_source accepts the exact string \"master\" for trackId", async () => {
  queuedResult = { sourceId: SOURCE_ID, source: {}, warnings: [] };

  await client.callTool({ name: "mod_add_source", arguments: { trackId: "master", kind: "macro" } });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params.trackId, "master");
});

test("mod_add_source requires trackId and kind (rejected at the schema layer, zero bridge calls)", async () => {
  const result = await client.callTool({ name: "mod_add_source", arguments: { trackId: TRACK_ID } });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.equal(calls.length, 0);
});

test("mod_add_source rejects an unknown kind at the schema layer", async () => {
  const result = await client.callTool({
    name: "mod_add_source",
    arguments: { trackId: TRACK_ID, kind: "envelope" },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.equal(calls.length, 0);
});

test("mod_add_source is MUTATING (the strict-schema wrapper): an unrecognized TOP-LEVEL argument is rejected at the MCP boundary, never reaches the bridge", async () => {
  const result = await client.callTool({
    name: "mod_add_source",
    arguments: { trackId: TRACK_ID, kind: "lfo", bogus: true },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.equal(calls.length, 0);
});

test("mod_add_source rejects an unrecognized key INSIDE `params` (the m30-c nested-strict-gap precedent), never reaches the bridge", async () => {
  const result = await client.callTool({
    name: "mod_add_source",
    arguments: { trackId: TRACK_ID, kind: "lfo", params: { rateHz: 2, rateHertz: 2 } },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "a typo'd nested params key must be rejected, not silently stripped");
  assert.equal(calls.length, 0);
});

test("mod_add_source still accepts a legitimate stepSequencer `params.steps` array (no regression)", async () => {
  queuedResult = { sourceId: SOURCE_ID, source: {}, warnings: [] };

  const result = await client.callTool({
    name: "mod_add_source",
    arguments: { trackId: TRACK_ID, kind: "stepSequencer", params: { steps: [0, 1, 0, 1] } },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok(!(result as any).isError);
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params.params, { steps: [0, 1, 0, 1] });
});

test("mod_add_source surfaces a stubbed clamp warning verbatim", async () => {
  queuedResult = {
    sourceId: SOURCE_ID,
    source: { id: SOURCE_ID },
    warnings: ["modulationParamClamped: 'rateHz' was 99, clamped to 40 (range 0.01...40)."],
  };

  const result = await client.callTool({
    name: "mod_add_source",
    arguments: { trackId: TRACK_ID, kind: "lfo", params: { rateHz: 99 } },
  });

  const parsed = parseJSON(result as any);
  assert.match(parsed.warnings[0], /modulationParamClamped/);
});

// ---------------------------------------------------------------------------
// mod_set_source
// ---------------------------------------------------------------------------

test("mod_set_source forwards trackId/sourceId/params/name verbatim to mod.setSource", async () => {
  queuedResult = { source: { id: SOURCE_ID }, warnings: [] };

  await client.callTool({
    name: "mod_set_source",
    arguments: { trackId: TRACK_ID, sourceId: SOURCE_ID, params: { rateHz: 4 }, name: "Filter LFO" },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "mod.setSource");
  assert.deepEqual(calls[0]!.params, {
    trackId: TRACK_ID,
    sourceId: SOURCE_ID,
    params: { rateHz: 4 },
    name: "Filter LFO",
  });
});

test("mod_set_source requires trackId and sourceId", async () => {
  const result = await client.callTool({ name: "mod_set_source", arguments: { trackId: TRACK_ID } });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

test("mod_set_source surfaces a modulationSourceKindMismatch-style refusal verbatim", async () => {
  queuedError = new Error("mod.setMacro applies to a 'macro' source; this one is 'lfo'");

  const result = await client.callTool({
    name: "mod_set_source",
    arguments: { trackId: TRACK_ID, sourceId: SOURCE_ID, params: { value: 0.5 } },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /this one is 'lfo'/);
});

// ---------------------------------------------------------------------------
// mod_remove_source
// ---------------------------------------------------------------------------

test("mod_remove_source forwards trackId/sourceId and round-trips the CASCADE result", async () => {
  const stubbed = { removedSourceId: SOURCE_ID, removedRouteIds: [ROUTE_ID] };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "mod_remove_source",
    arguments: { trackId: TRACK_ID, sourceId: SOURCE_ID },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "mod.removeSource");
  assert.deepEqual(calls[0]!.params, { trackId: TRACK_ID, sourceId: SOURCE_ID });
  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("mod_remove_source is MUTATING: an unrecognized argument is rejected at the MCP boundary", async () => {
  const result = await client.callTool({
    name: "mod_remove_source",
    arguments: { trackId: TRACK_ID, sourceId: SOURCE_ID, bogus: true },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

// ---------------------------------------------------------------------------
// mod_add_route
// ---------------------------------------------------------------------------

test("mod_add_route forwards trackId/sourceId/target/depth/enabled verbatim to mod.addRoute", async () => {
  queuedResult = { routeId: ROUTE_ID, route: { id: ROUTE_ID }, warnings: [] };

  await client.callTool({
    name: "mod_add_route",
    arguments: {
      trackId: TRACK_ID,
      sourceId: SOURCE_ID,
      target: { type: "volume" },
      depth: -0.25,
      enabled: false,
    },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "mod.addRoute");
  assert.deepEqual(calls[0]!.params, {
    trackId: TRACK_ID,
    sourceId: SOURCE_ID,
    target: { type: "volume" },
    depth: -0.25,
    enabled: false,
  });
});

test("mod_add_route forwards an effectParam target verbatim, including effectId/param", async () => {
  queuedResult = { routeId: ROUTE_ID, route: {}, warnings: [] };

  await client.callTool({
    name: "mod_add_route",
    arguments: {
      trackId: TRACK_ID,
      sourceId: SOURCE_ID,
      target: { type: "effectParam", effectId: EFFECT_ID, param: "peak1GainDb" },
      depth: 0.3,
    },
  });

  assert.deepEqual(calls[0]!.params.target, { type: "effectParam", effectId: EFFECT_ID, param: "peak1GainDb" });
});

test("mod_add_route forwards an instrumentParam target verbatim (no effectId/sendId)", async () => {
  queuedResult = { routeId: ROUTE_ID, route: {}, warnings: [] };

  await client.callTool({
    name: "mod_add_route",
    arguments: {
      trackId: TRACK_ID,
      sourceId: SOURCE_ID,
      target: { type: "instrumentParam", param: "cutoffHz" },
      depth: 0.1,
    },
  });

  assert.deepEqual(calls[0]!.params.target, { type: "instrumentParam", param: "cutoffHz" });
});

test("mod_add_route accepts `depth` outside -1...1 at the schema layer (the wire clamps and warns; the schema must not pre-empt it)", async () => {
  queuedResult = {
    routeId: ROUTE_ID,
    route: { id: ROUTE_ID, depth: 1 },
    warnings: ["modulationDepthClamped: 'depth' was 3, clamped to 1 (range -1...1)."],
  };

  const result = await client.callTool({
    name: "mod_add_route",
    arguments: { trackId: TRACK_ID, sourceId: SOURCE_ID, target: { type: "volume" }, depth: 3 },
  });

  assert.equal(calls.length, 1, "an out-of-range depth must still reach the bridge for the wire to clamp");
  assert.equal(calls[0]!.params.depth, 3, "the RAW value reaches the bridge unchanged");
  const parsed = parseJSON(result as any);
  assert.match(parsed.warnings[0], /modulationDepthClamped/);
});

test("mod_add_route rejects an unrecognized key INSIDE `target` (the m30-c nested-strict-gap precedent), never reaches the bridge", async () => {
  const result = await client.callTool({
    name: "mod_add_route",
    arguments: {
      trackId: TRACK_ID,
      sourceId: SOURCE_ID,
      target: { type: "effectParam", effectId: EFFECT_ID, param: "mix", parm: "mix" },
      depth: 0.2,
    },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.equal(calls.length, 0);
});

test("mod_add_route requires trackId, sourceId, target and depth", async () => {
  const result = await client.callTool({
    name: "mod_add_route",
    arguments: { trackId: TRACK_ID, sourceId: SOURCE_ID },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

test("mod_add_route surfaces a modulationTargetUnsupported-style refusal verbatim, naming its reason", async () => {
  queuedError = new Error(
    "cannot modulate effectParam(eq, highPassSlopeDbPerOct) (discrete): filter order is a topology switch, not a continuum"
  );

  const result = await client.callTool({
    name: "mod_add_route",
    arguments: {
      trackId: TRACK_ID,
      sourceId: SOURCE_ID,
      target: { type: "effectParam", effectId: EFFECT_ID, param: "highPassSlopeDbPerOct" },
      depth: 0.5,
    },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /\(discrete\)/);
});

// ---------------------------------------------------------------------------
// mod_set_route_depth
// ---------------------------------------------------------------------------

test("mod_set_route_depth forwards trackId/routeId/depth/enabled verbatim to mod.setRouteDepth", async () => {
  queuedResult = { route: { id: ROUTE_ID, depth: 0.5, enabled: true }, warnings: [] };

  await client.callTool({
    name: "mod_set_route_depth",
    arguments: { trackId: TRACK_ID, routeId: ROUTE_ID, depth: 0.5, enabled: true },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "mod.setRouteDepth");
  assert.deepEqual(calls[0]!.params, { trackId: TRACK_ID, routeId: ROUTE_ID, depth: 0.5, enabled: true });
});

test("mod_set_route_depth: omitting both depth and enabled still reaches the bridge as a legal no-op call", async () => {
  queuedResult = { route: { id: ROUTE_ID }, warnings: [] };

  await client.callTool({ name: "mod_set_route_depth", arguments: { trackId: TRACK_ID, routeId: ROUTE_ID } });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { trackId: TRACK_ID, routeId: ROUTE_ID, depth: undefined, enabled: undefined });
});

// ---------------------------------------------------------------------------
// mod_remove_route
// ---------------------------------------------------------------------------

test("mod_remove_route forwards trackId/routeId and round-trips the result", async () => {
  queuedResult = { removedRouteId: ROUTE_ID };

  const result = await client.callTool({
    name: "mod_remove_route",
    arguments: { trackId: TRACK_ID, routeId: ROUTE_ID },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "mod.removeRoute");
  assert.deepEqual(calls[0]!.params, { trackId: TRACK_ID, routeId: ROUTE_ID });
  assert.deepEqual(parseJSON(result as any), { removedRouteId: ROUTE_ID });
});

// ---------------------------------------------------------------------------
// mod_set_macro
// ---------------------------------------------------------------------------

test("mod_set_macro forwards trackId/sourceId/value verbatim to mod.setMacro", async () => {
  queuedResult = { source: { id: SOURCE_ID, kind: "macro" }, warnings: [] };

  await client.callTool({
    name: "mod_set_macro",
    arguments: { trackId: TRACK_ID, sourceId: SOURCE_ID, value: 0.75 },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "mod.setMacro");
  assert.deepEqual(calls[0]!.params, { trackId: TRACK_ID, sourceId: SOURCE_ID, value: 0.75 });
});

test("mod_set_macro requires value (schema-rejected, zero bridge calls)", async () => {
  const result = await client.callTool({
    name: "mod_set_macro",
    arguments: { trackId: TRACK_ID, sourceId: SOURCE_ID },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

test("mod_set_macro surfaces a modulationSourceKindMismatch refusal naming the ACTUAL kind", async () => {
  queuedError = new Error("mod.setMacro applies to a 'macro' source; this one is 'lfo'");

  const result = await client.callTool({
    name: "mod_set_macro",
    arguments: { trackId: TRACK_ID, sourceId: SOURCE_ID, value: 0.5 },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /this one is 'lfo'/);
});

// ---------------------------------------------------------------------------
// mod_describe
// ---------------------------------------------------------------------------

test("mod_describe forwards trackId/atBeat verbatim to mod.describe and round-trips the effective block", async () => {
  const stubbed = {
    strips: [
      {
        trackId: TRACK_ID,
        sources: [],
        routes: [],
        effective: [{ routeId: ROUTE_ID, sourceValue: 1, baseValue: 1, modulatedValue: 0.2512 }],
        atBeat: 8,
        transport: "stopped",
      },
    ],
  };
  queuedResult = stubbed;

  const result = await client.callTool({ name: "mod_describe", arguments: { trackId: TRACK_ID, atBeat: 8 } });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "mod.describe");
  assert.deepEqual(calls[0]!.params, { trackId: TRACK_ID, atBeat: 8 });
  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("mod_describe with no arguments is a bare READ (both trackId and atBeat optional) and still reaches the wire", async () => {
  queuedResult = { strips: [] };

  const result = await client.callTool({ name: "mod_describe", arguments: {} });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok(!(result as any).isError);
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { trackId: undefined, atBeat: undefined });
});

test("mod_describe is read-only (server.registerTool directly): an unrecognized argument is silently stripped, not rejected", async () => {
  queuedResult = { strips: [] };

  const result = await client.callTool({ name: "mod_describe", arguments: { bogus: true } });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError);
  assert.equal(calls.length, 1);
  assert.ok(!("bogus" in calls[0]!.params));
});

// ---------------------------------------------------------------------------
// Description content — the two verbatim carries the brief requires, plus
// mod_describe_kinds named in all eight sibling descriptions
// ---------------------------------------------------------------------------

test("mod_add_source's description carries the §7.2.0 polarity convention verbatim on steps/pulseWidth/bipolar", async () => {
  const { tools } = await client.listTools();
  const tool = tools.find((t) => t.name === "mod_add_source");
  assert.ok(tool, "mod_add_source is registered");
  const description = tool!.description ?? "";
  const paramsSchema = (tool!.inputSchema as any).properties.params;
  const stepsDesc = paramsSchema.properties.steps.description as string;
  const pulseWidthDesc = paramsSchema.properties.pulseWidth.description as string;
  const bipolarDesc = paramsSchema.properties.bipolar.description as string;

  assert.match(stepsDesc, /\[0,1,0,1\]/, "steps teaches the downbeat-opening pattern");
  assert.match(stepsDesc, /closed-open-closed-open/, "steps names the closed/open convention");
  assert.match(stepsDesc, /OFFSET/i, "steps teaches offset, not level");
  assert.match(stepsDesc, /NEGATIVE depth/, "steps names the required negative depth");
  assert.match(pulseWidthDesc, /CLOSED fraction/, "pulseWidth names the closed-fraction convention");
  assert.match(bipolarDesc, /NEGATIVE.*depth|depth.*NEGATIVE/, "bipolar ties to the negative-depth idiom");
  assert.match(description, /mod_describe_kinds/, "names the discovery entry point");
});

test("mod_add_route's description carries the §7.2.0 polarity convention AND the §7.3 depth-law worked examples verbatim", async () => {
  const { tools } = await client.listTools();
  const tool = tools.find((t) => t.name === "mod_add_route");
  assert.ok(tool, "mod_add_route is registered");
  const description = tool!.description ?? "";

  // Polarity.
  assert.match(description, /\[1,0,1,0\]/, "states the default pattern");
  assert.match(description, /\[0,1,0,1\]/, "states the downbeat-opening inversion");
  assert.match(description, /CLOSED/);
  assert.match(description, /OFFSET/);
  assert.match(description, /NEGATIVE `depth`|NEGATIVE depth/);

  // Depth law worked examples.
  assert.match(description, /8\.81/, "the cutoffHz octave-span worked example");
  assert.match(description, /octave/i);
  assert.match(description, /±0\.25|\+\/-0\.25/, "the resonance worked example");
  assert.match(description, /±6 dB|\+\/-6 dB/, "the volume tremolo worked example");
  assert.match(description, /±1\.0|\+\/-1\.0/, "the pan full-depth worked example");

  // Refusal taxonomy.
  assert.match(description, /discrete/);
  assert.match(description, /hostedAudioUnit/);
  assert.match(description, /controlPlaneOnly/);
  assert.match(description, /noInstrument/);
  assert.match(description, /sendLevelUnsupported/);

  assert.match(description, /mod_describe_kinds/, "names the discovery entry point");
});

test("mod_set_route_depth's description repeats the depth law and names mod_describe_kinds", async () => {
  const { tools } = await client.listTools();
  const tool = tools.find((t) => t.name === "mod_set_route_depth");
  const description = tool!.description ?? "";
  assert.match(description, /NEGATIVE depth/);
  assert.match(description, /mod_describe_kinds/);
});

test("mod_describe_kinds is named in every one of the other eight tool descriptions", async () => {
  const { tools } = await client.listTools();
  const siblingNames = [
    "mod_add_source",
    "mod_set_source",
    "mod_remove_source",
    "mod_add_route",
    "mod_set_route_depth",
    "mod_remove_route",
    "mod_set_macro",
    "mod_describe",
  ];
  for (const name of siblingNames) {
    const tool = tools.find((t) => t.name === name);
    assert.ok(tool, `${name} is registered`);
    assert.match(tool!.description ?? "", /mod_describe_kinds/, `${name} names mod_describe_kinds`);
  }
});

test("mod_add_source's params schema teaches stepDivision works, the LFO syncDivision stays refused, and the envelope-follower's non-determinism", async () => {
  const { tools } = await client.listTools();
  const tool = tools.find((t) => t.name === "mod_add_source");
  const paramsSchema = (tool!.inputSchema as any).properties.params;
  const syncDesc = paramsSchema.properties.syncDivision.description as string;
  const stepSyncDesc = paramsSchema.properties.stepDivision.description as string;
  const rateDesc = paramsSchema.properties.rateHz.description as string;
  // The LFO refusal is kept, in plain words, with no internal ticket names.
  assert.match(syncDesc, /REFUSED/);
  assert.match(syncDesc, /modulationTempoSyncUnavailable/);
  assert.doesNotMatch(syncDesc, /m39-c|when sync lands/);
  // stepDivision is available and explained.
  assert.doesNotMatch(stepSyncDesc, /NOT AVAILABLE/);
  assert.match(stepSyncDesc, /stepDivision: "1\/16"/);
  assert.match(stepSyncDesc, /step 1 is always on the bar line/);
  assert.match(stepSyncDesc, /time-signature change/);
  assert.match(stepSyncDesc, /`rateHz` is unused/);
  assert.match(stepSyncDesc, /`null` to clear/);
  assert.match(rateDesc, /ignores it while `stepDivision` is set/);
  assert.doesNotMatch(rateDesc, /NOT AVAILABLE/);
  assert.match(tool!.description ?? "", /render history/, "envelopeFollower's non-determinism is taught");
  assert.match(tool!.description ?? "", /stepDivision/);
});

test("mod_set_source, mod_describe_kinds and mod_describe teach stepDivision and the tempoSync block", async () => {
  const { tools } = await client.listTools();
  const text = (name: string) => tools.find((t) => t.name === name)!.description ?? "";
  assert.match(text("mod_set_source"), /`stepDivision`/);
  assert.match(text("mod_set_source"), /`rateHz` is unused/);
  assert.match(text("mod_describe_kinds"), /`stepDivision` param lists every allowed note length in its `values`/);
  assert.match(text("mod_describe"), /`tempoSync` block/);
  for (const key of ["stepDivision", "stepsPerBar", "meter", "restart", "rateHzNote"]) {
    assert.match(text("mod_describe"), new RegExp(key), `mod_describe names tempoSync.${key}`);
  }
});

test("DRIFT: the stepDivision enum equals the Swift NoteDivision raw values, in the same order", async () => {
  const swift = readFileSync(
    join(findRoot(dirname(fileURLToPath(import.meta.url))), "..", "Sources", "DAWCore", "TempoMap.swift"),
    "utf8"
  );
  const block = swift.slice(swift.indexOf("public enum NoteDivision"));
  const body = block.slice(0, block.indexOf("public var beats"));
  const swiftValues = [...body.matchAll(/case\s+\w+\s*=\s*"([^"]+)"|,\s*\w+\s*=\s*"([^"]+)"/g)].map((m) => m[1] ?? m[2]);
  assert.equal(swiftValues.length, 18, "positive control: the scan found all 18 Swift divisions");
  const { tools } = await client.listTools();
  const tool = tools.find((t) => t.name === "mod_add_source");
  const field = (tool!.inputSchema as any).properties.params.properties.stepDivision;
  const values = (field.enum ?? field.anyOf?.find((b: any) => b.enum)?.enum).filter((v: unknown) => v !== null);
  assert.deepEqual(values, swiftValues);
});

test("the instrumentParam target's description states the automation-lane boundary and points at mod_add_route", async () => {
  const { tools } = await client.listTools();
  const tool = tools.find((t) => t.name === "mod_add_route");
  const targetSchema = (tool!.inputSchema as any).properties.target;
  const instrumentBranch = (targetSchema.anyOf as any[]).find(
    (branch) => branch.properties?.type?.const === "instrumentParam"
  );
  assert.ok(instrumentBranch, "the instrumentParam branch is present in the target union");
  const typeDesc = instrumentBranch.properties.type.description as string;
  assert.match(typeDesc, /automation_add_lane`? REFUSES/);
  assert.match(typeDesc, /instrument_describe_synth/);
});

test("the sendLevel target's description states it is REFUSED (sendLevelUnsupported)", async () => {
  const { tools } = await client.listTools();
  const tool = tools.find((t) => t.name === "mod_add_route");
  const targetSchema = (tool!.inputSchema as any).properties.target;
  const sendBranch = (targetSchema.anyOf as any[]).find((branch) => branch.properties?.type?.const === "sendLevel");
  assert.ok(sendBranch, "the sendLevel branch is present in the target union");
  assert.match(sendBranch.properties.type.description as string, /sendLevelUnsupported/);
});
