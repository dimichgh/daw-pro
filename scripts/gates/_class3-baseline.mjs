// _class3-baseline.mjs — run an UNCONVERTED class-3 gate against a FRESH staging
// instance, then tear it down.
//
// WHY THIS EXISTS (m23-ac-3a). A class-3 gate never launches anything; it drives
// whatever happens to be listening on 17695. So when you convert one and it goes
// red, the result is AMBIGUOUS in the worst way: it can mean the conversion broke
// the gate, or it can mean the gate never passed standalone and had only ever run
// against an instance a human had prepared by hand.
//
// The only way to tell them apart is to measure the gate's behaviour against a
// fresh instance BEFORE touching it. Red on both sides exonerates the conversion
// and turns the result into a finding ("this gate was never green") rather than a
// regression to chase.
//
// ⚠️ ONE FRESH INSTANCE PER GATE. Running several gates against a single instance
//    lets the first gate's state leak into the second, which is precisely NOT the
//    condition a converted gate creates for itself. This script launches and tears
//    down per invocation for that reason — resist the urge to batch it.
//
// ARGUMENTS ARE FORWARDED (m23-ac-3b-1). Everything after the gate path is passed
// through to the gate untouched. This is not a convenience: 6 of the 14 gates in
// ac-3b read `process.argv[2]` for an output directory, and three of them
// (m23m3, m23m3b, m23m3c) have NO default — without forwarding they cannot be
// baselined AT ALL. m23m3b at least exits 2 with a usage line; the other two would
// silently build paths out of the string "undefined". A baseline harness that
// quietly mangles its subject is worse than no harness, because the transcript it
// produces looks like a real measurement.
//
// ⚠️ THIS HARNESS CAN INDUCE ONE SPECIFIC FALSE FAILURE (measured, m23-ac-3e-3).
//    It launches the app as ITS OWN child and then blocks in spawnSync running
//    the gate. So while the gate runs, this process cannot reap. If the gate
//    kills the staging app itself and then asks "is it gone?" with
//    `process.kill(pid, 0)`, the answer is YES-STILL-ALIVE — because the app is
//    a ZOMBIE, not because it is running. `kill -0` succeeds on a zombie.
//
//    Measured with /bin/sleep (which dies instantly on SIGTERM, so shutdown
//    latency plays no part): parent-blocked-in-spawnSync gives `ps stat=Z` and
//    stillUp=true; the same kill from the process that OWNS the child gives
//    `(gone)` and stillUp=false. m23c2's Leg 6 does exactly this, and failed
//    that check on both baseline runs and passed it on both converted runs —
//    the CONVERSION is the correct side there, not the baseline.
//
//    Only gates that kill their own app are affected (in this corpus, only
//    m23c2). If you baseline such a gate, expect that one leg to lie.
//
// Usage:  node scripts/gates/_class3-baseline.mjs scripts/gates/<gate>.mjs [gate args…]
// Exit:   the gate's own exit code (so `rc` stays comparable across the conversion).
import { spawnSync } from "node:child_process";
import { buildOrAbort, startStaging, stopStaging, connect } from "./_staging.mjs";

const [, , gateScript, ...gateArgs] = process.argv;
if (!gateScript) {
  console.log("usage: node scripts/gates/_class3-baseline.mjs <gate.mjs> [gate args…]");
  process.exit(2);
}

const GATE = "class3-baseline";

buildOrAbort({ label: `building for class-3 baseline of ${gateScript}…` });
startStaging({ gate: GATE });

// Wait for the app to actually accept connections before handing it to the gate —
// otherwise the gate races the boot and its own retry loop masks the difference.
const ws = await connect();
try { ws.close(); } catch { /* ignore */ }

const r = spawnSync("node", [gateScript, ...gateArgs], { stdio: "inherit" });

stopStaging(GATE);
process.exit(r.status ?? 1);
