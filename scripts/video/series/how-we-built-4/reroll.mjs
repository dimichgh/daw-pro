import { open, cmd, close } from "../../session/build.mjs";
import { readFileSync } from "node:fs";
const HERE = "/Users/dsemenov/Views/daw-pro/scripts/video/series/how-we-built-4";
await open();
const T = JSON.parse(readFileSync(`${HERE}/ids.json`, "utf8")).ids;
for (const k of ["Bass", "Lead", "Pad"]) {
  const n = await cmd("clip.getNotes", { clipId: T[`${k}:clip`] });
  const ps = n.notes.map(x => x.pitch);
  console.log(k, "notes", n.totalNotes ?? ps.length, "pitch", Math.min(...ps), "..", Math.max(...ps),
              "median", ps.slice().sort((a,b)=>a-b)[Math.floor(ps.length/2)]);
}
await close();

process.exit(0);
