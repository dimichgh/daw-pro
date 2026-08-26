/**
 * midi-control-map.test.ts — wiring coverage for the m28-knob MIDI-learn trio:
 * midi_get_control_map (read-only, direct registration), midi_set_control_map
 * and midi_learn_control (mutating, strict-schema wrapper).
 *
 * The clip-get-notes.test.ts stub-bridge pattern verbatim: monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive each
 * tool over an in-memory transport, and assert what actually goes on the wire.
 *
 * ⚠️ **THE HAZARD THIS FILE EXISTS FOR** is not an unknown key — `registerTool`
 * wraps every schema in `.strict()`, so a stray argument is already rejected at
 * the boundary. It is the OPPOSITE: **a key the DESCRIPTION advertises that the
 * SCHEMA omits**. That one fails silently — the model reads the description,
 * sends the key, `.strict()` throws, and the tool looks broken for a reason
 * nothing in the code names. So every key named in prose is round-tripped here
 * on the recorded bridge frame, and the description is asserted against the
 * schema's own key list rather than by eye.
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
  client = new Client({ name: "midi-control-map-test-client", version: "0.0.0" });
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

const STUB_MAP = {
  bindings: [
    { target: "breathPadAngle", controller: 74, sourceId: 42, inverted: false },
  ],
  targets: [
    {
      id: "breathPadAngle",
      name: "Breath pad — travel around the ring",
      summary: "Turns the pad's dot around the circle of effort gestures.",
      controller: 74,
      sourceId: 42,
    },
    {
      id: "breathPadRadius",
      name: "Breath pad — depth",
      summary: "Moves the pad's dot in and out.",
    },
  ],
  lastControlChange: { sourceId: 42, channel: 5, controller: 74, value: 96 },
  subscribed: true,
};

// ---------------------------------------------------------------------------
// midi_get_control_map
// ---------------------------------------------------------------------------

test("midi_get_control_map sends no params and round-trips the app's payload verbatim", async () => {
  queuedResult = STUB_MAP;

  const result = await client.callTool({ name: "midi_get_control_map", arguments: {} });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "midi.getControlMap");
  assert.deepEqual(calls[0]!.params, {}, "no params — the verb takes none");

  const parsed = parseJSON(result as any);
  assert.deepEqual(parsed, STUB_MAP, "including the catalogue and lastControlChange");
});

test("midi_get_control_map's description names the diagnostic and the not-saved caveat", async () => {
  const { tools } = await client.listTools();
  const tool = tools.find((t) => t.name === "midi_get_control_map");
  assert.ok(tool, "midi_get_control_map must be registered");
  const description = tool!.description ?? "";
  // Every field the payload carries is named, so an agent knows what it got.
  for (const key of [
    "bindings",
    "targets",
    "learningTarget",
    "lastControlChange",
    "subscribed",
  ]) {
    assert.ok(description.includes(key), `description must name \`${key}\``);
  }
  assert.ok(
    /not saved into the project|does not survive/i.test(description),
    "the map is machine setup, not song content — the description must say so"
  );
});

// ---------------------------------------------------------------------------
// midi_set_control_map
// ---------------------------------------------------------------------------

test("midi_set_control_map forwards the WHOLE bindings array verbatim, every advertised key included", async () => {
  queuedResult = STUB_MAP;
  const bindings = [
    { target: "breathPadAngle", controller: 74, sourceId: 42, inverted: true },
    { target: "breathPadRadius", controller: 71, channel: 3 },
  ];

  await client.callTool({ name: "midi_set_control_map", arguments: { bindings } });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "midi.setControlMap");
  assert.deepEqual(
    calls[0]!.params["bindings"],
    bindings,
    "target/controller/channel/sourceId/inverted all survive the schema"
  );
});

test("midi_set_control_map forwards [] — the documented way to clear the map", async () => {
  queuedResult = { bindings: [], targets: [], subscribed: false };

  await client.callTool({ name: "midi_set_control_map", arguments: { bindings: [] } });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params["bindings"], []);
});

test("midi_set_control_map bounds controller and channel at the MCP boundary — zero bridge calls", async () => {
  const tooHigh = await client.callTool({
    name: "midi_set_control_map",
    arguments: { bindings: [{ target: "breathPadAngle", controller: 200 }] },
  });
  assert.ok(tooHigh.isError, "controller 200 must be refused at the schema layer");

  const badChannel = await client.callTool({
    name: "midi_set_control_map",
    arguments: { bindings: [{ target: "breathPadAngle", controller: 74, channel: 99 }] },
  });
  assert.ok(badChannel.isError, "channel 99 must be refused at the schema layer");

  const fractional = await client.callTool({
    name: "midi_set_control_map",
    arguments: { bindings: [{ target: "breathPadAngle", controller: 74.5 }] },
  });
  assert.ok(fractional.isError, "a CC number is an integer");

  const missingTarget = await client.callTool({
    name: "midi_set_control_map",
    arguments: { bindings: [{ controller: 74 }] },
  });
  assert.ok(missingTarget.isError, "a binding with no target names nothing");

  assert.equal(calls.length, 0, "a schema refusal must never reach the app");
});

test("midi_set_control_map rejects an unrecognized argument before the bridge call", async () => {
  const result = await client.callTool({
    name: "midi_set_control_map",
    arguments: { bindings: [], mode: "absolute" },
  });
  assert.ok(result.isError, "the strict schema rejects an unrecognized key");
  assert.equal(calls.length, 0);
});

test("midi_set_control_map's description points at learn and names the absolute-only limit", async () => {
  const { tools } = await client.listTools();
  const tool = tools.find((t) => t.name === "midi_set_control_map");
  assert.ok(tool);
  const description = tool!.description ?? "";
  // ⚠️ THE REAL HAZARD: a key advertised in prose but missing from the schema.
  // Assert against the schema's OWN key list, not by eye.
  const schemaKeys = Object.keys(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ((tool!.inputSchema as any)?.properties?.bindings?.items?.properties ?? {}) as object
  );
  assert.deepEqual(
    schemaKeys.sort(),
    ["channel", "controller", "inverted", "sourceId", "target"],
    "the binding schema's keys"
  );
  for (const key of schemaKeys) {
    assert.ok(
      description.includes(key),
      `description names \`${key}\`, so the schema and the prose agree`
    );
  }
  assert.ok(
    /ABSOLUTE/.test(description),
    "an endless encoder will misbehave and the description must say so"
  );
  assert.ok(
    description.includes("midi_learn_control"),
    "with a human present, turning the knob beats looking a CC number up"
  );
  assert.ok(
    /not swallowed|still reaches/i.test(description),
    "a mapped CC still reaches armed tracks and takes — that must not be a surprise"
  );
});

// ---------------------------------------------------------------------------
// midi_learn_control
// ---------------------------------------------------------------------------

test("midi_learn_control forwards target alone, and cancel alone — never a fabricated pair", async () => {
  queuedResult = { ...STUB_MAP, learningTarget: "breathPadAngle", inputs: [], hint: "…" };

  await client.callTool({
    name: "midi_learn_control",
    arguments: { target: "breathPadAngle" },
  });
  assert.equal(calls[0]!.command, "midi.learnControl");
  assert.deepEqual(
    calls[0]!.params,
    { target: "breathPadAngle" },
    "cancel is OMITTED, not sent as false — the app distinguishes the two"
  );

  calls = [];
  await client.callTool({ name: "midi_learn_control", arguments: { cancel: true } });
  assert.deepEqual(calls[0]!.params, { cancel: true }, "target is omitted, not null");
});

test("midi_learn_control round-trips the hint and inputs the app sends back", async () => {
  const payload = {
    ...STUB_MAP,
    learningTarget: "breathPadRadius",
    inputs: [{ uniqueID: 42, name: "Keys", isVirtual: false, isOnline: true }],
    hint: "Learn is armed. Turn the knob you want on Breath pad — depth;",
  };
  queuedResult = payload;

  const result = await client.callTool({
    name: "midi_learn_control",
    arguments: { target: "breathPadRadius" },
  });
  assert.deepEqual(parseJSON(result as any), payload);
});

test("midi_learn_control surfaces the app's refusal verbatim", async () => {
  queuedError = new Error("'target' must be one of breathPadAngle, breathPadRadius");
  const result = (await client.callTool({
    name: "midi_learn_control",
    arguments: { target: "nope" },
  })) as { isError?: boolean; content: { type: string; text: string }[] };
  assert.equal(result.isError, true);
  assert.match(result.content[0]!.text, /breathPadAngle/);
});

test("midi_learn_control's description says it WAKES the MIDI system and that the first message wins", async () => {
  const { tools } = await client.listTools();
  const tool = tools.find((t) => t.name === "midi_learn_control");
  assert.ok(tool);
  const description = tool!.description ?? "";
  const schemaKeys = Object.keys(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ((tool!.inputSchema as any)?.properties ?? {}) as object
  );
  assert.deepEqual(schemaKeys.sort(), ["cancel", "target"]);
  for (const key of schemaKeys) {
    assert.ok(description.includes(key), `description must name \`${key}\``);
  }
  // The lazy-client hazard: a learn armed against a MIDI system that was never
  // started hears nothing, and "nothing happens" reads as a bug.
  assert.ok(
    /WAKES THE MIDI SYSTEM UP/.test(description),
    "the bring-up is why this is its own verb — say it"
  );
  assert.ok(
    /FIRST controller message wins/i.test(description),
    "every MIDI learn has this footgun; naming it is the mitigation"
  );
  assert.ok(
    description.includes("hint"),
    "the response's hint is how an agent reports 'nothing is plugged in'"
  );
});
