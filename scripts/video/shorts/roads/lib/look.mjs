#!/usr/bin/env node
// Merge a `look` override into a base payload and write a new payload.
// Keeps every rung of a ladder reproducible: the override that made a frame is
// stored next to the frame, rather than living in a shell variable.
//   node look.mjs <base-payload.json> <out-payload.json> '{"overhead":0.6}'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import path from 'node:path';
const [base, out, json] = process.argv.slice(2);
if (!base || !out) { console.error('usage: look.mjs <base> <out> <json-look>'); process.exit(2); }
const P = JSON.parse(readFileSync(base, 'utf8'));
const over = json ? JSON.parse(json) : {};
P.look = { ...(P.look || {}), ...over };
mkdirSync(path.dirname(path.resolve(out)), { recursive: true });
writeFileSync(out, JSON.stringify(P));
console.log(`look -> ${out}  ${JSON.stringify(over)}`);
