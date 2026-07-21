/**
 * clip-fit-to-content.test.ts — wiring coverage for clip_fit_to_content
 * (m21-d: fit a clip's length to its content in one call).
 *
 * The clip-time-range.test.ts pattern verbatim: monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive the
 * tool over an in-memory transport, and assert:
 *   - the tool forwards exactly `clip.fitToContent {trackId, clipId}`
 *   - the app's response (updated clip + `changed` flag) round-trips verbatim
 *   - the strict wrapper rejects unknown arguments at the MCP boundary
 *   - an app-side error surfaces as an MCP tool error, message verbatim
 */

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

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
  client = new Client({ name: "clip-fit-to-content-test-client", version: "0.0.0" });
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

test("clip_fit_to_content forwards {trackId, clipId} to clip.fitToContent and returns the clip + changed flag", async () => {
  const trackId = randomUUID();
  const clipId = randomUUID();
  const stubbed = {
    id: clipId,
    name: "AI Riff",
    startBeat: 1,
    lengthBeats: 2.37,
    notes: [{ id: randomUUID(), pitch: 64, velocity: 100, startBeat: 1.5, lengthBeats: 0.87 }],
    changed: true,
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_fit_to_content",
    arguments: { trackId, clipId },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "clip.fitToContent");
  assert.deepEqual(calls[0]!.params, { trackId, clipId });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed, "the app's response (incl. `changed`) round-trips verbatim");
});

test("clip_fit_to_content rejects an unrecognized argument at the MCP boundary (never reaches the bridge)", async () => {
  const result = await client.callTool({
    name: "clip_fit_to_content",
    arguments: { trackId: randomUUID(), clipId: randomUUID(), lengthBeats: 2 },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError, "the strict wrapper must reject unknown keys");
  assert.equal(calls.length, 0, "a rejected call never reaches the bridge");
});

test("clip_fit_to_content surfaces an app-side error as an MCP tool error, message verbatim", async () => {
  queuedError = new Error(
    "clip belongs to take group 'Vocals' — edit the comp (take.setComp) or take.flatten first"
  );

  const result = await client.callTool({
    name: "clip_fit_to_content",
    arguments: { trackId: randomUUID(), clipId: randomUUID() },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.fitToContent");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /take group/, "the app's teaching message passes through verbatim");
});
