/**
 * pan-law-text.test.ts — W9-W45 (m39-panlaw-new-wire): an agent must be able to
 * learn which pan rule a song uses. Text pins on `project_snapshot` and
 * `track_set_pan`; the app side (the `panLaw` key on the snapshot reply) is
 * pinned in Swift (`w45SnapshotReportsThePanLaw`).
 */

import { test, before, after } from "node:test";
import assert from "node:assert/strict";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { DawBridge } from "../src/bridge.js";

DawBridge.prototype.send = async function (): Promise<unknown> {
  return {};
};

const { server } = await import("../src/server.js");

let client: Client;

before(async () => {
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  client = new Client({ name: "pan-law-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
});

async function description(name: string): Promise<string> {
  const { tools } = await client.listTools();
  const tool = tools.find((t) => t.name === name);
  assert.ok(tool, `${name} is registered`);
  return tool!.description ?? "";
}

test("track_set_pan says in plain words which rule new and older songs use", async () => {
  const text = await description("track_set_pan");
  assert.match(text, /songs made from now on, the pan knob keeps a sound equally loud as it moves/);
  assert.match(text, /near side gets up to 3 dB louder/);
  assert.match(text, /Older songs keep the original rule/);
  assert.match(text, /`panLaw`/);
});

test("project_snapshot documents panLaw and that a missing key means the original rule", async () => {
  const text = await description("project_snapshot");
  assert.match(text, /`panLaw`/);
  assert.match(text, /"equalPower"/);
  assert.match(text, /"balance"/);
  assert.match(text, /read a missing `panLaw` as `balance`/);
});
