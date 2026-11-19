/**
 * drum-pattern-tools.test.ts — W9-PATM (m39-w4-10 MCP leg): `pattern_list` and
 * `clip_add_drum_pattern` map to `pattern.list` / `clip.addDrumPattern`, the
 * schema rejects unknown keys like the wire does, and the refusal sentences
 * are QUOTED in the descriptions (text pins). The bounce-in-place description
 * names the song-changed refusal verbatim.
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

DawBridge.prototype.send = async function (
  command: string,
  params: Record<string, unknown> = {}
): Promise<unknown> {
  calls.push({ command, params });
  return {};
};

const { server } = await import("../src/server.js");
let client: Client;

before(async () => {
  const [c, s] = InMemoryTransport.createLinkedPair();
  client = new Client({ name: "drum-pattern-test-client", version: "0.0.0" });
  await Promise.all([server.connect(s), client.connect(c)]);
});
after(async () => {
  await client?.close();
});
beforeEach(() => {
  calls = [];
});

/** The params as the bridge serialises them: JSON drops `undefined`. */
function wire(params: Record<string, unknown>): unknown {
  return JSON.parse(JSON.stringify(params));
}

async function description(name: string): Promise<string> {
  const { tools } = await client.listTools();
  const tool = tools.find((t) => t.name === name);
  assert.ok(tool, `${name} is registered`);
  return tool!.description ?? "";
}

test("pattern_list maps to pattern.list with no params", async () => {
  const r = (await client.callTool({ name: "pattern_list", arguments: {} })) as any;
  assert.ok(!r.isError);
  assert.deepStrictEqual(calls, [{ command: "pattern.list", params: {} }]);
});

test("clip_add_drum_pattern maps to clip.addDrumPattern and forwards only what was given", async () => {
  const trackId = randomUUID();
  const r = (await client.callTool({
    name: "clip_add_drum_pattern",
    arguments: { trackId, pattern: "basicRock", bars: 4, atBeat: 16 },
  })) as any;
  assert.ok(!r.isError);
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.addDrumPattern");
  // What goes on the wire: JSON drops the `undefined` keys the tool leaves for what was not given.
  assert.deepStrictEqual(wire(calls[0]!.params), { trackId, pattern: "basicRock", bars: 4, atBeat: 16 });
});

test("clip_add_drum_pattern schema: required keys, unknown keys, bars and atBeat bounds", async () => {
  const trackId = randomUUID();
  const bad: Array<Record<string, unknown>> = [
    { pattern: "trap" }, // trackId missing
    { trackId }, // pattern missing
    { trackId, pattern: "trap", swing: 0.5 }, // unknown key
    { trackId, pattern: "trap", bars: 0 },
    { trackId, pattern: "trap", bars: 65 },
    { trackId, pattern: "trap", bars: 1.5 },
    { trackId, pattern: "trap", atBeat: -1 },
  ];
  for (const args of bad) {
    const r = (await client.callTool({ name: "clip_add_drum_pattern", arguments: args })) as any;
    assert.equal(r.isError, true, `rejected: ${JSON.stringify(args)}`);
  }
  assert.equal(calls.length, 0, "no rejected call reached the bridge");
  const ok = (await client.callTool({
    name: "clip_add_drum_pattern",
    arguments: { trackId, pattern: "trap", bars: 64, atBeat: 0 },
  })) as any;
  assert.ok(!ok.isError);
});

test("clip_add_drum_pattern forwards clipId, and omits it when not given (W9-PATF)", async () => {
  const trackId = randomUUID();
  const clipId = randomUUID();
  const r = (await client.callTool({
    name: "clip_add_drum_pattern",
    arguments: { trackId, clipId, pattern: "trap" },
  })) as any;
  assert.ok(!r.isError);
  assert.deepStrictEqual(wire(calls[0]!.params), { trackId, clipId, pattern: "trap" });
  const r2 = (await client.callTool({
    name: "clip_add_drum_pattern",
    arguments: { trackId, pattern: "trap" },
  })) as any;
  assert.ok(!r2.isError);
  assert.deepStrictEqual(wire(calls[1]!.params), { trackId, pattern: "trap" }, "an omitted clipId is not on the wire");
});

test("clip_add_drum_pattern schema: clipId is an optional non-empty string; the count stays (W9-PATF)", async () => {
  const { tools } = await client.listTools();
  const t = tools.find((x) => x.name === "clip_add_drum_pattern")!;
  const schema = t.inputSchema as any;
  assert.ok("clipId" in schema.properties);
  assert.equal(schema.properties.clipId.type, "string");
  assert.ok(!schema.required.includes("clipId"), "clipId is optional");
  assert.deepStrictEqual([...schema.required].sort(), ["pattern", "trackId"]);
  const trackId = randomUUID();
  for (const args of [{ trackId, pattern: "trap", clipId: "" }, { trackId, pattern: "trap", clipId: 5 }]) {
    const r = (await client.callTool({ name: "clip_add_drum_pattern", arguments: args })) as any;
    assert.equal(r.isError, true, `rejected: ${JSON.stringify(args)}`);
  }
  assert.equal(calls.length, 0, "no rejected call reached the bridge");
});

test("clip_add_drum_pattern description pins the fill-a-clip form (W9-PATF)", async () => {
  const { tools } = await client.listTools();
  const t = tools.find((x) => x.name === "clip_add_drum_pattern")!;
  const d = t.description ?? "";
  for (const needle of ["FILL A CLIP YOU ALREADY MADE", "EMPTY MIDI clip", "already has notes", "REFUSED", "`atBeat` and `bars` are refused"]) {
    assert.ok(d.includes(needle), `description mentions: ${needle}`);
  }
  const prop = (t.inputSchema as any).properties.clipId.description as string;
  assert.ok(prop.includes("EMPTY") && prop.includes("Refused if the clip has any notes"));
});

test("pattern_list takes no params", async () => {
  const { tools } = await client.listTools();
  const t = tools.find((x) => x.name === "pattern_list")!;
  assert.deepStrictEqual(Object.keys((t.inputSchema as any).properties ?? {}), []);
});

test("clip_add_drum_pattern description quotes the overlap refusal and the left-out wording", async () => {
  const text = await description("clip_add_drum_pattern");
  assert.match(text, /REFUSED, not trimmed/);
  assert.ok(
    text.includes(
      "The beat would land on top of the clip '<name>' (<id>) on this track, and adding it there would cut that clip, so nothing was added. Leave 'atBeat' out to add the beat after the last clip (it would start at beat <n>), choose a free spot, or move that clip first."
    ),
    "overlap sentence quoted verbatim"
  );
  assert.ok(
    text.includes(
      "This kit has no <Drum>, so the beat's <n> <Drum> hits were left out. Nothing else plays in their place."
    ),
    "left-out sentence quoted verbatim"
  );
  assert.ok(
    text.includes(
      "This kit has none of the drums this beat uses (<drums>), so nothing was added. Pick a beat that uses the drums this kit has."
    ),
    "nothing-to-play sentence quoted verbatim"
  );
  assert.match(text, /LEFT OUT and NAMED, never replaced/);
  assert.match(text, /next bar line after the track's last clip/);
});

test("track_bounce_in_place names the song-changed refusal verbatim", async () => {
  const text = await description("track_bounce_in_place");
  assert.ok(
    text.includes(
      "The song changed while the track was bouncing (a new song was started or another song was opened), so nothing was added to either song. Bounce the track again from the song it belongs to."
    )
  );
});
