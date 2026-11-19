// shoot.mjs — stills through debug.captureUI (the user's stated DEFAULT: no app
// on screen). Library only: import { shot } and call it after open().
//
// ⚠ A wrong screenshot and a right one are both {"ok":true} plus a valid PNG.
// Every still is LOOKED AT afterwards (the LOOK report); `shot` only guarantees
// the file exists, is non-trivial, and is not byte-identical to the previous
// one (identical bytes = the change you meant to photograph never took).
import { mkdirSync, statSync, readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { cmd, sleep, VOICE_HOME } from "./wire.mjs";

export const SHOTS = `${VOICE_HOME}/out/shots`;
mkdirSync(SHOTS, { recursive: true });
let last = null;

export async function shot(name, extra = {}) {
  await sleep(extra.settleMs ?? 350);      // let SwiftUI land the last change
  const { settleMs, ...params } = extra;
  const path = `${SHOTS}/${name}.png`;
  const r = await cmd("debug.captureUI", { path, ...params }, 30000);
  const size = statSync(path).size;
  if (size < 20000) throw new Error(`${name}: ${size} B — not a real capture`);
  const md5 = createHash("md5").update(readFileSync(path)).digest("hex");
  if (md5 === last) console.warn(`⚠ ${name} is BYTE-IDENTICAL to the previous shot — did the change take?`);
  last = md5;
  console.log(`shot ${name}  ${r.width}x${r.height}  ${size} B`);
  return path;
}
