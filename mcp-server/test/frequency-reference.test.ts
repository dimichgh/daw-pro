/**
 * frequency-reference.test.ts — wiring coverage for frequency_reference
 * (m23-o1: the instrument frequency reference table —
 * design-m23o1-instrument-frequency-reference.md §6/§8.3).
 *
 * The fx-spectrum.test.ts / note-audition.test.ts stub-bridge pattern
 * verbatim: monkeypatch `DawBridge.prototype.send` before importing the real
 * `McpServer`, drive the tool over an in-memory transport, and assert:
 *   - the tool forwards exactly `frequency.reference` with {family, trackId,
 *     note}, `undefined` when a param is omitted (the wire's own
 *     rejectUnknownKeys allow-list, not a client-side default)
 *   - the app's response round-trips verbatim (resolved, drumKit, unresolved,
 *     and index shapes alike — this tool does not interpret the payload)
 *   - all three params are OPTIONAL at the schema layer — a bare call reaches
 *     the bridge with every param undefined, never a schema error
 *   - `note` is bounded 0-127 integer; an unrecognized key is rejected AT THE
 *     MCP BOUNDARY (the m16-e strict wrapper), never reaching the bridge
 *   - an app-side refusal (e.g. an unknown `family` value) surfaces verbatim
 *   - the tool description teaches how to ACT on a recommendation
 *     (fx_set_param / highPassFreq / highPassSlopeDbPerOct) — per design
 *     §8.3 M3, deleting this from the description is half the item undone
 *   - the MCP schema is `z.string()` for `family`, never `z.enum` (design
 *     §8.3's deliberate asymmetry: the vocabulary rides in every response,
 *     so an older MCP server must never reject a family the app supports)
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
  client = new Client({ name: "frequency-reference-test-client", version: "0.0.0" });
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

test("frequency_reference with no arguments forwards frequency.reference with every param undefined", async () => {
  const stubbed = {
    resolution: "index",
    families: [{ family: "kick", displayName: "Kick drum", notes: [35, 36] }],
  };
  queuedResult = stubbed;

  const result = await client.callTool({ name: "frequency_reference", arguments: {} });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "frequency.reference");
  assert.deepEqual(calls[0]!.params, { family: undefined, trackId: undefined, note: undefined });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed, "the index response round-trips verbatim");
});

test("frequency_reference forwards family verbatim, leaving trackId/note undefined", async () => {
  const stubbed = {
    resolution: "family",
    resolvedFrom: "argument",
    reference: { family: "electricBass", displayName: "Electric bass guitar" },
    families: [],
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "frequency_reference",
    arguments: { family: "electricBass" },
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { family: "electricBass", trackId: undefined, note: undefined });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("frequency_reference forwards trackId + note verbatim", async () => {
  const stubbed = {
    resolution: "family",
    resolvedFrom: "gmPercussionNote",
    reference: { family: "snare", displayName: "Snare drum" },
    families: [],
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "frequency_reference",
    arguments: { trackId: "track-1", note: 38 },
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { family: undefined, trackId: "track-1", note: 38 });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("frequency_reference: unresolved and drumKit shapes round-trip verbatim too (this tool never interprets the payload)", async () => {
  const unresolved = {
    resolution: "unresolved",
    reason: "audioTrackHasNoInstrument",
    explanation: "This is a recorded audio track...",
    remedy: "Call frequency.reference again with `family`...",
    families: [{ family: "kick", displayName: "Kick drum", notes: [35, 36] }],
  };
  queuedResult = unresolved;
  let result = await client.callTool({
    name: "frequency_reference",
    arguments: { trackId: "track-2" },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), unresolved);

  const drumKit = {
    resolution: "drumKit",
    coveredNotes: [{ note: 36, name: "Bass Drum 1", family: "kick" }],
    families: [],
  };
  queuedResult = drumKit;
  result = await client.callTool({ name: "frequency_reference", arguments: { trackId: "track-3" } });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), drumKit);
});

test("frequency_reference rejects `note` outside 0-127 or non-integer at the schema layer (zero bridge calls)", async () => {
  const bad: Array<Record<string, unknown>> = [
    { note: -1 },
    { note: 128 },
    { note: 60.5 },
    { note: "38" },
  ];
  for (const args of bad) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const result = (await client.callTool({ name: "frequency_reference", arguments: args as any })) as any;
    assert.ok(result.isError, `expected a schema error for ${JSON.stringify(args)}`);
  }
  assert.equal(calls.length, 0, "no rejected call ever reached the bridge");
});

test("frequency_reference rejects an unrecognized argument at the MCP boundary (never reaches the bridge, m16-e)", async () => {
  const result = await client.callTool({
    name: "frequency_reference",
    arguments: { family: "kick", bogus: true },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an unrecognized key must be rejected before the bridge call");
  assert.equal(calls.length, 0, "the strict schema rejects before bridge.send is ever invoked");
});

test("frequency_reference surfaces an app-side refusal (e.g. an unknown family value) verbatim", async () => {
  queuedError = new Error(
    "unknown 'family' value 'bass' — valid ids are acousticGuitar, crashCymbal, electricBass, " +
      "electricGuitar, femaleVocal, hiHat, kick, maleVocal, piano, rideCymbal, snare, tom, uprightBass"
  );

  const result = await client.callTool({
    name: "frequency_reference",
    arguments: { family: "bass" },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /unknown 'family' value 'bass'/);
  assert.match(r.content[0].text as string, /valid ids are/);
});

test("frequency_reference description teaches how to ACT on a recommendation (fx_set_param / highPassFreq / highPassSlopeDbPerOct)", async () => {
  const tools = await client.listTools();
  const tool = tools.tools.find((t) => t.name === "frequency_reference");
  assert.ok(tool, "frequency_reference is registered");
  const description = tool!.description ?? "";
  assert.match(description, /fx_set_param/, "names the tool to act with");
  assert.match(description, /highPassFreq/, "names the corner param");
  assert.match(description, /highPassSlopeDbPerOct/, "names the slope param");
  assert.match(description, /families/, "teaches the always-present families index");
  assert.match(description, /unresolved/, "teaches the honest-failure resolution");
});

test("frequency_reference's `family` schema is a plain string, not a closed enum (design §8.3's deliberate asymmetry)", async () => {
  const tools = await client.listTools();
  const tool = tools.tools.find((t) => t.name === "frequency_reference");
  assert.ok(tool);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const familySchema = (tool!.inputSchema as any)?.properties?.family;
  assert.ok(familySchema, "family is present in the input schema");
  assert.equal(familySchema.type, "string");
  assert.equal(
    familySchema.enum,
    undefined,
    "family must stay z.string() — a z.enum would be a second, separately-shipped " +
      "source of truth for the family vocabulary and would REJECT a family the app supports"
  );

  // A value the Swift-side enum does not know about must still reach the
  // bridge (the app is the sole authority on validity) rather than being
  // rejected at the MCP boundary.
  queuedResult = { resolution: "index", families: [] };
  const result = await client.callTool({
    name: "frequency_reference",
    arguments: { family: "totallyMadeUpFamily" },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok(!(result as any).isError);
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params.family, "totallyMadeUpFamily");
});
