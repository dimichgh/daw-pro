/**
 * fx-spectrum.test.ts — wiring coverage for fx_spectrum (m23-r4).
 *
 * The mixer-master-analysis.test.ts / au-params.test.ts stub-bridge pattern
 * verbatim: monkeypatch `DawBridge.prototype.send` before importing the real
 * `McpServer`, drive the tool over an in-memory transport, and assert:
 *   - the tool forwards exactly `fx.spectrum` with {trackId, effectId} and,
 *     when passed, `arm` — omitting `arm` sends NO `arm` key (the wire's own
 *     default-true, not a redundant client-side default)
 *   - "master" passes through verbatim as `trackId` (no client-side rewrite)
 *   - the app's response round-trips verbatim, including `armed`, `tapPoint`,
 *     `leaseSeconds` riding alongside the mixer_master_analysis-shaped fields
 *   - this is a MUTATING tool (arms/renews/releases a lease) registered
 *     through the m16-e strict wrapper: trackId/effectId are required, and
 *     an unrecognized key is rejected AT THE MCP BOUNDARY, never reaching
 *     the bridge
 *   - a bridge-side refusal (e.g. the cap-full message) surfaces verbatim
 *   - the tool description teaches tapPoint, the lease, and the poll-rate
 *     guidance — the agent's only manual for this tool
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
  client = new Client({ name: "fx-spectrum-test-client", version: "0.0.0" });
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

const STUBBED_SNAPSHOT = {
  bands: Array.from({ length: 24 }, () => -40),
  levelDB: -12.25,
  peakDB: -6.5,
  centroidHz: 1024,
  flux: 0.4375,
  correlation: -0.5,
  width: 0.75,
  balance: 0.125,
  armed: true,
  tapPoint: "postInsertPreFader",
  leaseSeconds: 3,
};

test("fx_spectrum forwards trackId/effectId to fx.spectrum, leaving `arm` undefined when not passed", async () => {
  queuedResult = STUBBED_SNAPSHOT;

  const result = await client.callTool({
    name: "fx_spectrum",
    arguments: { trackId: "track-1", effectId: "eq-1" },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "fx.spectrum");
  // `arm: undefined` (not an absent key) is this codebase's own convention
  // for an omitted optional param (au-params.test.ts:277) — `JSON.stringify`
  // drops it at the real wire boundary in `bridge.ts`, downstream of this
  // stub, so the wire's own default-true (not a redundant client-side one)
  // is still what actually reaches the app.
  assert.deepEqual(
    calls[0]!.params,
    { trackId: "track-1", effectId: "eq-1", arm: undefined },
    "omitting arm leaves it undefined here; JSON.stringify drops it before it reaches the wire"
  );
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const parsed = parseJSON(result as any);
  assert.deepEqual(parsed, STUBBED_SNAPSHOT, "the app's response round-trips verbatim");
  assert.equal(parsed.armed, true);
  assert.equal(parsed.tapPoint, "postInsertPreFader");
  assert.equal(parsed.leaseSeconds, 3);
});

test("fx_spectrum forwards arm:false verbatim, and \"master\" passes through as trackId unchanged", async () => {
  queuedResult = {
    bands: Array.from({ length: 24 }, () => -80),
    levelDB: -80,
    peakDB: -80,
    centroidHz: 0,
    flux: 0,
    correlation: 1,
    width: 0,
    balance: 0,
    armed: false,
    tapPoint: "postInsertPostFader",
    leaseSeconds: 3,
  };

  const result = await client.callTool({
    name: "fx_spectrum",
    arguments: { trackId: "master", effectId: "limiter-1", arm: false },
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { trackId: "master", effectId: "limiter-1", arm: false });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const parsed = parseJSON(result as any);
  assert.equal(parsed.armed, false);
  assert.equal(parsed.tapPoint, "postInsertPostFader", "a master insert reads postInsertPostFader");
});

test("fx_spectrum requires trackId and effectId (rejected at the schema layer, zero bridge calls)", async () => {
  for (const arguments_ of [{}, { trackId: "t" }, { effectId: "e" }]) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const result = (await client.callTool({ name: "fx_spectrum", arguments: arguments_ as any })) as any;
    assert.ok(result.isError, `expected a schema error for ${JSON.stringify(arguments_)}`);
  }
  assert.equal(calls.length, 0);
});

test("fx_spectrum rejects an unrecognized argument at the MCP boundary (never reaches the bridge, m16-e)", async () => {
  const result = await client.callTool({
    name: "fx_spectrum",
    arguments: { trackId: "t", effectId: "e", bogus: true },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an unrecognized key must be rejected before the bridge call");
  assert.equal(calls.length, 0, "the strict schema rejects before bridge.send is ever invoked");
});

test("fx_spectrum surfaces a bridge-side refusal (e.g. the cap-full message) verbatim", async () => {
  queuedError = new Error(
    "too many spectrum taps — at most 8 inserts can be measured at once; release one with " +
      "fx.spectrum {arm:false} (or close an EQ card) and retry"
  );

  const result = await client.callTool({
    name: "fx_spectrum",
    arguments: { trackId: "t", effectId: "e" },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /at most 8 inserts/);
  assert.match(r.content[0].text as string, /release/);
});

test("fx_spectrum description teaches tapPoint (pre/post fader), the 3s lease, and the poll-rate guidance", async () => {
  const tools = await client.listTools();
  const tool = tools.tools.find((t) => t.name === "fx_spectrum");
  assert.ok(tool, "fx_spectrum is registered");
  const description = tool!.description ?? "";
  assert.match(description, /tapPoint/, "teaches the tapPoint field");
  assert.match(description, /postInsertPreFader/, "names the strip-insert tap point");
  assert.match(description, /postInsertPostFader/, "names the master-insert tap point");
  assert.match(description, /before.*fader/i, "explains the strip insert is measured BEFORE the fader");
  assert.match(description, /after.*fader/i, "explains the master insert is measured AFTER the fader");
  assert.match(description, /3.second/i, "states the lease length");
  assert.match(description, /5-30 ?hz|poll/i, "gives poll-rate guidance");
  assert.match(description, /8 inserts|at most 8/, "names the cap");
  assert.match(description, /mixer_master_analysis/, "points at mixer_master_analysis for field meaning, one home for that copy");
});
