/**
 * transport-end-stop.test.ts — round-trip coverage for
 * transport_set_stop_at_content_end (m25-d): "when playback reaches the point
 * past which there are no more clips, stop".
 *
 * Same stub-bridge pattern as vc.test.ts: `DawBridge.prototype.send` is
 * monkeypatched before any tool call runs, so the REAL `McpServer` from
 * `src/server.ts` is driven over an in-memory transport with no live app.
 * Asserts:
 *   - the tool forwards exactly `transport.setStopAtContentEnd` with the one
 *     `enabled` boolean, both ways
 *   - the app's `{stopAtContentEnd, contentEndBeat}` shape round-trips verbatim
 *   - `enabled` is REQUIRED and an unrecognized argument is rejected at the MCP
 *     boundary, never reaching the bridge (the m16-e strict-schema convention)
 *   - an app-side error surfaces as an MCP tool error, message verbatim
 *   - the description teaches the two carve-outs a user can be bitten by
 *     (recording never stops; looping wins) and the snapshot omit-at-default
 *     inversion
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
  client = new Client({ name: "end-stop-test-client", version: "0.0.0" });
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
  assert.ok(
    first && first.type === "text",
    `expected a text content item, got: ${JSON.stringify(result.content)}`
  );
  return JSON.parse(first.text as string);
}

test("forwards enabled:false to transport.setStopAtContentEnd and round-trips the app's shape", async () => {
  const stubbed = { stopAtContentEnd: false, contentEndBeat: 96 };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "transport_set_stop_at_content_end",
    arguments: { enabled: false },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "transport.setStopAtContentEnd");
  assert.deepEqual(calls[0]!.params, { enabled: false });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed, "the app's response round-trips verbatim");
});

test("forwards enabled:true — the default state is settable back explicitly", async () => {
  queuedResult = { stopAtContentEnd: true, contentEndBeat: 0 };

  await client.callTool({
    name: "transport_set_stop_at_content_end",
    arguments: { enabled: true },
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { enabled: true });
});

test("enabled is REQUIRED — rejected at the MCP boundary, never reaches the bridge", async () => {
  const result = await client.callTool({
    name: "transport_set_stop_at_content_end",
    arguments: {},
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.equal((result as any).isError, true);
  assert.equal(calls.length, 0, "a schema rejection must never reach the app");
});

test("an unrecognized argument is rejected at the MCP boundary, never reaches the bridge", async () => {
  const result = await client.callTool({
    name: "transport_set_stop_at_content_end",
    arguments: { enabled: true, stopAtEnd: true },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.equal((result as any).isError, true);
  assert.equal(calls.length, 0, "a strict-schema rejection must never reach the app");
});

test("a non-boolean enabled is rejected at the MCP boundary", async () => {
  const result = await client.callTool({
    name: "transport_set_stop_at_content_end",
    arguments: { enabled: "yes" },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.equal((result as any).isError, true);
  assert.equal(calls.length, 0);
});

test("an app-side error surfaces as an MCP tool error with the message verbatim", async () => {
  queuedError = new Error("app not running — start DAW Pro or run `swift run DAWApp`");

  const result = await client.callTool({
    name: "transport_set_stop_at_content_end",
    arguments: { enabled: false },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const asAny = result as any;
  assert.equal(asAny.isError, true);
  assert.match(asAny.content[0].text as string, /app not running/);
});

test("the description teaches the recording carve-out, loop precedence, and the snapshot's different key NAME", async () => {
  const { tools } = await client.listTools();
  const tool = tools.find((t) => t.name === "transport_set_stop_at_content_end");
  assert.ok(tool, "transport_set_stop_at_content_end is registered");
  const description = tool!.description ?? "";

  // The two carve-outs that would otherwise look like bugs to an agent.
  assert.match(description, /recording/i);
  assert.match(description, /loop/i);
  // NOT a polarity convention to memorise — a different key NAME. An agent
  // that greps project_snapshot for `stopAtContentEnd` finds nothing and must
  // be told where the setting actually lives. The absent-key reading of
  // `runsPastContentEnd` is self-evidently correct once it has the name.
  assert.match(description, /runsPastContentEnd/);
});
