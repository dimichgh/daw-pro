/**
 * mixer-master-analysis.test.ts — wiring coverage for mixer_master_analysis
 * (M8 vm-a snapshot + the m22-d additive stereo-image keys).
 *
 * The mixer-live-loudness.test.ts stub-bridge pattern verbatim: monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive the
 * tool over an in-memory transport, and assert:
 *   - the tool forwards exactly `mixer.masterAnalysis` with no params
 *   - the app's snapshot round-trips verbatim INCLUDING the m22-d
 *     correlation / width / balance keys (additive on the same response)
 *   - the floor shape is honest: correlation +1 (silence holds nothing out
 *     of phase — never a fabricated 0), width 0, balance 0
 *   - the tool description teaches the stereo-image semantics and the
 *     phase/mono-problem use case (that text is the agent's only manual)
 *   - read-only poll ⇒ non-strict schema: stray arguments are stripped,
 *     not rejected (m16-e scopes strictness to mutating tools)
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
  client = new Client({ name: "mixer-master-analysis-test-client", version: "0.0.0" });
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

test("mixer_master_analysis forwards to mixer.masterAnalysis and round-trips the snapshot including the m22-d stereo keys", async () => {
  const stubbed = {
    bands: Array.from({ length: 24 }, () => -40),
    levelDB: -12.25,
    peakDB: -6.5,
    centroidHz: 1024,
    flux: 0.4375,
    correlation: -0.5,
    width: 0.75,
    balance: 0.125,
  };
  queuedResult = stubbed;

  const result = await client.callTool({ name: "mixer_master_analysis", arguments: {} });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "mixer.masterAnalysis");
  assert.deepEqual(calls[0]!.params, {}, "a no-param poll sends no params");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const parsed = parseJSON(result as any);
  assert.deepEqual(parsed, stubbed, "the app's snapshot round-trips verbatim");
  assert.equal(parsed.correlation, -0.5, "the m22-d correlation key rides the same response");
  assert.equal(parsed.width, 0.75);
  assert.equal(parsed.balance, 0.125);
});

test("mixer_master_analysis: the floor shape carries the documented stereo floors (correlation +1, never a fake 0)", async () => {
  const stubbed = {
    bands: Array.from({ length: 24 }, () => -80),
    levelDB: -80,
    peakDB: -80,
    centroidHz: 0,
    flux: 0,
    correlation: 1,
    width: 0,
    balance: 0,
  };
  queuedResult = stubbed;

  const result = await client.callTool({ name: "mixer_master_analysis", arguments: {} });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const parsed = parseJSON(result as any);
  assert.equal(parsed.correlation, 1, "silence holds nothing out of phase: floor is +1");
  assert.equal(parsed.width, 0, "silent image is mono-width");
  assert.equal(parsed.balance, 0, "silent image is centered");
});

test("mixer_master_analysis description teaches correlation/width/balance and the mono-compatibility use case", async () => {
  const tools = await client.listTools();
  const tool = tools.tools.find((t) => t.name === "mixer_master_analysis");
  assert.ok(tool, "mixer_master_analysis is registered");
  const description = tool!.description ?? "";
  assert.match(description, /correlation/, "teaches the correlation key");
  assert.match(description, /width/, "teaches the width key");
  assert.match(description, /balance/, "teaches the balance key");
  assert.match(description, /mono/i, "teaches the mono-compatibility use case");
  assert.match(description, /CANCEL/i, "warns about anti-phase cancellation");
});

test("mixer_master_analysis is a read-only poll: an unrecognized argument is silently stripped, not rejected", async () => {
  queuedResult = { bands: [], levelDB: -80, peakDB: -80, centroidHz: 0, flux: 0, correlation: 1, width: 0, balance: 0 };

  const result = await client.callTool({
    name: "mixer_master_analysis",
    arguments: { bogus: 1 },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError, "read-only tools use a non-strict schema (m16-e scopes strictness to mutating tools)");
  assert.equal(calls.length, 1, "the call still reaches the bridge, with the unrecognized key stripped");
  assert.ok(!("bogus" in calls[0]!.params), "the stray key never reaches bridge.send");
});
