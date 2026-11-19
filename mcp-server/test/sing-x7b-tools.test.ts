/**
 * sing-x7b-tools.test.ts — p2-sing-x7 part B (W8-X7B): the MCP side of `sing.render {parts, key, mode}`,
 * `sing.jobStatus.parts`, `sing.cancelJob`'s landing note and `ai.writeLyrics {fitClipId, language}` (design
 * docs/design/2026-10-06-p2-sing-expansion.md §4.7, §8.3, §9.2 S6).
 *
 * Same stub-bridge / InMemoryTransport pattern as sing-tools.test.ts: `DawBridge.prototype.send` is replaced, so no
 * app, no socket and no provider call. One test per changed tool, plus S6: each changed tool's `required` list is the
 * pin-before one (captured 2026-10-07 01:08 from the built, unchanged server: 290 tools) and no new param is in it.
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

DawBridge.prototype.send = async function (
  command: string,
  params: Record<string, unknown> = {}
): Promise<unknown> {
  calls.push({ command, params });
  return { ok: true };
};

const { server } = await import("../src/server.js");

let client: Client;

before(async () => {
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  client = new Client({ name: "sing-x7b-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
});

beforeEach(() => {
  calls = [];
});

const CLIP = "7C70224C-A6A0-47BF-B905-55769739D1BA";
const OTHER = "1B4E28BA-2FA1-11D2-883F-0016D3CCA427";

async function listed(name: string) {
  const tool = (await client.listTools()).tools.find((t) => t.name === name);
  assert.ok(tool, `${name} must be listed`);
  return tool!;
}

function schemaOf(tool: { inputSchema: unknown }) {
  return tool.inputSchema as { required?: string[]; properties?: Record<string, any> };
}

/** S6: the pin-before `required` lists of the four tools this round changes (required-before.json, 01:08). */
const REQUIRED_BEFORE: Record<string, string[]> = {
  sing_render: ["clipId"],
  sing_job_status: [],
  sing_cancel_job: ["jobId"],
  ai_write_lyrics: ["prompt"],
};

test("S6: the four changed tools keep their pin-before `required` lists; no new param is required", async () => {
  for (const [name, required] of Object.entries(REQUIRED_BEFORE)) {
    const schema = schemaOf(await listed(name));
    assert.deepEqual([...(schema.required ?? [])].sort(), required, `${name} required`);
  }
  for (const param of ["parts", "key", "mode", "fitClipId", "language"]) {
    for (const name of Object.keys(REQUIRED_BEFORE)) {
      assert.ok(!(schemaOf(await listed(name)).required ?? []).includes(param), `${name}: ${param} stays optional`);
    }
  }
});

test("sing_render: parts / key / mode are listed, forwarded unchanged, and a part is a strict object", async () => {
  const tool = await listed("sing_render");
  const schema = schemaOf(tool);
  assert.deepEqual(
    Object.keys(schema.properties ?? {}).sort(),
    ["clipId", "dryRun", "key", "lyrics", "mode", "octaveShift", "parts", "seed", "trackName", "voiceId"]
  );
  const item = schema.properties!.parts.items;
  assert.equal(item.additionalProperties, false, "an unknown part field is refused at the boundary");
  assert.deepEqual(item.required, ["kind"]);
  assert.deepEqual(item.properties.kind.enum, ["harmony", "chordTones", "clip", "double"]);
  assert.deepEqual(
    Object.keys(item.properties).sort(),
    ["chordSource", "direction", "interval", "kind", "pan", "seed", "sourceClipId", "trackName", "voiceId", "volumeDb"]
  );
  assert.equal(schema.properties!.parts.maxItems, undefined, "the app's own sentence says \"up to 3\"");
  assert.match(tool.description ?? "", /HARMONIES AND DOUBLES/);
  assert.match(tool.description ?? "", /Land Sung Harmony/);
  assert.match(tool.description ?? "", /`dryRun` previews the parts too/);
  assert.doesNotMatch(tool.description ?? "", /singPartsDryRunUnsupported/);

  const parts = [
    { kind: "harmony", interval: "third", direction: "above", chordSource: "none", pan: 0.3, volumeDb: -4 },
    { kind: "clip", sourceClipId: OTHER, voiceId: "builtin-1", seed: 7, trackName: "Alto" },
    { kind: "double" },
  ];
  const args = { clipId: CLIP, parts, key: 9, mode: "minor" };
  const result = (await client.callTool({ name: "sing_render", arguments: args })) as any;
  assert.ok(!result.isError, JSON.stringify(result.content));
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "sing.render");
  assert.deepEqual(JSON.parse(JSON.stringify(calls[0]!.params)), args);

  calls = [];
  const typo = (await client.callTool({
    name: "sing_render",
    arguments: { clipId: CLIP, parts: [{ kind: "harmony", interval: "third", direction: "above", intervall: "x" }] },
  })) as any;
  assert.ok(typo.isError, "a typo'd part field is refused");
  assert.equal(calls.length, 0, "and never reaches the app");
});

