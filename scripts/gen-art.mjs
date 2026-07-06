#!/usr/bin/env node
// Generate UI art assets with GPT Image (see .claude/skills/generate-assets).
// Usage: node scripts/gen-art.mjs --prompt "..." --out assets/generated/name.png
//        [--size 1024x1024] [--transparent]
import { writeFile, mkdir, readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

async function loadDotEnv() {
  try {
    const text = await readFile(resolve(repoRoot, ".env"), "utf8");
    for (const line of text.split("\n")) {
      const match = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
      if (match && !(match[1] in process.env)) process.env[match[1]] = match[2];
    }
  } catch {
    // no .env — rely on process env
  }
}

function arg(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  if (index === -1) return fallback;
  const value = process.argv[index + 1];
  return value && !value.startsWith("--") ? value : true;
}

await loadDotEnv();

const prompt = arg("prompt");
const out = arg("out");
if (typeof prompt !== "string" || typeof out !== "string") {
  console.error('usage: gen-art.mjs --prompt "..." --out path.png [--size WxH] [--transparent]');
  process.exit(1);
}
const apiKey = process.env.OPENAI_API_KEY;
if (!apiKey) {
  console.error("OPENAI_API_KEY is not set — add it to .env (see .env.example)");
  process.exit(1);
}

const body = {
  model: process.env.OPENAI_IMAGE_MODEL || "gpt-image-2",
  prompt,
  size: arg("size", "1024x1024"),
};
if (arg("transparent", false)) body.background = "transparent";

const response = await fetch("https://api.openai.com/v1/images/generations", {
  method: "POST",
  headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
  body: JSON.stringify(body),
});
if (!response.ok) {
  console.error(`OpenAI image request failed (${response.status}): ${await response.text()}`);
  process.exit(1);
}
const json = await response.json();
const b64 = json.data?.[0]?.b64_json;
if (!b64) {
  console.error("no image data in response");
  process.exit(1);
}

const outPath = resolve(repoRoot, out);
await mkdir(dirname(outPath), { recursive: true });
await writeFile(outPath, Buffer.from(b64, "base64"));
console.log(outPath);
