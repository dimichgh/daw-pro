/**
 * playbox-generate.test.ts — wiring coverage for playbox_generate
 * (m34-g: the AI produces the INVITATION, the human produces the PERFORMANCE).
 *
 * The chord-voice.test.ts pattern verbatim: monkeypatch `DawBridge.prototype
 * .send` before importing the real `McpServer`, drive the tool over an in-memory
 * transport, and assert the forwarding, the Zod bounds, and the verbatim
 * round-trip.
 *
 * ⛔⛔ AND TWO THINGS THAT ARE NOT WIRING, PINNED HERE BECAUSE NOTHING ELSE CAN
 * SEE THEM:
 *
 *   1. The DESCRIPTION must keep telling an agent NOT to play the progression
 *      for the user. The whole value of this feature is that the take is
 *      genuinely theirs — played on the keys, captured through the ordinary live
 *      path. An agent that helpfully followed this call with clip_set_notes
 *      would have deleted the feature while appearing to complete it.
 *   2. The description must keep explaining `source: ai | local`. "The AI wrote
 *      this" and "we picked a stock progression" are different claims and only
 *      one of them is true at a time; an agent that reported the first for the
 *      second would be taking credit the fallback did not earn.
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
  client = new Client({ name: "playbox-test-client", version: "0.0.0" });
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

test("playbox_generate forwards to playbox.generate and round-trips the answer", async () => {
  const stubbed = {
    degrees: [1, 5, 6, 4],
    name: "Playbox",
    source: "ai",
    detail: "anthropic",
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "playbox_generate",
    arguments: { keyTonic: 0, bars: 4 },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "playbox.generate");
  assert.deepEqual(calls[0]!.params, {
    keyTonic: 0,
    keyMode: undefined,
    bars: 4,
    tempoBPM: undefined,
    section: undefined,
    style: undefined,
    preferLocal: undefined,
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("every optional parameter is forwarded when given", async () => {
  queuedResult = { degrees: [1, 6, 3, 7], name: "Playbox", source: "local", detail: "Minor Rock" };
  await client.callTool({
    name: "playbox_generate",
    arguments: {
      keyTonic: 9,
      keyMode: "minor",
      bars: 8,
      tempoBPM: 92,
      section: "Chorus",
      style: "dreamy indie",
      preferLocal: true,
    },
  });
  assert.deepEqual(calls[0]!.params, {
    keyTonic: 9,
    keyMode: "minor",
    bars: 8,
    tempoBPM: 92,
    section: "Chorus",
    style: "dreamy indie",
    preferLocal: true,
  });
});

test("takes no arguments at all — every parameter is optional", async () => {
  queuedResult = { degrees: [1, 5, 6, 4], name: "Playbox", source: "local", detail: "Four Chords" };
  await client.callTool({ name: "playbox_generate", arguments: {} });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "playbox.generate");
});

test("the local-fallback answer round-trips its source, detail and reason", async () => {
  const stubbed = {
    degrees: [6, 4, 1, 5],
    name: "Four Chords variation",
    source: "local",
    detail: "Four Chords",
    reason: "No AI provider is configured for chord-progression.",
  };
  queuedResult = stubbed;
  const result = await client.callTool({ name: "playbox_generate", arguments: {} });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const parsed = parseJSON(result as any);
  assert.equal(parsed.source, "local");
  assert.equal(parsed.detail, "Four Chords");
  assert.ok(parsed.reason.length > 0, "the fallback says WHY it ran");
});

// ── Zod bounds reject at the MCP BOUNDARY, never at the app ─────────────────

test("bars outside 2-16 is rejected at the boundary and never reaches the bridge", async () => {
  for (const bars of [1, 17, 4.5]) {
    const result = await client.callTool({
      name: "playbox_generate",
      arguments: { bars },
    });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.equal((result as any).isError, true, `bars=${bars} should be refused`);
  }
  assert.equal(calls.length, 0, "no bridge call was made for any of them");
});

test("an unknown keyMode is rejected at the boundary", async () => {
  const result = await client.callTool({
    name: "playbox_generate",
    arguments: { keyMode: "lydian" },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.equal((result as any).isError, true);
  assert.equal(calls.length, 0);
});

test("an unrecognized argument is rejected at the boundary (never reaches the bridge)", async () => {
  const result = await client.callTool({
    name: "playbox_generate",
    arguments: { degrees: [1, 5, 6, 4] },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.equal((result as any).isError, true);
  assert.equal(calls.length, 0);
});

test("an app-side refusal surfaces verbatim", async () => {
  queuedError = new Error("keyMode must be one of: major, minor — got 'phrygian'");
  const result = await client.callTool({ name: "playbox_generate", arguments: {} });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.equal((result as any).isError, true);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const text = (result as any).content[0].text as string;
  assert.ok(text.includes("major, minor"), `expected the app's own wording, got: ${text}`);
});

// ── ⛔⛔ The description is load-bearing ─────────────────────────────────────

test("⛔⛔ the description tells an agent NOT to play the progression for the user", async () => {
  const { tools } = await client.listTools();
  const tool = tools.find((t) => t.name === "playbox_generate");
  assert.ok(tool, "playbox_generate is registered");
  const description = tool!.description ?? "";
  assert.ok(
    /INVITATION/.test(description),
    "the inversion must be stated: the agent invites, the human performs"
  );
  assert.ok(
    /clip_set_notes/.test(description) && /deletes the entire value/.test(description),
    "it must name the specific helpful-looking action that would destroy the feature"
  );
  assert.ok(
    /READ-ONLY AND SILENT/.test(description),
    "it lights nothing, sounds nothing, records nothing"
  );
});

test("⛔ the description explains source: ai vs local, so credit is never misreported", async () => {
  const { tools } = await client.listTools();
  const description =
    tools.find((t) => t.name === "playbox_generate")?.description ?? "";
  assert.ok(/WITHOUT AN API KEY/.test(description), "the no-key story is stated");
  assert.ok(/`source`/.test(description) && /`local`/.test(description));
  assert.ok(
    /rather than crediting the AI for a stock progression/.test(description),
    "the honesty instruction is explicit, not implied"
  );
});

test("the description says CHORDS ONLY rather than half-promising melody", async () => {
  const { tools } = await client.listTools();
  const description =
    tools.find((t) => t.name === "playbox_generate")?.description ?? "";
  assert.ok(/CHORDS ONLY/.test(description));
  assert.ok(/out of scope/.test(description));
});
