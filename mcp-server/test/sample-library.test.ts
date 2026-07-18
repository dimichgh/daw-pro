/**
 * sample-library.test.ts — round-trip coverage for
 * instrument_import_sample_library (m19-c flight 2, the MCP half of the
 * SFZ/.dspreset sample-library importer; Swift wire command
 * `instrument.importSampleLibrary` landed and is verified in flight 1).
 *
 * Same stub-bridge pattern as sound-banks.test.ts / connection-info.test.ts
 * (the m10-h/m10-l/m10-m/m10-n-2 precedent): unlike integration.test.ts
 * (real spawned DAWApp + real control WebSocket), this suite monkeypatches
 * `DawBridge.prototype.send` before any tool call runs, so the REAL
 * `McpServer` from `src/server.ts` is driven over an in-memory transport
 * with no live app required. Asserts:
 *   - trackId/path are forwarded verbatim to `instrument.importSampleLibrary`
 *   - dryRun/force, when supplied, are forwarded verbatim alongside them
 *   - omitted dryRun/force are NOT sent as keys at all (matching how
 *     instrument_import_sound_bank forwards only what the caller gave —
 *     no invented defaults at the MCP layer; the app itself defaults both
 *     to false when the key is absent)
 *   - a stubbed `{report, applied}` result round-trips back unchanged, for
 *     both a dry run (applied:false) and a real apply (applied:true)
 *   - trackId and path are both required (rejected at the schema layer,
 *     zero bridge calls)
 *   - stubbed app-side errors (wrong extension, .dspreset-not-yet-available,
 *     .dslibrary unzip hint, relative path, size refusal) surface as MCP
 *     tool errors (isError: true) carrying the app's own message verbatim
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
  client = new Client({ name: "sample-library-test-client", version: "0.0.0" });
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
// instrument_import_sample_library
// ---------------------------------------------------------------------------

test("instrument_import_sample_library forwards trackId/path verbatim, dryRun/force omitted, to instrument.importSampleLibrary", async () => {
  const stubbed = {
    report: {
      format: "sfz",
      skippedRegions: {},
      groupCount: 2,
      degradations: [],
      zonesImported: 2,
      totalSampleBytes: 264688,
      ignoredOpcodes: {},
      velocityLayerCount: 2,
    },
    applied: true,
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "instrument_import_sample_library",
    arguments: { trackId: "track-1", path: "/Users/x/Samples/Piano.sfz" },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "instrument.importSampleLibrary");
  assert.deepEqual(
    calls[0]!.params,
    { trackId: "track-1", path: "/Users/x/Samples/Piano.sfz" },
    "dryRun/force are never sent as keys when the caller omitted them — no invented defaults at the MCP layer"
  );

  assert.deepEqual(parseJSON(result as any), stubbed, "the app's response round-trips back verbatim");
});

test("instrument_import_sample_library forwards dryRun:true and force:true verbatim alongside trackId/path", async () => {
  const stubbed = {
    report: {
      format: "sfz",
      skippedRegions: { "trigger=release": 49 },
      groupCount: 4,
      degradations: ["Keyswitches were reduced to the default articulation."],
      zonesImported: 128,
      totalSampleBytes: 6_442_450_944,
      ignoredOpcodes: { ampeg_decay: 3 },
      velocityLayerCount: 8,
    },
    applied: false,
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "instrument_import_sample_library",
    arguments: {
      trackId: "track-1",
      path: "/Users/x/Samples/Huge.sfz",
      dryRun: true,
      force: true,
    },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "instrument.importSampleLibrary");
  assert.deepEqual(calls[0]!.params, {
    trackId: "track-1",
    path: "/Users/x/Samples/Huge.sfz",
    dryRun: true,
    force: true,
  });

  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("instrument_import_sample_library forwards dryRun:false and force:false explicitly when the caller passes them", async () => {
  queuedResult = { report: { format: "dspreset" }, applied: true };

  const result = await client.callTool({
    name: "instrument_import_sample_library",
    arguments: { trackId: "track-1", path: "/Users/x/Samples/Kit.sfz", dryRun: false, force: false },
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, {
    trackId: "track-1",
    path: "/Users/x/Samples/Kit.sfz",
    dryRun: false,
    force: false,
  });
  assert.ok(!(result as any).isError);
});

test("instrument_import_sample_library requires trackId (rejected at the schema layer, zero bridge calls)", async () => {
  const result = await client.callTool({
    name: "instrument_import_sample_library",
    arguments: { path: "/Users/x/Samples/Piano.sfz" },
  });

  assert.equal(calls.length, 0, "a missing required trackId never reaches bridge.send");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
});

test("instrument_import_sample_library requires path (rejected at the schema layer, zero bridge calls)", async () => {
  const result = await client.callTool({
    name: "instrument_import_sample_library",
    arguments: { trackId: "track-1" },
  });

  assert.equal(calls.length, 0);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
});

test("instrument_import_sample_library rejects an unknown extra key at the schema layer, zero bridge calls", async () => {
  const result = await client.callTool({
    name: "instrument_import_sample_library",
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    arguments: { trackId: "track-1", path: "/Users/x/Samples/Piano.sfz", bogus: true } as any,
  });

  assert.equal(calls.length, 0, "an unrecognized key never reaches bridge.send — the strict schema rejects it first");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
});

test("instrument_import_sample_library surfaces a relative-path error verbatim", async () => {
  queuedError = new Error("'path' must be an absolute path");

  const result = await client.callTool({
    name: "instrument_import_sample_library",
    arguments: { trackId: "track-1", path: "relative/Piano.sfz" },
  });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.equal(r.content[0].text, "'path' must be an absolute path");
});

test("instrument_import_sample_library surfaces the malformed-.dspreset-XML error verbatim", async () => {
  // m19-d: .dspreset imports are live; the app-side error shape for a broken
  // preset is DSPresetParserError.malformedXML — passthrough stays verbatim.
  queuedError = new Error(
    "malformed .dspreset XML in /Users/x/Samples/Kit.dspreset: " +
      "The element “groups” is missing its closing tag on line 7."
  );

  const result = await client.callTool({
    name: "instrument_import_sample_library",
    arguments: { trackId: "track-1", path: "/Users/x/Samples/Kit.dspreset" },
  });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /malformed \.dspreset XML in/);
});

test("instrument_import_sample_library surfaces the .dslibrary unzip-hint error verbatim", async () => {
  queuedError = new Error(
    ".dslibrary is a zip archive — unzip it and import the .dspreset inside"
  );

  const result = await client.callTool({
    name: "instrument_import_sample_library",
    arguments: { trackId: "track-1", path: "/Users/x/Samples/Kit.dslibrary" },
  });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /unzip it and import the \.dspreset inside/);
});

test("instrument_import_sample_library surfaces the size-refusal error verbatim (names the force flag)", async () => {
  queuedError = new Error(
    "sample library totals 5.2 GB, over the 4 GB limit — pass force to import it anyway"
  );

  const result = await client.callTool({
    name: "instrument_import_sample_library",
    arguments: { trackId: "track-1", path: "/Users/x/Samples/Huge.sfz" },
  });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /force/);
});

test("instrument_import_sample_library surfaces an app-not-running bridge error verbatim", async () => {
  queuedError = new Error("app not running — start DAW Pro or run `swift run DAWApp`");

  const result = await client.callTool({
    name: "instrument_import_sample_library",
    arguments: { trackId: "track-1", path: "/Users/x/Samples/Piano.sfz" },
  });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /app not running/);
});
