/**
 * sing-x7d-tools.test.ts — p2-sing-x7d: `sing_render`'s text for `lyrics` + `parts` (a refused request changes
 * nothing; the dry run previews parts over new words). Description only: no param changes.
 */

import { test, before, after } from "node:test";
import assert from "node:assert/strict";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { DawBridge } from "../src/bridge.js";

DawBridge.prototype.send = async function (): Promise<unknown> {
  return { ok: true };
};

const { server } = await import("../src/server.js");

let client: Client;

before(async () => {
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  client = new Client({ name: "sing-x7d-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
});

test("sing_render's text: a dry run previews parts over new lyrics; a refused request changes nothing", async () => {
  const tool = (await client.listTools()).tools.find((t) => t.name === "sing_render");
  assert.ok(tool, "sing_render must be listed");
  const text = tool!.description ?? "";
  assert.match(text, /over new `lyrics` too; nothing is sung or saved/);
  assert.match(text, /a refused request changes nothing \(not the words, not the undo or redo history\)/);
  assert.doesNotMatch(text, /partsNote/);
  assert.doesNotMatch(text, /the words are put back/);
});
