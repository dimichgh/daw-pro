#!/usr/bin/env node
// secret-scan — scan a diff for credentials before it becomes a commit.
//
// WHY IT HAS A SELF-TEST: a scanner that matches nothing and a diff with nothing to
// find produce IDENTICAL output. That confusion is this project's characteristic
// failure, and "I scanned it and it was clean" is worthless unless the scanner has
// just been shown to fire. `--self-test` runs every pattern against a synthetic
// positive and refuses to score if any pattern fails to match its own fixture.
//
// USAGE
//   node scripts/gates/secret-scan.mjs --self-test      # prove the patterns fire
//   git diff HEAD | node scripts/gates/secret-scan.mjs  # scan a real diff on stdin
//
// EXITS: 0 clean · 1 candidate secret found · 3 self-test failed (refused to score)

import { readFileSync } from "node:fs";

const EXIT_OK = 0, EXIT_FOUND = 1, EXIT_CONTROL = 3;

// Each rule carries its OWN positive fixture. A rule with no fixture cannot be
// self-tested, so adding one without a fixture is a hard error rather than a
// silently-unverified rule.
const RULES = [
  { name: "anthropic-key", re: /sk-ant-[A-Za-z0-9_-]{16,}/,
    fixture: "sk-ant-api03-" + "A".repeat(24) },
  { name: "openai-key", re: /\bsk-(?!ant-)[A-Za-z0-9]{32,}/,
    fixture: "sk-" + "B".repeat(40) },
  { name: "aws-access-key", re: /\bAKIA[0-9A-Z]{16}\b/,
    fixture: "AKIA" + "C".repeat(16) },
  { name: "github-pat", re: /\b(ghp|gho|ghs|ghu)_[A-Za-z0-9]{30,}\b/,
    fixture: "ghp_" + "D".repeat(36) },
  { name: "github-fine-grained", re: /\bgithub_pat_[A-Za-z0-9_]{40,}\b/,
    fixture: "github_pat_" + "E".repeat(60) },
  { name: "slack-token", re: /\bxox[abprs]-[A-Za-z0-9-]{10,}\b/,
    fixture: "xoxb-" + "1".repeat(20) },
  { name: "google-api-key", re: /\bAIza[0-9A-Za-z_-]{35}\b/,
    fixture: "AIza" + "F".repeat(35) },
  // ⚠️ Built by concatenation ON PURPOSE. Written as one literal, this fixture makes
  // THIS FILE trip its own scanner on every diff that touches it — which happened on
  // the first real run. The alternative was an allowlist entry for this path, and every
  // allowlist entry is a permanent hole; a fixture that assembles at runtime is not.
  { name: "private-key-block", re: /-----BEGIN (RSA |EC |OPENSSH |PGP )?PRIVATE KEY-----/,
    fixture: "-----BEGIN " + "RSA PRIVATE KEY" + "-----" },
  { name: "assigned-secret", re: /(?:api[_-]?key|secret|passwd|password|token)\s*[:=]\s*["'][^"'\s]{16,}["']/i,
    fixture: 'api_key = "' + "G".repeat(24) + '"' },
  { name: "bearer-literal", re: /\bBearer\s+[A-Za-z0-9._-]{24,}/,
    fixture: "Bearer " + "H".repeat(32) },
];

// Lines that legitimately look like secrets. Kept DELIBERATELY SHORT: every entry
// here is a hole in the scanner, so each must be justified, not convenient.
const ALLOW = [
  /process\.env\./,                 // reading a key is fine; embedding one is not
  /ProcessInfo\.processInfo\.environment/,
  /ANTHROPIC_API_KEY["']?\s*[,)\]]/, // naming the VARIABLE, not its value
  /your[_-]?api[_-]?key|<[A-Z_]+>|xxx+|\.\.\./i, // placeholders in docs
  /sk-ant-api03-EXAMPLE|EXAMPLE_KEY/i,
];

function scan(text) {
  const hits = [];
  const lines = text.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    // Only scan ADDED lines of a diff; a removed secret is a secret being deleted.
    if (/^(---|\+\+\+)/.test(line)) continue;
    if (text.includes("\ndiff --git ") && !line.startsWith("+")) continue;
    if (ALLOW.some((a) => a.test(line))) continue;
    for (const rule of RULES) {
      if (rule.re.test(line)) hits.push({ rule: rule.name, n: i + 1, line: line.slice(0, 120) });
    }
  }
  return hits;
}

function selfTest() {
  let bad = 0;
  for (const rule of RULES) {
    if (!rule.fixture) {
      console.error(`secret-scan: CONTROL FAILED — rule '${rule.name}' has no fixture`);
      bad++;
      continue;
    }
    // The fixture must match its own rule...
    if (!rule.re.test(rule.fixture)) {
      console.error(`secret-scan: CONTROL FAILED — rule '${rule.name}' does NOT match its own fixture`);
      bad++;
      continue;
    }
    // ...and must survive the allowlist, or the rule is dead in practice.
    if (ALLOW.some((a) => a.test(rule.fixture))) {
      console.error(`secret-scan: CONTROL FAILED — the allowlist swallows rule '${rule.name}'`);
      bad++;
      continue;
    }
    // ...and must be found by the real scanner, as an added diff line.
    if (scan("diff --git a/x b/x\n+" + rule.fixture).length === 0) {
      console.error(`secret-scan: CONTROL FAILED — scanner missed rule '${rule.name}' in a diff`);
      bad++;
      continue;
    }
    console.log(`  fires: ${rule.name}`);
  }
  // Negative control: innocuous text must NOT trip anything.
  const innocuous = "diff --git a/x b/x\n+let volume = 0.8  // a perfectly ordinary line\n";
  const fp = scan(innocuous);
  if (fp.length) {
    console.error(`secret-scan: CONTROL FAILED — ${fp.length} FALSE POSITIVE on innocuous text: ${fp[0].rule}`);
    bad++;
  } else {
    console.log("  negative control: innocuous line does not trip (good)");
  }
  if (bad) {
    console.error(`secret-scan: ${bad} control failure(s) — REFUSING TO SCORE`);
    process.exit(EXIT_CONTROL);
  }
  console.log(`secret-scan: self-test OK — ${RULES.length} rules all fire, no false positive.`);
  process.exit(EXIT_OK);
}

if (process.argv.includes("--self-test")) selfTest();

const input = process.argv[2] && process.argv[2] !== "-"
  ? readFileSync(process.argv[2], "utf8")
  : readFileSync(0, "utf8");

if (input.trim().length === 0) {
  console.error("secret-scan: CONTROL FAILED — empty input. An empty diff and a failed " +
                "pipe look identical; refusing to report 'clean'.");
  process.exit(EXIT_CONTROL);
}

const hits = scan(input);
if (hits.length) {
  console.error(`secret-scan: FAIL — ${hits.length} candidate secret(s):`);
  for (const h of hits) console.error(`  [${h.rule}] line ${h.n}: ${h.line}`);
  process.exit(EXIT_FOUND);
}
console.log(`secret-scan: clean — ${input.split("\n").length} lines scanned, ${RULES.length} rules.`);
process.exit(EXIT_OK);
