/**
 * pad-preview-effort.test.ts — wiring coverage for pad_preview_effort
 * (breath pad P6: the live drag preview, gesture-scoped).
 *
 * The note-audition.test.ts pattern verbatim (its sibling verb: both "sound
 * something now, outside the timeline, not an edit"): monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive the
 * tool over an in-memory transport, and assert:
 *   - the tool forwards exactly `pad.previewEffort {trackId, gesture, value,
 *     expressionCC}` — checked on the RECORDED BRIDGE FRAME, which is the only
 *     place a key advertised by the description but missing from the schema
 *     shows up (the server.ts:4418 hazard)
 *   - every key the DESCRIPTION names is actually IN the schema. The `.strict()`
 *     wrapper REJECTS unknown keys rather than stripping them, so the failure
 *     mode is a caller who reads the description, passes the key, and gets a
 *     hard error for doing what they were told
 *   - the Zod bounds and the gesture enum reject at the MCP boundary, never at
 *     the app
 *   - `delivered:false` and `audible:false` + `reason` are REAL ANSWERS and must
 *     not become tool errors
 *   - an app-side gesture refusal surfaces verbatim
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
  client = new Client({ name: "pad-preview-test-client", version: "0.0.0" });
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

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function padTool(): Promise<any> {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "pad_preview_effort");
  assert.ok(tool, "pad_preview_effort must be registered");
  return tool;
}

test("a whole gesture forwards begin/move/end verbatim on the recorded bridge frame", async () => {
  const trackId = randomUUID();

  queuedResult = {
    trackId,
    gesture: "begin",
    controller: 11,
    controllerValue: 64,
    value: 0.5,
    streaming: true,
    delivered: true,
    audible: true,
  };
  await client.callTool({
    name: "pad_preview_effort",
    arguments: { trackId, gesture: "begin", value: 0.5 },
  });

  queuedResult = { ...(queuedResult as object), gesture: "move", controllerValue: 102, value: 0.8 };
  await client.callTool({
    name: "pad_preview_effort",
    arguments: { trackId, gesture: "move", value: 0.8 },
  });

  queuedResult = {
    trackId,
    gesture: "end",
    controller: 11,
    controllerValue: 127,
    streaming: false,
    delivered: true,
    audible: true,
  };
  await client.callTool({ name: "pad_preview_effort", arguments: { trackId, gesture: "end" } });

  assert.equal(calls.length, 3, "one bridge call per gesture phase");
  assert.deepEqual(calls.map((c) => c.command), [
    "pad.previewEffort",
    "pad.previewEffort",
    "pad.previewEffort",
  ]);
  assert.deepEqual(calls[0]!.params, {
    trackId,
    gesture: "begin",
    value: 0.5,
    expressionCC: undefined,
  });
  assert.deepEqual(calls[1]!.params, {
    trackId,
    gesture: "move",
    value: 0.8,
    expressionCC: undefined,
  });
  // `end` legitimately carries no value: the app restores neutral.
  assert.deepEqual(calls[2]!.params, {
    trackId,
    gesture: "end",
    value: undefined,
    expressionCC: undefined,
  });
});

test("expressionCC rides the bridge frame when the caller passes it", async () => {
  const trackId = randomUUID();
  queuedResult = {
    trackId,
    gesture: "begin",
    controller: 74,
    controllerValue: 127,
    value: 1,
    streaming: true,
    delivered: true,
    audible: true,
  };

  const result = await client.callTool({
    name: "pad_preview_effort",
    arguments: { trackId, gesture: "begin", value: 1, expressionCC: 74 },
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { trackId, gesture: "begin", value: 1, expressionCC: 74 });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.equal(parseJSON(result as any).controller, 74);
});

test("every key the DESCRIPTION advertises is present in the SCHEMA", async () => {
  // THE server.ts:4418 HAZARD, machine-checked. `.strict()` REJECTS unknown
  // keys rather than stripping them, so a key named in prose but missing from
  // the schema is a hard error for any caller who believes the prose.
  const tool = await padTool();
  const schemaKeys = new Set(Object.keys(tool.inputSchema.properties ?? {}));
  const described = ["trackId", "gesture", "value", "expressionCC"];
  for (const key of described) {
    assert.ok(
      schemaKeys.has(key),
      `the description names \`${key}\` but the schema omits it — a caller who ` +
        `follows the description gets a strict-mode rejection`
    );
    assert.ok(
      (tool.description as string).includes(key) ||
        JSON.stringify(tool.inputSchema).includes(key),
      `\`${key}\` should be discoverable from the tool surface`
    );
  }
  assert.deepEqual(
    [...schemaKeys].sort(),
    [...described].sort(),
    "the schema and the described key set must be EQUAL, not merely overlapping"
  );
  // The rule the tool exists to enforce must be stated where an agent reads it.
  const description = tool.description as string;
  assert.match(description, /gesture/i);
  assert.match(description, /neutral/i);
  assert.match(description, /not an edit|PREVIEW, not an edit/i);
});

test("the Zod bounds and the gesture enum reject at the MCP boundary (never reaching the bridge)", async () => {
  const trackId = randomUUID();
  const bad: Array<Record<string, unknown>> = [
    { trackId }, // no gesture
    { trackId, gesture: "start", value: 0.5 }, // not one of begin/move/end
    { trackId, gesture: "begin", value: 1.5 }, // above the effort range
    { trackId, gesture: "begin", value: -0.1 }, // below it
    { trackId, gesture: "begin", value: 0.5, expressionCC: 128 },
    { trackId, gesture: "begin", value: 0.5, expressionCC: -1 },
    { trackId, gesture: "begin", value: 0.5, expressionCC: 11.5 }, // not an integer
    { trackId, gesture: "begin", value: 0.5, effort: 0.5 }, // unknown key: strict REJECTS
  ];

  for (const args of bad) {
    const result = await client.callTool({ name: "pad_preview_effort", arguments: args });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.ok((result as any).isError, `expected a boundary rejection for ${JSON.stringify(args)}`);
  }
  assert.equal(calls.length, 0, "no rejected call ever reached the bridge");
});

test("delivered:false and audible:false + reason are REAL ANSWERS, not tool errors", async () => {
  const trackId = randomUUID();
  const stubbed = {
    trackId,
    gesture: "move",
    controller: 11,
    controllerValue: 90,
    value: 0.71,
    streaming: true,
    delivered: false,
    audible: false,
    reason: "instrumentNotReady",
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "pad_preview_effort",
    arguments: { trackId, gesture: "move", value: 0.71 },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError, "a coalesced or inaudible preview is a successful call");
  assert.deepEqual(parseJSON(r), stubbed);
});

test("an app-side gesture refusal surfaces as an MCP tool error, message verbatim", async () => {
  queuedError = new Error(
    "no pad gesture is open — send gesture 'begin' before 'move'. The pad streams ONLY " +
      "while a gesture is in progress, so that playback, replay and a bounce always agree"
  );

  const result = await client.callTool({
    name: "pad_preview_effort",
    arguments: { trackId: randomUUID(), gesture: "move", value: 0.4 },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "pad.previewEffort");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side refusal must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /no pad gesture is open/);
});
