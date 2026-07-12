/**
 * sound-banks.test.ts — round-trip coverage for instrument_list_sound_banks,
 * instrument_list_sound_bank_programs, instrument_import_sound_bank, and the
 * `soundBank` param/echo on track_set_instrument (m10-n-2 MCP half).
 *
 * Same stub-bridge pattern as connection-info.test.ts / copilot.test.ts (the
 * m10-h/m10-l/m10-m precedent): unlike integration.test.ts (real spawned
 * DAWApp + real control WebSocket), this suite monkeypatches
 * `DawBridge.prototype.send` before any tool call runs, so the REAL
 * `McpServer` from `src/server.ts` is driven over an in-memory transport (the
 * audit-tools.test.ts precedent) with no live app required. Asserts:
 *   - instrument_list_sound_banks takes no params and forwards exactly
 *     `instrument.listSoundBanks` with no arguments; a stubbed result
 *     round-trips back unchanged
 *   - instrument_list_sound_bank_programs forwards `source` verbatim to
 *     `instrument.listSoundBankPrograms`; a stubbed result (including
 *     namesParsed:false generic-fallback shapes) round-trips unchanged
 *   - instrument_import_sound_bank forwards `path` verbatim to
 *     `instrument.importSoundBank`; a stubbed `{bank}` result round-trips
 *     unchanged
 *   - track_set_instrument forwards a supplied `soundBank` object verbatim
 *     (including when only `source` is given, omitting program/bankMSB/
 *     bankLSB) and omits `soundBank` entirely from the wire frame when not
 *     supplied — the ai_copilot_send maxRounds precedent for "an omitted
 *     optional field never reaches the app as a value"
 *   - program/bankMSB/bankLSB are hard-rejected at the zod schema layer
 *     outside 0-127 (the m10-m house style for fixed, known MIDI-byte
 *     ranges — clip_add_midi's note pitch/velocity, ai_copilot_send's
 *     maxRounds), with ZERO bridge calls; the Swift-side model still CLAMPS
 *     these same fields for any other raw control-protocol caller
 *     (Sources/DAWCore/SoundBanks.swift's `SoundBankConfig.init`), this
 *     tool's schema simply never forwards an out-of-range value at all
 *   - a stubbed app-side error (e.g. the ambiguous audioUnit+soundBank
 *     rejection, or a missing-file error) surfaces as an MCP tool error
 *     (isError: true) carrying the app's own message verbatim, never
 *     swallowed
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
  client = new Client({ name: "sound-banks-test-client", version: "0.0.0" });
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
// instrument_list_sound_banks
// ---------------------------------------------------------------------------

test("instrument_list_sound_banks takes no params and forwards to instrument.listSoundBanks with no arguments", async () => {
  const stubbed = {
    banks: [
      { source: "gm", name: "General MIDI", path: "/System/Library/.../gs_instruments.dls", format: "dls", builtin: true, sizeBytes: 5_000_000 },
      { source: "/Users/x/Library/Application Support/DAWPro/SoundBanks/Vintage.sf2", name: "Vintage", path: "/Users/x/Library/Application Support/DAWPro/SoundBanks/Vintage.sf2", format: "sf2", builtin: false, sizeBytes: 100 },
    ],
  };
  queuedResult = stubbed;

  const result = await client.callTool({ name: "instrument_list_sound_banks", arguments: {} });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "instrument.listSoundBanks");
  assert.deepEqual(calls[0]!.params, {}, "no arguments are forwarded — this command takes no params");

  assert.deepEqual(parseJSON(result as any), stubbed, "the app's response round-trips back verbatim");
});

test("instrument_list_sound_banks surfaces a bridge-side error as an MCP tool error, message verbatim", async () => {
  queuedError = new Error("app not running — start DAW Pro or run `swift run DAWApp`");

  const result = await client.callTool({ name: "instrument_list_sound_banks", arguments: {} });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /app not running/);
});

// ---------------------------------------------------------------------------
// instrument_list_sound_bank_programs
// ---------------------------------------------------------------------------

test("instrument_list_sound_bank_programs forwards source verbatim to instrument.listSoundBankPrograms", async () => {
  const stubbed = {
    source: "gm",
    namesParsed: true,
    programs: [
      { program: 0, bankMSB: 121, bankLSB: 0, name: "Acoustic Grand Piano", category: "Piano" },
      { program: 56, bankMSB: 121, bankLSB: 0, name: "Trumpet", category: "Brass" },
      { program: 0, bankMSB: 120, bankLSB: 0, name: "Standard Drum Kit", category: "Drum Kits" },
    ],
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "instrument_list_sound_bank_programs",
    arguments: { source: "gm" },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "instrument.listSoundBankPrograms");
  assert.deepEqual(calls[0]!.params, { source: "gm" });

  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("instrument_list_sound_bank_programs forwards an absolute file-path source and round-trips a generic namesParsed:false result", async () => {
  const stubbed = {
    source: "/Library/Audio/Sounds/Banks/Weird.dls",
    namesParsed: false,
    programs: Array.from({ length: 128 }, (_, i) => ({
      program: i,
      bankMSB: 121,
      bankLSB: 0,
      name: `Program ${i}`,
      category: "",
    })),
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "instrument_list_sound_bank_programs",
    arguments: { source: "/Library/Audio/Sounds/Banks/Weird.dls" },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params["source"], "/Library/Audio/Sounds/Banks/Weird.dls");
  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("instrument_list_sound_bank_programs requires source (rejected at the schema layer, zero bridge calls)", async () => {
  const result = await client.callTool({ name: "instrument_list_sound_bank_programs", arguments: {} });

  assert.equal(calls.length, 0, "a missing required source never reaches bridge.send");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
});

test("instrument_list_sound_bank_programs surfaces a bridge-side error (bad source) verbatim", async () => {
  queuedError = new Error(
    "sound bank source must be \"gm\" or an absolute path — see instrument.listSoundBanks"
  );

  const result = await client.callTool({
    name: "instrument_list_sound_bank_programs",
    arguments: { source: "vintage" },
  });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /instrument\.listSoundBanks/);
});

// ---------------------------------------------------------------------------
// instrument_import_sound_bank
// ---------------------------------------------------------------------------

test("instrument_import_sound_bank forwards path verbatim to instrument.importSoundBank", async () => {
  const stubbed = {
    bank: {
      source: "/Users/x/Library/Application Support/DAWPro/SoundBanks/Strings.sf2",
      name: "Strings",
      path: "/Users/x/Library/Application Support/DAWPro/SoundBanks/Strings.sf2",
      format: "sf2",
      builtin: false,
      sizeBytes: 64,
    },
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "instrument_import_sound_bank",
    arguments: { path: "/Users/x/Downloads/Strings.sf2" },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "instrument.importSoundBank");
  assert.deepEqual(calls[0]!.params, { path: "/Users/x/Downloads/Strings.sf2" });

  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("instrument_import_sound_bank requires path (rejected at the schema layer, zero bridge calls)", async () => {
  const result = await client.callTool({ name: "instrument_import_sound_bank", arguments: {} });

  assert.equal(calls.length, 0);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
});

test("instrument_import_sound_bank surfaces a bridge-side error (relative path) verbatim", async () => {
  queuedError = new Error("'path' must be an absolute path");

  const result = await client.callTool({
    name: "instrument_import_sound_bank",
    arguments: { path: "relative/bank.sf2" },
  });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /absolute path/);
});

// ---------------------------------------------------------------------------
// track_set_instrument soundBank forwarding
// ---------------------------------------------------------------------------

test("track_set_instrument forwards a full soundBank object verbatim", async () => {
  queuedResult = {
    kind: "soundBank",
    soundBank: {
      source: "gm",
      path: "/System/Library/.../gs_instruments.dls",
      program: 56,
      bankMSB: 121,
      bankLSB: 0,
      name: "Trumpet — General MIDI",
      status: "pending",
    },
  };

  const result = await client.callTool({
    name: "track_set_instrument",
    arguments: {
      trackId: "track-1",
      soundBank: { source: "gm", program: 56, bankMSB: 121, bankLSB: 0 },
    },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "track.setInstrument");
  assert.deepEqual(calls[0]!.params["soundBank"], { source: "gm", program: 56, bankMSB: 121, bankLSB: 0 });
  assert.equal(calls[0]!.params["trackId"], "track-1");

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok(!(result as any).isError);
  assert.deepEqual(parseJSON(result as any), queuedResult);
});

test("track_set_instrument forwards a soundBank object with only source given (program/bankMSB/bankLSB omitted)", async () => {
  queuedResult = { kind: "soundBank", soundBank: { source: "gm", program: 0, bankMSB: 121, bankLSB: 0, name: "Acoustic Grand Piano — General MIDI", status: "pending" } };

  const result = await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId: "track-1", soundBank: { source: "gm" } },
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params["soundBank"], { source: "gm" });
  assert.deepEqual(parseJSON(result as any), queuedResult);
});

test("track_set_instrument never forwards soundBank at all when omitted", async () => {
  queuedResult = { kind: "polySynth" };

  const result = await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId: "track-1", waveform: "saw" },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params["soundBank"], undefined, "an omitted soundBank never reaches the app as a value");
  assert.equal(
    JSON.stringify(calls[0]!.params)?.includes("soundBank"),
    false,
    "an omitted soundBank does not appear in the JSON wire frame at all"
  );
  assert.deepEqual(parseJSON(result as any), queuedResult);
});

test("track_set_instrument surfaces the audioUnit+soundBank ambiguity error verbatim", async () => {
  queuedError = new Error("provide either audioUnit or soundBank, not both");

  const result = await client.callTool({
    name: "track_set_instrument",
    arguments: {
      trackId: "track-1",
      audioUnit: { subType: "samp", manufacturer: "appl" },
      soundBank: { source: "gm" },
    },
  });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.equal(r.content[0].text, "provide either audioUnit or soundBank, not both");
});

test("track_set_instrument surfaces a missing sound-bank-file error verbatim", async () => {
  queuedError = new Error("no sound bank file at /nope/x.sf2 — see instrument.listSoundBanks");

  const result = await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId: "track-1", soundBank: { source: "/nope/x.sf2" } },
  });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /instrument\.listSoundBanks/);
});

// ---------------------------------------------------------------------------
// soundBank.{program,bankMSB,bankLSB} zod boundary enforcement (0-127,
// hard-reject house style — see file-header note)
// ---------------------------------------------------------------------------

for (const field of ["program", "bankMSB", "bankLSB"] as const) {
  for (const boundary of [0, 127] as const) {
    test(`track_set_instrument accepts soundBank.${field} at the ${boundary} boundary`, async () => {
      queuedResult = { kind: "soundBank", soundBank: { source: "gm", program: 0, bankMSB: 121, bankLSB: 0, name: "x", status: "pending" } };

      const result = await client.callTool({
        name: "track_set_instrument",
        arguments: { trackId: "track-1", soundBank: { source: "gm", [field]: boundary } },
      });

      assert.equal(calls.length, 1);
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      assert.ok(!(result as any).isError);
    });
  }

  for (const outOfRange of [-1, 128, 1.5] as const) {
    test(`track_set_instrument rejects an out-of-range soundBank.${field} (${outOfRange}) at the schema layer, never reaching the bridge`, async () => {
      const result = await client.callTool({
        name: "track_set_instrument",
        arguments: { trackId: "track-1", soundBank: { source: "gm", [field]: outOfRange } },
      });

      assert.equal(calls.length, 0, "invalid arguments never reach bridge.send");
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const r = result as any;
      assert.ok(r.isError, "an out-of-range MIDI byte is a tool-call error, not a silent pass-through");
    });
  }
}

test("track_set_instrument requires soundBank.source when soundBank is provided (rejected at the schema layer)", async () => {
  const result = await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId: "track-1", soundBank: { program: 56 } },
  });

  assert.equal(calls.length, 0);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
});
