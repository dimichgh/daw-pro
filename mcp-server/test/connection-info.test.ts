/**
 * connection-info.test.ts — round-trip coverage for app_connection_info (m10-l).
 *
 * Same stub-bridge pattern as clip-time-range.test.ts (the m10-h precedent):
 * unlike integration.test.ts (real spawned DAWApp + real control WebSocket),
 * this suite monkeypatches `DawBridge.prototype.send` before any tool call
 * runs, so the REAL `McpServer` from `src/server.ts` is driven over an
 * in-memory transport (the audit-tools.test.ts precedent) with no live app
 * required. Asserts:
 *   - the tool takes no params and forwards exactly `app.connectionInfo`
 *     with no arguments
 *   - a stubbed success result round-trips back through the tool unchanged
 *     (including each of the three `source` values the app can report)
 *   - a stubbed app-side error surfaces as an MCP tool error (isError: true)
 *     carrying the app's own message verbatim, never swallowed — even
 *     though the real command never throws, the wire-level contract still
 *     holds if the bridge itself fails (e.g. app not running)
 */

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { DawBridge } from "../src/bridge.js";

// ---------------------------------------------------------------------------
// Stub the bridge BEFORE any tool call runs (see clip-time-range.test.ts for
// why patching the prototype here is safe and server-wide).
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
  client = new Client({ name: "connection-info-test-client", version: "0.0.0" });
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

// ---------------------------------------------------------------------------
// app_connection_info
// ---------------------------------------------------------------------------

test("app_connection_info takes no params and forwards to app.connectionInfo with no arguments", async () => {
  const stubbedInfo = {
    url: "ws://127.0.0.1:17600",
    port: 17600,
    source: "default",
    defaultPort: 17600,
  };
  queuedResult = stubbedInfo;

  const result = await client.callTool({ name: "app_connection_info", arguments: {} });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "app.connectionInfo");
  assert.deepEqual(calls[0]!.params, {}, "no arguments are forwarded — this command takes no params");

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbedInfo, "the app's response round-trips back verbatim");
});

for (const source of ["environment", "settings", "default"] as const) {
  test(`app_connection_info round-trips a "${source}"-sourced endpoint unchanged`, async () => {
    const stubbedInfo = {
      url: source === "default" ? "ws://127.0.0.1:17600" : "ws://127.0.0.1:9090",
      port: source === "default" ? 17600 : 9090,
      source,
      defaultPort: 17600,
    };
    queuedResult = stubbedInfo;

    const result = await client.callTool({ name: "app_connection_info", arguments: {} });

    assert.equal(calls.length, 1);
    assert.equal(calls[0]!.command, "app.connectionInfo");
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const r = result as any;
    assert.ok(!r.isError, "a healthy stubbed response is never a tool error");
    assert.deepEqual(parseJSON(r), stubbedInfo);
  });
}

test("app_connection_info surfaces a bridge-side error as an MCP tool error, message verbatim", async () => {
  queuedError = new Error("app not running — start DAW Pro or run `swift run DAWApp`");

  const result = await client.callTool({ name: "app_connection_info", arguments: {} });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "app.connectionInfo");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "a bridge-side failure must be a tool error, never a silent success");
  assert.match(
    r.content[0].text as string,
    /app not running/,
    "the actionable error message passes through verbatim"
  );
});
