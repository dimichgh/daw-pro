#!/usr/bin/env node
// dawctl — the control-protocol client for DAW Pro's `debug.*` surface.
//
// WHY THIS EXISTS: the `debug.*` commands are app-tier. They are NOT on
// `CommandRouter.allCommands` and NOT on the MCP server, so no MCP tool can
// reach them. They are the only way to open a panel, drive a control, or take
// a screenshot — and therefore the only way to film the app. This talks to the
// same WebSocket the MCP bridge uses.
//
// Use as a CLI:
//     node dawctl.mjs debug.panelLayout '{"editorMaximized":true}'
//     node dawctl.mjs --quiet project.overview '{}'
// or as a library:
//     import { connect, send, close } from "./dawctl.mjs";
//
// Node 18+ has a global WebSocket; there is no `ws` dependency on purpose, so
// this runs from a plugin directory with no npm install.

const PORT = process.env.DAW_CONTROL_PORT || "17600";
const URL_ = `ws://127.0.0.1:${PORT}`;
const TIMEOUT_MS = Number(process.env.DAW_TIMEOUT_MS || 30000);

let ws = null;
let seq = 0;
const pending = new Map();

export function connect(url = URL_) {
  return new Promise((res, rej) => {
    ws = new WebSocket(url);
    const t = setTimeout(() => rej(new Error(`no DAW Pro on ${url} after 10s — is the app running?`)), 10000);
    ws.onopen = () => { clearTimeout(t); res(ws); };
    ws.onerror = (e) => { clearTimeout(t); rej(new Error(`${url}: ${e.message || "connection failed"}`)); };
    ws.onmessage = (ev) => {
      const m = JSON.parse(ev.data);
      const p = pending.get(m.id);
      if (p) { pending.delete(m.id); p(m); }
    };
    ws.onclose = () => {
      for (const [, p] of pending) p({ ok: false, error: "socket closed" });
      pending.clear();
    };
  });
}

// Every call is timed out. A `debug.*` verb that opens a panel occasionally
// never answers (a close on an already-closed panel is the known case), and an
// un-timed await there hangs the whole script after all its work is done —
// which looks exactly like a crash in the middle.
export function send(command, params = {}) {
  const id = `dawctl-${++seq}`;
  return new Promise((res, rej) => {
    const t = setTimeout(() => {
      pending.delete(id);
      rej(new Error(`${command}: no reply in ${TIMEOUT_MS}ms`));
    }, TIMEOUT_MS);
    pending.set(id, (m) => {
      clearTimeout(t);
      m.ok === false ? rej(new Error(`${command}: ${m.error}`)) : res(m.result ?? {});
    });
    ws.send(JSON.stringify({ id, command, params }));
  });
}

/** Send and swallow failure — for best-effort teardown. */
export const trySend = (c, p) => send(c, p).catch(() => null);

export function close() { try { ws?.close(); } catch {} }

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2);
  const quiet = args[0] === "--quiet" && args.shift();
  const [command, raw] = args;
  if (!command) {
    console.error("usage: dawctl.mjs [--quiet] <command> '<paramsJSON>'");
    process.exit(2);
  }
  await connect();
  try {
    const r = await send(command, raw ? JSON.parse(raw) : {});
    if (!quiet) console.log(JSON.stringify(r, null, 2));
    close();
    process.exit(0);
  } catch (e) {
    console.error(String(e.message || e));
    close();
    process.exit(1);
  }
}
