/**
 * automation-master.test.ts — round-trip coverage for the m15-c master volume
 * automation sentinel on the EXISTING automation_* tools (no new tools; the
 * MCP tool count is pinned at 123 by audit-tools.test.ts).
 *
 * Same stub-bridge pattern as clip-time-range.test.ts / copilot.test.ts: unlike
 * integration.test.ts (real spawned DAWApp + real control WebSocket), this suite
 * monkeypatches `DawBridge.prototype.send` before any tool call runs, so the REAL
 * `McpServer` from `src/server.ts` is driven over an in-memory transport with no
 * live app required. Asserts:
 *   - each automation_* tool ACCEPTS the exact literal `trackId: "master"` (the
 *     m13-d fx.* sentinel pattern: these tools validate `trackId` as
 *     `z.string().min(1)`, so "master" passes the MCP schema and forwards
 *     verbatim to the control-protocol verb the app resolves) — the master
 *     param-relax proof at the MCP layer
 *   - a stubbed success (`{lane: ...}`) round-trips back through the tool
 *   - the app-side volume-only teaching error surfaces as an MCP tool error
 *     (isError: true), message verbatim — the schema accepts a `pan` target on
 *     "master" (the discriminated union has no master awareness); the STORE is
 *     what rejects it, and that error must pass through unswallowed
 *   - an empty `trackId` is rejected at the MCP schema layer itself (`.min(1)`),
 *     an isError result with ZERO bridge calls (the clip-time-range rejection
 *     precedent)
 */

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { DawBridge } from "../src/bridge.js";

// ---------------------------------------------------------------------------
// Stub the bridge BEFORE any tool call runs (the clip-time-range.test.ts note:
// `new DawBridge()` at server.ts module scope does no networking, so patching
// the prototype here intercepts every server-wide call, DAW-app-free).
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
  client = new Client({ name: "automation-master-test-client", version: "0.0.0" });
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

const MASTER_LANE = {
  id: randomUUID(),
  target: { type: "volume" },
  points: [
    { beat: 0, value: 1, curve: "linear" },
    { beat: 16, value: 0, curve: "linear" },
  ],
  isEnabled: true,
};

// ---------------------------------------------------------------------------
// "master" literal accepted + forwarded verbatim on every automation_* tool
// ---------------------------------------------------------------------------

test("automation_add_lane accepts trackId 'master' and forwards it verbatim to automation.addLane", async () => {
  queuedResult = { lane: MASTER_LANE };

  const result = await client.callTool({
    name: "automation_add_lane",
    arguments: { trackId: "master", target: { type: "volume" } },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "automation.addLane");
  assert.deepEqual(calls[0]!.params, { trackId: "master", target: { type: "volume" } });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), { lane: MASTER_LANE }, "the app's lane round-trips back verbatim");
});

test("automation_set_points accepts trackId 'master' and forwards the whole-array replace verbatim", async () => {
  const laneId = MASTER_LANE.id;
  const points = [
    { beat: 0, value: 1 },
    { beat: 16, value: 0 },
  ];
  queuedResult = { lane: MASTER_LANE };

  const result = await client.callTool({
    name: "automation_set_points",
    arguments: { trackId: "master", laneId, points },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "automation.setPoints");
  assert.deepEqual(calls[0]!.params, { trackId: "master", laneId, points });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok(!(result as any).isError, "a legal master setPoints call is not rejected client-side");
});

test("automation_set_lane_enabled accepts trackId 'master' and forwards the toggle verbatim", async () => {
  const laneId = MASTER_LANE.id;
  queuedResult = { lane: { ...MASTER_LANE, isEnabled: false } };

  await client.callTool({
    name: "automation_set_lane_enabled",
    arguments: { trackId: "master", laneId, enabled: false },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "automation.setLaneEnabled");
  assert.deepEqual(calls[0]!.params, { trackId: "master", laneId, enabled: false });
});

test("automation_remove_lane accepts trackId 'master' and forwards it verbatim", async () => {
  const laneId = MASTER_LANE.id;
  queuedResult = { ok: true };

  await client.callTool({
    name: "automation_remove_lane",
    arguments: { trackId: "master", laneId },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "automation.removeLane");
  assert.deepEqual(calls[0]!.params, { trackId: "master", laneId });
});

// ---------------------------------------------------------------------------
// The schema accepts a pan target on "master"; the STORE rejects it — that
// teaching error must surface unswallowed (the discriminated union has no
// master awareness, so this rejection is app-side, not client-side).
// ---------------------------------------------------------------------------

test("a non-volume target on master surfaces the app's volume-only teaching error verbatim", async () => {
  queuedError = new Error(
    "master automation supports the volume target only in v1 — pan, sendLevel, and " +
      "effectParam lanes live on tracks (pass a track UUID)"
  );

  const result = await client.callTool({
    name: "automation_add_lane",
    arguments: { trackId: "master", target: { type: "pan" } },
  });

  // The MCP schema accepted the pan target and forwarded it — the app is what
  // refuses it, so exactly one bridge call was made before the error.
  assert.equal(calls.length, 1, "the pan target passes the MCP schema and reaches the app");
  assert.equal(calls[0]!.command, "automation.addLane");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(
    r.content[0].text as string,
    /master automation supports the volume target only in v1/,
    "the app's actionable teaching error passes through verbatim"
  );
});

// ---------------------------------------------------------------------------
// An empty trackId is rejected at the MCP schema layer (.min(1)) — isError,
// zero bridge calls (the clip-time-range client-side-rejection precedent).
// ---------------------------------------------------------------------------

test("an empty trackId is rejected at the MCP schema layer, no bridge call", async () => {
  const result = await client.callTool({
    name: "automation_add_lane",
    arguments: { trackId: "", target: { type: "volume" } },
  });

  assert.equal(calls.length, 0, "a schema-invalid trackId never reaches the bridge");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError, "an empty trackId is a client-side schema rejection");
});
