/**
 * fx-get-params.test.ts — wiring coverage for fx_get_params (m27-f).
 *
 * Stub-bridge pattern (fx-spectrum.test.ts): monkeypatch `DawBridge.prototype.send`
 * before importing the real server, drive the tool over an in-memory transport.
 * Asserts: exact forwarding to `fx.getParams` with only {trackId, effectId};
 * "master" passes verbatim; the reply round-trips verbatim; unknown keys are
 * rejected at the MCP boundary; a bridge refusal surfaces; and the description
 * teaches the replacement for the old no-op-bypass workaround.
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
  client = new Client({ name: "fx-get-params-test-client", version: "0.0.0" });
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
  assert.ok(first && first.type === "text", `expected text content, got: ${JSON.stringify(result.content)}`);
  return JSON.parse(first.text as string);
}

const CHAIN = {
  trackId: "track-1",
  effectId: "fx-1",
  effects: [
    { id: "fx-1", kind: "gain", isBypassed: false, params: { gainLinear: 2 }, latencySamples: 0 },
  ],
};

test("fx_get_params forwards exactly {trackId, effectId} to fx.getParams and returns the reply verbatim", async () => {
  queuedResult = CHAIN;
  const result = await client.callTool({
    name: "fx_get_params",
    arguments: { trackId: "track-1", effectId: "fx-1" },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "fx.getParams");
  assert.deepEqual(calls[0]!.params, { trackId: "track-1", effectId: "fx-1" });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), CHAIN);
});

test("fx_get_params passes \"master\" through verbatim", async () => {
  queuedResult = { ...CHAIN, trackId: "master" };
  await client.callTool({ name: "fx_get_params", arguments: { trackId: "master", effectId: "fx-1" } });
  assert.equal(calls[0]!.params.trackId, "master");
});

test("fx_get_params rejects an unrecognized key before the bridge", async () => {
  const result = await client.callTool({
    name: "fx_get_params",
    arguments: { trackId: "track-1", effectId: "fx-1", bypassed: false },
  });
  assert.equal(calls.length, 0, "an unknown key must never reach the bridge");
  assert.equal((result as { isError?: boolean }).isError, true);
});

test("fx_get_params requires both ids", async () => {
  const result = await client.callTool({ name: "fx_get_params", arguments: { trackId: "track-1" } });
  assert.equal(calls.length, 0);
  assert.equal((result as { isError?: boolean }).isError, true);
});

test("fx_get_params surfaces a bridge refusal verbatim", async () => {
  queuedError = new Error("No effect with id abc.");
  const result = await client.callTool({
    name: "fx_get_params",
    arguments: { trackId: "track-1", effectId: "abc" },
  });
  assert.equal((result as { isError?: boolean }).isError, true);
  assert.match(JSON.stringify(result), /No effect with id abc\./);
});

test("fx_get_params description teaches read-here, never toggle bypass to read", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "fx_get_params");
  assert.ok(tool, "fx_get_params must be listed");
  const d = tool!.description ?? "";
  assert.match(d, /never toggle bypass/i);
  assert.match(d, /undo/i);
  assert.match(d, /fx_describe/);
});
