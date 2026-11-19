#!/usr/bin/env node
// One command to STAGING (17695), printed as JSON. The voice film's dawctl.
//   node ctl.mjs sing.sidecarStatus '{}'
//   node ctl.mjs --timeout 600000 render.mixdown '{"path":"..."}'
import { open, close, cmd } from "./wire.mjs";

const args = process.argv.slice(2);
let timeout = 60000;
if (args[0] === "--timeout") { args.shift(); timeout = Number(args.shift()); }
const [command, raw] = args;
if (!command) { console.error("usage: ctl.mjs [--timeout ms] <command> '<json>'"); process.exit(2); }
await open();
try {
  const r = await cmd(command, raw ? JSON.parse(raw) : {}, timeout);
  console.log(JSON.stringify(r, null, 2));
} catch (e) {
  console.error(String(e.message || e));
  process.exitCode = 1;
} finally {
  close();
  // ⚠ MEASURED 2026-10-10: Node's WebSocket waits for the server's close frame,
  // which this app does not send, so without an explicit exit the process
  // lingers after printing — and `| head` then never sees EOF.
  process.exit(process.exitCode ?? 0);
}