test("sing_job_status: describes parts and whose take `result` is (the lead's when it landed, else the first landed part's)", async () => {
  const tool = await listed("sing_job_status");
  const text = tool.description ?? "";
  assert.match(text, /`parts: \[\{role/);
  assert.match(text, /LEAD's take when the lead landed, otherwise the FIRST part that landed/);
  assert.match(text, /A job without parts has no `parts` key/);
  assert.deepEqual(Object.keys(schemaOf(tool).properties ?? {}), ["jobId"]);
  const result = (await client.callTool({ name: "sing_job_status", arguments: { jobId: "sing-1" } })) as any;
  assert.ok(!result.isError);
  assert.deepEqual(calls, [{ command: "sing.jobStatus", params: { jobId: "sing-1" } }]);
});

test("sing_cancel_job: says a take that has started landing cannot be cancelled, and to use edit_undo", async () => {
  const tool = await listed("sing_cancel_job");
  assert.match(tool.description ?? "", /Once a take has started landing in the song, cancel cannot stop it/);
  assert.match(tool.description ?? "", /edit_undo/);
  assert.deepEqual(Object.keys(schemaOf(tool).properties ?? {}), ["jobId"]);
  const result = (await client.callTool({ name: "sing_cancel_job", arguments: { jobId: "sing-1" } })) as any;
  assert.ok(!result.isError);
  assert.deepEqual(calls, [{ command: "sing.cancelJob", params: { jobId: "sing-1" } }]);
});

test("ai_write_lyrics: fitClipId / language are listed, forwarded unchanged, and the fit reply is described", async () => {
  const tool = await listed("ai_write_lyrics");
  const schema = schemaOf(tool);
  assert.deepEqual(
    Object.keys(schema.properties ?? {}).sort(),
    ["context", "existingLyrics", "fitClipId", "instruction", "language", "prompt", "structure", "style"]
  );
  assert.match(tool.description ?? "", /fit: \{lines: \[\{phrase, notes, syllables, fits\}\], allFit/);
  assert.match(tool.description ?? "", /Nothing is stored/);
  const args = { prompt: "missing home", fitClipId: CLIP, language: "zh" };
  const result = (await client.callTool({ name: "ai_write_lyrics", arguments: args })) as any;
  assert.ok(!result.isError, JSON.stringify(result.content));
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "ai.writeLyrics");
  assert.deepEqual(JSON.parse(JSON.stringify(calls[0]!.params)), args);

  calls = [];
  const bad = (await client.callTool({ name: "ai_write_lyrics", arguments: { prompt: "x", fitClipId: "nope" } })) as any;
  assert.ok(bad.isError, "fitClipId must be a clip id");
  assert.equal(calls.length, 0);
});

test("transport_record / transport_record_layer quote W8-F2's recorder-open refusal verbatim (description only)", async () => {
  const sentence = "The voice recorder is open. Close it before recording in the song.";
  for (const name of ["transport_record", "transport_record_layer"]) {
    const tool = await listed(name);
    assert.ok((tool.description ?? "").includes(`"${sentence}"`), `${name} quotes the sentence`);
    assert.deepEqual(Object.keys(schemaOf(tool).properties ?? {}), [], `${name} still takes no params`);
  }
});

// W9-PICKS (p2-sing-x9-picks): the user's Sung Vocal Picks are the singer's defaults. Captured BEFORE the edit: the
// level and width defaults the picks kept (H2 −4 dB, D +0.4) are stated exactly as before.
test("PICKS pin: sing_render's part pan and level text still states the kept defaults (H2 -4 dB, D +0.4)", async () => {
  const item = schemaOf(await listed("sing_render")).properties!.parts.items;
  assert.equal(
    item.properties.pan.description,
    "-1 (left) … 1 (right). Default ±0.3 for the first part on a side (above = right), ±0.5 for the next; a double +0.4."
  );
  assert.equal(
    item.properties.volumeDb.description,
    "Level in dB, -60 … +6. Default -4 for the first part on a side, -6 for the next; a double -4."
  );
});

test("PICKS: sing_render's part seed text states the H3 pick (a part's own performance on the lead's seed + 2)", async () => {
  const item = schemaOf(await listed("sing_render")).properties!.parts.items;
  assert.equal(
    item.properties.seed.description,
    "A whole number. Default: a harmony, chordTones or clip part sings its own performance on the lead's seed + 2; " +
      "a double on the lead's + 7919 (a double on the lead's own seed is refused, it would be an exact copy). A seed " +
      "you pass is used as given."
  );
  assert.doesNotMatch(item.properties.seed.description, /Default the lead's seed/);
});

test("PICKS: the singing-style tools state the round-V pick (\"normal\" vibrato is the default; asSung is a choice)", async () => {
  const set = await listed("clip_set_sing_style");
  const vibrato = schemaOf(set).properties!.vibrato.description as string;
  assert.equal(
    vibrato,
    "Vibrato, the gentle wobble singers put on long notes: \"normal\" (a medium wobble — the default when none is " +
      "chosen), \"asSung\" (the singer's own, untouched), \"straight\" (no wobble), \"gentle\" or \"wide\"."
  );
  assert.doesNotMatch(vibrato, /untouched — the default/);
  const sentence = "sung with the defaults: \"normal\" vibrato, no air, every note at one level";
  assert.ok((set.description ?? "").includes(sentence), "clip_set_sing_style names the defaults");
  assert.ok(!(set.description ?? "").includes("sung as the engine sings it"), "the old default is gone");
  const get = await listed("clip_get_sing_style");
  assert.ok((get.description ?? "").includes(sentence), "clip_get_sing_style names the defaults");
  assert.deepEqual(schemaOf(set).properties!.vibrato.enum, ["asSung", "straight", "gentle", "normal", "wide"]);
});

// W9-PICKSF (p2-sing-x9-picks-f): an omitted seed is a FIXED starting number, never a fresh take. No sing tool may
// say otherwise.
test("PICKSF: sing_render's seed text says an omitted seed repeats, not 'a fresh take'", async () => {
  const seed = schemaOf(await listed("sing_render")).properties!.seed.description as string;
  assert.match(seed, /Omit it and the take uses one fixed starting number/);
  assert.match(seed, /seed \+ 2/);
  assert.doesNotMatch(seed, /fresh take/);
  for (const name of ["sing_render", "sing_job_status", "sing_propose_harmony", "clip_set_sing_style"]) {
    const t = await listed(name);
    assert.doesNotMatch(JSON.stringify(t), /fresh take each time|omit(ted)? (it )?for a fresh/i, `${name} promises a fresh take`);
  }
});
