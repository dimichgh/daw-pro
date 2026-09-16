// Re-derives media/material.json's `counts` block FROM material.mjs, without
// re-rendering audio. shoot.mjs writes the same block; this exists so a counts
// key added after the renders can reach the measurement chain without spending
// a full render pass on staging. It DERIVES -- it never types a number in.
import fs from "fs";
import * as M from "./material.mjs";
const p = new URL("./media/material.json", import.meta.url).pathname;
const j = JSON.parse(fs.readFileSync(p, "utf8"));
const before = JSON.stringify(j.counts);
j.counts = M.COUNTS;
fs.writeFileSync(p, JSON.stringify(j, null, 1));
console.log("before:", before);
console.log("after :", JSON.stringify(j.counts));
