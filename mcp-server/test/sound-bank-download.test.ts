/**
 * sound-bank-download.test.ts — the four one-click SoundFont download tools
 * (m34-c).
 *
 * Same stub-bridge pattern as vc.test.ts: the REAL `McpServer` from
 * `src/server.ts` is driven over an in-memory transport with
 * `DawBridge.prototype.send` monkeypatched, so no app and no network are
 * involved. Asserts:
 *   - each tool forwards exactly its matching control command, with exactly
 *     the parameters it should (three of the four take none)
 *   - a stubbed status payload round-trips back unchanged
 *   - the app's teaching errors surface as MCP tool errors, verbatim
 *   - the two MUTATING tools reject an unrecognized argument at the MCP
 *     boundary (the strict-schema convention), and the reads do not need to
 *   - the descriptions carry the two claims that are easy to get wrong and
 *     expensive when wrong: that a `succeeded` STATE (not an accepted request)
 *     is what "installed" means, and that the pinned SHA-256 is an integrity
 *     check, NOT a provenance one
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
  client = new Client({ name: "sound-bank-download-test-client", version: "0.0.0" });
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

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function descriptionOf(name: string): Promise<string> {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === name);
  assert.ok(tool, `${name} is not registered`);
  return `${tool!.description ?? ""}`;
}

// ---------------------------------------------------------------------------
// instrument_list_downloadable_sound_banks
// ---------------------------------------------------------------------------

test("instrument_list_downloadable_sound_banks takes no params and forwards the catalogue read", async () => {
  const stubbed = {
    banks: [
      {
        id: "musescore-general",
        name: "MuseScore General",
        // Mirrors the app's real catalogue entry: the primary moved to our own
        // release asset 2026-08-30 (upstream is kept as a fallback app-side).
        // This is a STUB of the bridge's reply, so it only has to stay honest.
        url: "https://github.com/dimichgh/daw-pro/releases/download/soundbanks-v1/MuseScore_General.sf2",
        fileName: "MuseScore_General.sf2",
        sizeBytes: 215614036,
        sizeDescription: "216 MB",
        sha256: "ee51d2c4b1525e70f19a45909c4fd7a2e26d91d115fa89dbf5a6bc413d8b9bf3",
        licence: "MIT",
        attribution: "Copyright © 2014–2016 Michael Cowgill, © 2000–2002, 2008 Frank Wen. MIT licence.",
        summary: "A full set of 128 instruments plus around fifteen drum kits.",
        installed: false,
      },
    ],
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "instrument_list_downloadable_sound_banks",
    arguments: {},
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "instrument.listDownloadableSoundBanks");
  assert.deepEqual(calls[0]!.params, {}, "this command takes no params");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed, "the app's response round-trips verbatim");
});

test("the catalogue tool labels its checksum as integrity, NOT provenance", async () => {
  const description = await descriptionOf("instrument_list_downloadable_sound_banks");
  // No publisher signs this file. An agent that tells a user the hash proves
  // where the bytes CAME FROM would be claiming a guarantee nobody has.
  assert.match(description, /INTEGRITY/i);
  assert.match(description, /SELF-COMPUTED/i);
  assert.match(description, /NOT a publisher signature/i);
  assert.match(description, /provenance/i);
  // The licence terms are the point of this tool existing at all.
  assert.match(description, /licence/i);
  assert.match(description, /verbatim/i);
});

// ---------------------------------------------------------------------------
// instrument_download_sound_bank
// ---------------------------------------------------------------------------

test("instrument_download_sound_bank forwards the catalogue id", async () => {
  queuedResult = {
    state: "downloading",
    bankID: "musescore-general",
    bankName: "MuseScore General",
    cancelRequested: false,
  };

  const result = await client.callTool({
    name: "instrument_download_sound_bank",
    arguments: { id: "musescore-general" },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "instrument.downloadSoundBank");
  assert.deepEqual(calls[0]!.params, { id: "musescore-general" });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.equal(parseJSON(result as any).state, "downloading");
});

test("instrument_download_sound_bank requires id and rejects extras at the MCP boundary", async () => {
  const missing = await client.callTool({
    name: "instrument_download_sound_bank",
    arguments: {},
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((missing as any).isError, "a missing id must not reach the bridge");
  assert.equal(calls.length, 0);

  const extra = await client.callTool({
    name: "instrument_download_sound_bank",
    arguments: { id: "musescore-general", overwrite: true },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((extra as any).isError, "an unrecognized argument is rejected, never silently stripped");
  assert.equal(calls.length, 0, "the bridge is never reached");
});

test("instrument_download_sound_bank says plainly that an accepted request is not an install", async () => {
  const description = await descriptionOf("instrument_download_sound_bank");
  assert.match(description, /RETURNS IMMEDIATELY/);
  assert.match(description, /never that a bank is installed/);
  assert.match(description, /succeeded/);
  // The user's bandwidth and disk — the size and licence come first.
  assert.match(description, /216 MB/);
  assert.match(description, /BEFORE starting/);
});

test("a refused second download surfaces the app's own sentence verbatim", async () => {
  queuedError = new Error(
    'Already downloading "MuseScore General" — poll instrument.soundBankDownloadStatus and ' +
      "wait for it to reach a terminal state (succeeded, failed or cancelled) before starting " +
      '"MuseScore General". Only one sound-bank download runs at a time.'
  );

  const result = await client.callTool({
    name: "instrument_download_sound_bank",
    arguments: { id: "musescore-general" },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "a refusal is a tool error, never a silent success");
  assert.match(r.content[0].text as string, /Only one sound-bank download runs at a time/);
});

// ---------------------------------------------------------------------------
// instrument_sound_bank_download_status
// ---------------------------------------------------------------------------

test("instrument_sound_bank_download_status takes no params and round-trips a terminal payload", async () => {
  const stubbed = {
    state: "succeeded",
    bankID: "musescore-general",
    bankName: "MuseScore General",
    cancelRequested: false,
    progress: {
      phase: "finished",
      bankID: "musescore-general",
      phaseFraction: 1,
      completedBytes: 215614036,
      totalBytes: 215614036,
    },
    bank: {
      source: "/Users/x/Library/Application Support/DAWPro/SoundBanks/MuseScore_General.sf2",
      name: "MuseScore_General",
      path: "/Users/x/Library/Application Support/DAWPro/SoundBanks/MuseScore_General.sf2",
      format: "sf2",
      builtin: false,
      sizeBytes: 215614036,
    },
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "instrument_sound_bank_download_status",
    arguments: {},
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "instrument.soundBankDownloadStatus");
  assert.deepEqual(calls[0]!.params, {});
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("the status tool warns that phaseFraction is not overall progress, and that failures leave nothing", async () => {
  const description = await descriptionOf("instrument_sound_bank_download_status");
  assert.match(description, /WITHIN the current phase/);
  assert.match(description, /NOT overall progress/);
  assert.match(description, /not a hang/);
  assert.match(description, /leaves NOTHING in the library/);
  assert.match(description, /cancelling/i);
});

// ---------------------------------------------------------------------------
// instrument_cancel_sound_bank_download
// ---------------------------------------------------------------------------

test("instrument_cancel_sound_bank_download takes no params and forwards the cancel", async () => {
  queuedResult = {
    state: "downloading",
    bankID: "musescore-general",
    bankName: "MuseScore General",
    cancelRequested: true,
  };

  const result = await client.callTool({
    name: "instrument_cancel_sound_bank_download",
    arguments: {},
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "instrument.cancelSoundBankDownload");
  assert.deepEqual(calls[0]!.params, {});
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const payload = parseJSON(result as any);
  assert.equal(payload.cancelRequested, true);
  assert.equal(payload.state, "downloading", "cancellation is requested, then observed by polling");
});

test("instrument_cancel_sound_bank_download rejects an unrecognized argument", async () => {
  const result = await client.callTool({
    name: "instrument_cancel_sound_bank_download",
    arguments: { id: "musescore-general" },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError, "there is one download slot — naming one is a caller mistake");
  assert.equal(calls.length, 0);
});

test("the cancel tool tells the caller NOT to claim it stopped until the state says so", async () => {
  const description = await descriptionOf("instrument_cancel_sound_bank_download");
  assert.match(description, /STILL SAYS/);
  assert.match(description, /cancelRequested/);
  assert.match(description, /do not tell the user it stopped/i);
  assert.match(description, /Refused when nothing is running/);
});

// ---------------------------------------------------------------------------
// All four exist, and nothing else moved
// ---------------------------------------------------------------------------

test("all four download tools are registered under their mechanical names", async () => {
  const listed = await client.listTools();
  const names = new Set(listed.tools.map((t) => t.name));
  for (const expected of [
    "instrument_list_downloadable_sound_banks",
    "instrument_download_sound_bank",
    "instrument_sound_bank_download_status",
    "instrument_cancel_sound_bank_download",
  ]) {
    assert.ok(names.has(expected), `${expected} is missing`);
  }
  // Negative control: a plausible name that should NOT exist, so a passing
  // membership check above is evidence and not a tautology.
  assert.ok(!names.has("instrument_download_soundfont"));
  // The pre-existing sound-bank tools are untouched — this item is additive.
  for (const untouched of [
    "instrument_list_sound_banks",
    "instrument_list_sound_bank_programs",
    "instrument_import_sound_bank",
  ]) {
    assert.ok(names.has(untouched), `${untouched} disappeared`);
  }
});
