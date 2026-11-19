/**
 * template-tools.test.ts — m39-tpl-7: the seven `template_*` MCP tools and
 * `macro_song_skeleton`'s `template` / `dryRun` passthrough.
 *
 * Same stub-bridge / InMemoryTransport pattern as nested-strict-gap.test.ts, but
 * the central test here INVERTS that file's m30-c pattern on purpose:
 *
 *   - m30-c: a misspelled key inside a nested object is refused AT THE MCP BOUNDARY
 *     (`isError`, `calls.length === 0`), because the schema can name every key.
 *   - here: an inline template is an opaque `z.record(z.string(), z.unknown())`. The
 *     MCP server must NOT judge its keys (a zod copy of the whole template schema
 *     would be a second home that goes stale with every new effect setting), so a
 *     misspelled nested key REACHES THE BRIDGE VERBATIM (`calls.length === 1`, the key
 *     present) and the APP's refusal comes back as `isError`.
 *
 * Every inverted test is paired with a "still accepts a legitimate call" test.
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
  client = new Client({ name: "template-tools-test-client", version: "0.0.0" });
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

/** An inline template whose nested key `instrumnet` is a deliberate typo. */
const typoTemplate = {
  formatVersion: 1,
  name: "Typo band",
  tracks: [{ key: "keys", name: "Keys", kind: "instrument", instrumnet: { kind: "polySynth" } }],
};

const goodTemplate = {
  formatVersion: 1,
  name: "Good band",
  tracks: [{ key: "keys", name: "Keys", kind: "instrument", instrument: { kind: "polySynth" } }],
};

const APP_REFUSAL = "tracks[0]: unknown key 'instrumnet' — did you mean 'instrument'?";

// ---------------------------------------------------------------------------
// The tools exist, with the right mutating shape
// ---------------------------------------------------------------------------

test("all seven template tools are listed, each with a novice-readable description", async () => {
  const listed = (await client.listTools()).tools;
  for (const name of [
    "template_list",
    "template_describe",
    "template_apply",
    "template_save",
    "template_remove",
    "template_import",
    "template_export",
  ]) {
    const tool = listed.find((t) => t.name === name);
    assert.ok(tool, `${name} must be listed`);
    assert.match(tool!.description ?? "", /A template is a saved "band"/, `${name} explains what a template is`);
  }
  const apply = listed.find((t) => t.name === "template_apply")!;
  assert.match(apply.description!, /ONLY ADDS/);
  assert.match(apply.description!, /template_describe/);
  const describeTool = listed.find((t) => t.name === "template_describe")!;
  assert.match(describeTool.description!, /WITHOUT changing the song/);
});

// ---------------------------------------------------------------------------
// template_list / template_describe (read-only)
// ---------------------------------------------------------------------------

test("template_list forwards to template.list with no params", async () => {
  queuedResult = { templates: [], unreadable: [] };
  const result = (await client.callTool({ name: "template_list", arguments: {} })) as any;
  assert.ok(!result.isError);
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "template.list");
});

test("template_describe accepts an id and forwards it unchanged", async () => {
  queuedResult = { template: {}, tracks: [], slotsUsed: {}, hasRouting: false, warnings: [] };
  const result = (await client.callTool({
    name: "template_describe",
    arguments: { template: "lofi-chill" },
  })) as any;
  assert.ok(!result.isError);
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "template.describe");
  assert.equal(calls[0]!.params.template, "lofi-chill");
});

test("template_describe: a misspelled nested key in an inline template REACHES THE BRIDGE and the app's refusal is surfaced", async () => {
  queuedError = new Error(APP_REFUSAL);
  const result = (await client.callTool({
    name: "template_describe",
    arguments: { template: typoTemplate },
  })) as any;
  assert.ok(result.isError, "the app's refusal must come back as isError");
  assert.equal(calls.length, 1, "the MCP server must not judge an inline template's keys");
  const sent = calls[0]!.params.template as Record<string, any>;
  assert.equal(sent.tracks[0].instrumnet.kind, "polySynth", "the typo'd key must arrive verbatim");
  assert.ok(JSON.stringify(result).includes("instrumnet"), "the app's message reaches the agent");
});

