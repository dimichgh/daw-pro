/**
 * chord-voice.test.ts — wiring coverage for chord_voice
 * (m23-cv: work out well-voiced chord notes; READ-ONLY, sounds nothing).
 *
 * The note-play.test.ts pattern verbatim: monkeypatch `DawBridge.prototype.send`
 * before importing the real `McpServer`, drive the tool over an in-memory
 * transport, and assert:
 *   - the tool forwards exactly `chord.voice` with the parameters it was given
 *   - the answer round-trips verbatim
 *   - the Zod bounds (degrees 1-7, octaveShift -4..4, the preset and mode enums,
 *     pitches 0-127) reject at the MCP BOUNDARY, never at the app
 *   - an app-side refusal surfaces verbatim
 *
 * ⛔⛔ AND ONE THING THAT IS NOT WIRING, PINNED HERE BECAUSE NOTHING ELSE CAN SEE
 * IT: the DESCRIPTION must keep saying this tool is read-only and must keep
 * naming the bass preset's single-note behaviour as deliberate. The deliverable
 * of m23-cv is the on-screen one-key chord button; the user ruled explicitly
 * against "an agent can already do it over the wire" as a substitute for a
 * manual surface in this exact cluster. A description that grew into "use this
 * to play chords" would be re-shipping the thing that was declined.
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
  client = new Client({ name: "chord-voice-test-client", version: "0.0.0" });
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

test("chord_voice forwards degrees to chord.voice and round-trips the answer", async () => {
  const stubbed = {
    key: "C",
    keyPitchClass: 0,
    mode: "major",
    preset: "piano",
    density: "triad",
    chords: [
      { symbol: "C", quality: "major", degree: 1, numeral: "I", pitches: [48, 60, 64, 67] },
      { symbol: "G", quality: "major", degree: 5, numeral: "V", pitches: [43, 59, 62, 67] },
    ],
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "chord_voice",
    arguments: { key: "C", degrees: [1, 5] },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "chord.voice");
  assert.deepEqual(calls[0]!.params, {
    key: "C",
    mode: undefined,
    degrees: [1, 5],
    chords: undefined,
    preset: undefined,
    density: undefined,
    previousVoicing: undefined,
    octaveShift: undefined,
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("every optional parameter is forwarded when given", async () => {
  queuedResult = { chords: [] };
  await client.callTool({
    name: "chord_voice",
    arguments: {
      key: 7,
      mode: "minor",
      chords: ["Am7", "F#m", "G7"],
      preset: "pad",
      density: "seventh",
      previousVoicing: [60, 64, 67],
      octaveShift: -1,
    },
  });
  assert.deepEqual(calls[0]!.params, {
    key: 7,
    mode: "minor",
    degrees: undefined,
    chords: ["Am7", "F#m", "G7"],
    preset: "pad",
    density: "seventh",
    previousVoicing: [60, 64, 67],
    octaveShift: -1,
  });
});

test("a numeric key and a note-name key are both accepted at the boundary", async () => {
  queuedResult = { chords: [] };
  await client.callTool({ name: "chord_voice", arguments: { key: 0, degrees: [1] } });
  await client.callTool({ name: "chord_voice", arguments: { key: "F#", degrees: [1] } });
  assert.equal(calls.length, 2);
  assert.equal(calls[0]!.params.key, 0);
  assert.equal(calls[1]!.params.key, "F#");
});

test("out-of-range degrees are rejected at the MCP boundary and never reach the app", async () => {
  const result = await client.callTool({
    name: "chord_voice",
    arguments: { degrees: [8] },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError, "a degree above 7 must be refused");
  assert.equal(calls.length, 0, "the app must never see it");
});

test("an out-of-range octaveShift and an unknown preset are both refused at the boundary", async () => {
  const shift = await client.callTool({
    name: "chord_voice",
    arguments: { degrees: [1], octaveShift: 9 },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((shift as any).isError);
  const preset = await client.callTool({
    name: "chord_voice",
    arguments: { degrees: [1], preset: "theremin" },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((preset as any).isError);
  assert.equal(calls.length, 0, "neither may reach the app");
});

test("an unrecognized argument is rejected at the MCP boundary (the strict wrapper)", async () => {
  const result = await client.callTool({
    name: "chord_voice",
    arguments: { degrees: [1], tempo: 120 },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

test("the app's refusal surfaces verbatim rather than being reworded", async () => {
  queuedError = new Error(
    "could not read the chord 'H7b9#11' — write a root then a quality, one of: " +
      "(nothing) m dim aug maj7 m7 7 m7b5 sus4. For example C, Am, F#m7, G7, Bdim, Csus4"
  );
  const result = await client.callTool({
    name: "chord_voice",
    arguments: { chords: ["H7b9#11"] },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const asAny = result as any;
  assert.ok(asAny.isError);
  assert.match(asAny.content[0].text as string, /H7b9#11/);
  assert.match(asAny.content[0].text as string, /m7b5/);
});

test("the description keeps this tool READ-ONLY and keeps the bass answer honest", async () => {
  const { tools } = await client.listTools();
  const tool = tools.find((t) => t.name === "chord_voice");
  assert.ok(tool, "chord_voice is not registered");
  const text = (tool.description ?? "") as string;
  // ⛔ READ-ONLY, said in the description where an agent will actually read it.
  assert.match(text, /READ-ONLY AND SILENT/);
  assert.match(text, /plays\s+nothing, records nothing, edits no clip/);
  // ⭐ The two things that make the tool worth having, named so a later edit
  // cannot quietly reduce it to "returns some notes".
  assert.match(text, /NEAREST-TONE VOICE LEADING/);
  assert.match(text, /LOW-INTERVAL LIMITS/);
  // ⭐ The user's own question, answered in the tool text: a bass plays the
  // root only, and that is deliberate.
  assert.match(text, /SINGLE ROOT NOTE PER CHORD/);
  assert.match(text, /deliberate, not a limitation/);
  // ⛔ AND IT MUST NOT ADVERTISE ITSELF AS A WAY TO PLAY. note_play is that.
  assert.doesNotMatch(text, /use this to play chords/i);
});
