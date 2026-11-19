// wire.mjs — the control-protocol client for the voice film. STAGING ONLY.
//
// ⛔ WHY THIS FILE AND NOT claude-plugin/skills/ui-capture/scripts/dawctl.mjs:
// dawctl reads DAW_CONTROL_PORT and DAW_TIMEOUT_MS at IMPORT time and its port
// DEFAULTS TO 17600 — the user's live app. A static import is hoisted above any
// `process.env.X = …` line, so a script that sets the port and then imports
// dawctl gets the default (features/README's hoisting trap, which sprang). This
// client has NO default: the port is 17695, refused if anything else, and every
// call carries its own timeout so a long render does not depend on a shell
// export having been typed.
//
// Envelope (measured from dawctl.mjs): send {id, command, params}; reply
// {id, ok, result, error}.

export const VOICE_HOME = process.env.VOICE_HOME
  || new URL(".", import.meta.url).pathname.replace(/\/$/, "");

const PORT = 17695;
if (process.env.DAW_CONTROL_PORT && process.env.DAW_CONTROL_PORT !== String(PORT)) {
  console.error(`REFUSING: DAW_CONTROL_PORT=${process.env.DAW_CONTROL_PORT}. This film talks to staging on ${PORT} only; 17600 is the user's live app.`);
  process.exit(1);
}

let ws = null;
let seq = 0;
const pending = new Map();

export function open() {
  return new Promise((res, rej) => {
    ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
    const t = setTimeout(() => rej(new Error(`no staging app on ${PORT} after 10 s`)), 10000);
    ws.onopen = () => { clearTimeout(t); res(); };
    ws.onerror = (e) => { clearTimeout(t); rej(new Error(`ws ${PORT}: ${e.message || "connection failed"}`)); };
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

export function close() { try { ws?.close(); } catch {} }

/** Send one command. Rejects on {ok:false} with the app's own words. */
export function cmd(command, params = {}, timeoutMs = 60000) {
  const id = `voice-${++seq}`;
  return new Promise((res, rej) => {
    const t = setTimeout(() => {
      pending.delete(id);
      rej(new Error(`${command}: no reply in ${timeoutMs} ms`));
    }, timeoutMs);
    pending.set(id, (m) => {
      clearTimeout(t);
      m.ok === false ? rej(new Error(`${command}: ${typeof m.error === "string" ? m.error : JSON.stringify(m.error)}`))
                     : res(m.result ?? {});
    });
    ws.send(JSON.stringify({ id, command, params }));
  });
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Route STAGING's output to BlackHole by UID and PROVE it took (isSelected). */
export async function silence() {
  const UID = "BlackHole2ch_UID";
  await cmd("output.setDevice", { uid: UID });
  const { devices } = await cmd("output.listDevices", {});
  const sel = (devices || []).find((d) => d.isSelected);
  if (!sel || sel.uid !== UID) {
    throw new Error(`REFUSING TO PLAY: staging output is ${sel ? sel.name : "unset"}, not BlackHole.`);
  }
  return sel;
}