test("template_describe still accepts a legitimate inline template (no regression)", async () => {
  queuedResult = { template: goodTemplate, tracks: [], slotsUsed: {}, hasRouting: false, warnings: [] };
  const result = (await client.callTool({
    name: "template_describe",
    arguments: { template: goodTemplate },
  })) as any;
  assert.ok(!result.isError);
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params.template, goodTemplate);
});

test("template_describe refuses a template that is neither an id nor an object (never reaches the bridge)", async () => {
  const result = (await client.callTool({
    name: "template_describe",
    arguments: { template: 42 },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

// ---------------------------------------------------------------------------
// template_apply
// ---------------------------------------------------------------------------

test("template_apply: a misspelled nested key in an inline template REACHES THE BRIDGE and the app's refusal is surfaced", async () => {
  queuedError = new Error(APP_REFUSAL);
  const result = (await client.callTool({
    name: "template_apply",
    arguments: { template: typoTemplate },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "template.apply");
  const sent = calls[0]!.params.template as Record<string, any>;
  assert.ok("instrumnet" in sent.tracks[0], "the typo'd key must arrive verbatim, not be stripped");
});

test("template_apply still accepts an id, an inline template and dryRun (no regression)", async () => {
  queuedResult = { applied: true, name: "x", tracks: [], warnings: [], duplicateTrackNames: [], undoLabel: "x" };
  const byId = (await client.callTool({
    name: "template_apply",
    arguments: { template: "lofi-chill" },
  })) as any;
  assert.ok(!byId.isError);
  const inline = (await client.callTool({
    name: "template_apply",
    arguments: { template: goodTemplate, dryRun: true },
  })) as any;
  assert.ok(!inline.isError);
  assert.equal(calls.length, 2);
  assert.equal(calls[0]!.params.template, "lofi-chill");
  assert.deepEqual(calls[1]!.params.template, goodTemplate);
  assert.equal(calls[1]!.params.dryRun, true);
});

test("template_apply rejects an unknown TOP-LEVEL key at the MCP boundary (mutating tools are strict)", async () => {
  const result = (await client.callTool({
    name: "template_apply",
    arguments: { template: "lofi-chill", dryrun: true },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

// ---------------------------------------------------------------------------
// template_save / remove / import / export
// ---------------------------------------------------------------------------

test("template_save forwards name, trackIds and the optional fields", async () => {
  queuedResult = { id: "user-1", name: "My trio", template: {}, warnings: [] };
  const result = (await client.callTool({
    name: "template_save",
    arguments: {
      name: "My trio",
      trackIds: ["11111111-1111-1111-1111-111111111111"],
      summary: "Three players",
      genres: ["jazz"],
      replaceId: "user-0",
    },
  })) as any;
  assert.ok(!result.isError);
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "template.save");
  assert.equal(calls[0]!.params.name, "My trio");
  assert.deepEqual(calls[0]!.params.trackIds, ["11111111-1111-1111-1111-111111111111"]);
  assert.deepEqual(calls[0]!.params.genres, ["jazz"]);
  assert.equal(calls[0]!.params.replaceId, "user-0");
});

test("template_save rejects an empty trackIds list and an over-long name (never reaches the bridge)", async () => {
  const empty = (await client.callTool({
    name: "template_save",
    arguments: { name: "x", trackIds: [] },
  })) as any;
  assert.ok(empty.isError);
  const long = (await client.callTool({
    name: "template_save",
    arguments: { name: "x".repeat(41), trackIds: ["a"] },
  })) as any;
  assert.ok(long.isError);
  assert.equal(calls.length, 0);
});

test("template_remove forwards the id", async () => {
  queuedResult = { removed: "user-1" };
  const result = (await client.callTool({ name: "template_remove", arguments: { id: "user-1" } })) as any;
  assert.ok(!result.isError);
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "template.remove");
  assert.equal(calls[0]!.params.id, "user-1");
});

test("template_import forwards the path", async () => {
  queuedResult = { id: "user-2", name: "Band", warnings: [] };
  const result = (await client.callTool({
    name: "template_import",
    arguments: { path: "/tmp/band.dawtemplate" },
  })) as any;
  assert.ok(!result.isError);
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "template.import");
  assert.equal(calls[0]!.params.path, "/tmp/band.dawtemplate");
});

test("template_export forwards id, path and overwrite", async () => {
  queuedResult = { path: "/tmp/band.dawtemplate", bytes: 100 };
  const result = (await client.callTool({
    name: "template_export",
    arguments: { id: "lofi-chill", path: "/tmp/band.dawtemplate", overwrite: true },
  })) as any;
  assert.ok(!result.isError);
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "template.export");
  assert.equal(calls[0]!.params.id, "lofi-chill");
  assert.equal(calls[0]!.params.overwrite, true);
});

// ---------------------------------------------------------------------------
// macro_song_skeleton — template / dryRun passthrough, and D2
// ---------------------------------------------------------------------------

test("macro_song_skeleton forwards an inline template untouched; a typo'd nested key reaches the bridge and the app's refusal is surfaced", async () => {
  queuedError = new Error(APP_REFUSAL);
  const result = (await client.callTool({
    name: "macro_song_skeleton",
    arguments: { genre: "pop", template: typoTemplate },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "macro.songSkeleton");
  const sent = calls[0]!.params.template as Record<string, any>;
  assert.ok("instrumnet" in sent.tracks[0]);
});

test("macro_song_skeleton still accepts a template id and dryRun (no regression)", async () => {
  queuedResult = { applied: false, genre: "pop", tracks: [] };
  const result = (await client.callTool({
    name: "macro_song_skeleton",
    arguments: { genre: "pop", template: "lofi-chill", dryRun: true },
  })) as any;
  assert.ok(!result.isError);
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params.genre, "pop");
  assert.equal(calls[0]!.params.template, "lofi-chill");
  assert.equal(calls[0]!.params.dryRun, true);
});

test("macro_song_skeleton D2: a `program` key inside tracks[] reaches the bridge (the app teaches why it is refused)", async () => {
  queuedError = new Error("tracks[0].program: A track list can't pick sounds. To choose instruments, pass a template.");
  const result = (await client.callTool({
    name: "macro_song_skeleton",
    arguments: { genre: "pop", tracks: [{ name: "Keys", kind: "instrument", program: 4 }] },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 1, "the key must not be stripped or refused at the MCP boundary");
  const sent = calls[0]!.params.tracks as Array<Record<string, unknown>>;
  assert.equal(sent[0]!.program, 4);
  assert.ok(JSON.stringify(result).includes("pass a template"));
});

test("macro_song_skeleton still accepts a legitimate tracks roster (no regression)", async () => {
  queuedResult = { genre: "pop", tracks: [] };
  const result = (await client.callTool({
    name: "macro_song_skeleton",
    arguments: { genre: "pop", tracks: [{ name: "Rhodes", kind: "instrument", mixerPreset: "warm-keys" }] },
  })) as any;
  assert.ok(!result.isError);
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params.tracks, [{ name: "Rhodes", kind: "instrument", mixerPreset: "warm-keys" }]);
});

test("macro_song_skeleton's genre text is short and points at dryRun", async () => {
  const listed = (await client.listTools()).tools;
  const tool = listed.find((t) => t.name === "macro_song_skeleton")!;
  const genreSchema = (tool.inputSchema as any).properties.genre;
  assert.match(genreSchema.description, /dryRun: true/);
  assert.ok(genreSchema.description.length < 1500, `genre text should stay short, was ${genreSchema.description.length}`);
  assert.deepEqual(genreSchema.enum.length, 14);
});
