/**
 * ai.test.ts — stub-fetch unit coverage for src/ai.ts's Anthropic/OpenAI
 * clients (m10-o: migrated the hand-rolled `fetch` calls onto the official
 * `@anthropic-ai/sdk` and `openai` packages — USER DIRECTIVE to use standard
 * SDKs instead of a hand-rolled parser).
 *
 * Unlike copilot.test.ts / sound-banks.test.ts (which drive the real
 * `McpServer` over an in-memory transport and stub `DawBridge.prototype.send`),
 * `ai.ts` never touches the control-protocol bridge — it calls provider APIs
 * directly. So this suite exercises `src/ai.ts`'s exported functions
 * directly and uses the test-only `__setFetchForTests` seam (see src/ai.ts)
 * to intercept the SDK's outbound HTTP call at the fetch layer. That means
 * these tests exercise the REAL SDK request construction and response/error
 * parsing, never the network and never a real API key.
 *
 * Env vars are saved/restored around every test: the project's `npm test`
 * invocation pre-sets ANTHROPIC_API_KEY/OPENAI_API_KEY/SUNO_API_KEY to dummy
 * staging values (see m10-t — those dummy keys exist to dodge a Keychain
 * hang in integration.test.ts's spawned app), so this suite cannot assume a
 * clean env; each test explicitly sets or deletes exactly the keys it needs.
 */

import { test, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { readFile, rm, rmdir } from "node:fs/promises";
import { dirname, join } from "node:path";

import { generateImage, generateLyrics, generateSongSuno, __setFetchForTests } from "../src/ai.js";

// ---------------------------------------------------------------------------
// Env isolation
// ---------------------------------------------------------------------------

const ENV_KEYS = [
  "ANTHROPIC_API_KEY",
  "OPENAI_API_KEY",
  "SUNO_API_KEY",
  "OPENAI_TEXT_MODEL",
  "OPENAI_IMAGE_MODEL",
  "SUNO_API_BASE",
] as const;

let savedEnv: Partial<Record<(typeof ENV_KEYS)[number], string | undefined>>;

beforeEach(() => {
  savedEnv = {};
  for (const key of ENV_KEYS) {
    savedEnv[key] = process.env[key];
    delete process.env[key];
  }
});

afterEach(() => {
  for (const key of ENV_KEYS) {
    const value = savedEnv[key];
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  __setFetchForTests(undefined);
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function headerValue(init: RequestInit | undefined, name: string): string | null {
  return new Headers(init?.headers).get(name);
}

function parsedBody(init: RequestInit | undefined): Record<string, unknown> {
  return init?.body ? JSON.parse(init.body as string) : {};
}

const anthropicMessage = (content: Array<Record<string, unknown>>) => ({
  id: "msg_test",
  type: "message",
  role: "assistant",
  model: "claude-sonnet-5",
  content,
  stop_reason: "end_turn",
  stop_sequence: null,
  usage: { input_tokens: 1, output_tokens: 1 },
});

const openAiChatCompletion = (content: string | null) => ({
  id: "chatcmpl_test",
  object: "chat.completion",
  created: 0,
  model: "gpt-4o",
  choices: [{ index: 0, message: { role: "assistant", content }, finish_reason: "stop" }],
});

// ---------------------------------------------------------------------------
// generateLyrics — provider preference
// ---------------------------------------------------------------------------

test("generateLyrics prefers anthropic when both ANTHROPIC_API_KEY and OPENAI_API_KEY are set", async () => {
  process.env["ANTHROPIC_API_KEY"] = "sk-ant-fake-key-anthropic-first";
  process.env["OPENAI_API_KEY"] = "sk-oai-fake-key-should-not-be-used";

  let calledUrl: string | undefined;
  let sentKey: string | null = null;
  __setFetchForTests(async (input, init) => {
    calledUrl = String(input);
    sentKey = headerValue(init, "x-api-key");
    return jsonResponse(200, anthropicMessage([{ type: "text", text: "[Verse 1]\nanthropic line" }]));
  });

  const result = await generateLyrics({ theme: "a rainy Tuesday" });

  assert.equal(result.provider, "anthropic");
  assert.equal(result.lyrics, "[Verse 1]\nanthropic line");
  assert.ok(calledUrl?.includes("api.anthropic.com"), `expected an anthropic URL, got: ${calledUrl}`);
  assert.equal(sentKey, "sk-ant-fake-key-anthropic-first", "the exact env key is passed explicitly to the client");
});

test("generateLyrics falls back to openai when only OPENAI_API_KEY is set", async () => {
  process.env["OPENAI_API_KEY"] = "sk-oai-fake-key-fallback";

  let calledUrl: string | undefined;
  let sentAuth: string | null = null;
  __setFetchForTests(async (input, init) => {
    calledUrl = String(input);
    sentAuth = headerValue(init, "authorization");
    return jsonResponse(200, openAiChatCompletion("[Verse 1]\nopenai fallback line"));
  });

  const result = await generateLyrics({ theme: "a rainy Tuesday" });

  assert.equal(result.provider, "openai");
  assert.equal(result.lyrics, "[Verse 1]\nopenai fallback line");
  assert.ok(calledUrl?.includes("api.openai.com"), `expected an openai URL, got: ${calledUrl}`);
  assert.equal(sentAuth, "Bearer sk-oai-fake-key-fallback");
});

test("generateLyrics throws the exact missing-keys error when neither key is set", async () => {
  await assert.rejects(() => generateLyrics({ theme: "x" }), (err: unknown) => {
    assert.ok(err instanceof Error);
    assert.equal(
      err.message,
      "Missing required API key(s): ANTHROPIC_API_KEY, OPENAI_API_KEY. " +
        "Set them in your .env file (see .env.example) or export them in the environment " +
        "the MCP server runs in, then retry."
    );
    return true;
  });
});

// ---------------------------------------------------------------------------
// Anthropic response parsing
// ---------------------------------------------------------------------------

test("generateLyrics (anthropic) joins ALL text blocks and skips non-text blocks — the m10-a regression pin", async () => {
  process.env["ANTHROPIC_API_KEY"] = "sk-ant-fake-key";
  __setFetchForTests(async () =>
    jsonResponse(
      200,
      anthropicMessage([
        { type: "thinking", thinking: "let me plan the verses...", signature: "sig" },
        { type: "text", text: "[Verse 1]\nfirst block" },
        { type: "text", text: "[Chorus]\nsecond block" },
      ])
    )
  );

  const result = await generateLyrics({ theme: "regression pin" });
  assert.equal(result.lyrics, "[Verse 1]\nfirst block\n[Chorus]\nsecond block");
});

test("generateLyrics (anthropic) throws 'no text content' when the response has no text blocks", async () => {
  process.env["ANTHROPIC_API_KEY"] = "sk-ant-fake-key";
  __setFetchForTests(async () =>
    jsonResponse(200, anthropicMessage([{ type: "thinking", thinking: "no output at all", signature: "sig" }]))
  );

  await assert.rejects(
    () => generateLyrics({ theme: "x" }),
    /Anthropic API returned no text content for the lyrics request\./
  );
});

// ---------------------------------------------------------------------------
// OpenAI response parsing
// ---------------------------------------------------------------------------

test("generateLyrics (openai) throws 'no content' when message.content is null", async () => {
  process.env["OPENAI_API_KEY"] = "sk-oai-fake-key";
  __setFetchForTests(async () => jsonResponse(200, openAiChatCompletion(null)));

  await assert.rejects(
    () => generateLyrics({ theme: "x" }),
    /OpenAI API returned no content for the lyrics request\./
  );
});

test("generateLyrics (openai) honors the OPENAI_TEXT_MODEL override", async () => {
  process.env["OPENAI_API_KEY"] = "sk-oai-fake-key";
  process.env["OPENAI_TEXT_MODEL"] = "gpt-test-model";

  let sentModel: unknown;
  __setFetchForTests(async (_input, init) => {
    sentModel = parsedBody(init)["model"];
    return jsonResponse(200, openAiChatCompletion("[Verse 1]\nmodel override line"));
  });

  await generateLyrics({ theme: "x" });
  assert.equal(sentModel, "gpt-test-model");
});

// ---------------------------------------------------------------------------
// Provider errors — informative, never leak the key
// ---------------------------------------------------------------------------

test("generateLyrics (anthropic) surfaces a provider error's status + detail without leaking the key", async () => {
  const fakeKey = "sk-ant-super-secret-should-never-appear-in-errors";
  process.env["ANTHROPIC_API_KEY"] = fakeKey;
  __setFetchForTests(async () =>
    jsonResponse(401, { type: "error", error: { type: "authentication_error", message: "invalid x-api-key" } })
  );

  await assert.rejects(() => generateLyrics({ theme: "x" }), (err: unknown) => {
    assert.ok(err instanceof Error);
    assert.match(err.message, /401/);
    assert.match(err.message, /invalid x-api-key/);
    assert.ok(!err.message.includes(fakeKey), "thrown error must never contain the API key");
    return true;
  });
});

test("generateLyrics (openai) surfaces a provider error's status + detail without leaking the key", async () => {
  const fakeKey = "sk-oai-super-secret-should-never-appear-in-errors";
  process.env["OPENAI_API_KEY"] = fakeKey;
  __setFetchForTests(async () =>
    jsonResponse(429, { error: { message: "Rate limit exceeded for this model.", type: "rate_limit_error" } })
  );

  await assert.rejects(() => generateLyrics({ theme: "x" }), (err: unknown) => {
    assert.ok(err instanceof Error);
    assert.match(err.message, /429/);
    assert.match(err.message, /Rate limit exceeded/);
    assert.ok(!err.message.includes(fakeKey), "thrown error must never contain the API key");
    return true;
  });
});

// ---------------------------------------------------------------------------
// generateImage
// ---------------------------------------------------------------------------

test("generateImage happy path: writes bytes matching b64_json under assets/generated/ and returns the path", async () => {
  process.env["OPENAI_API_KEY"] = "sk-oai-fake-key";
  process.env["OPENAI_IMAGE_MODEL"] = "gpt-image-test-model";

  // Smallest valid 1x1 PNG, base64-encoded.
  const pngBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";

  let capturedBody: Record<string, unknown> = {};
  __setFetchForTests(async (_input, init) => {
    capturedBody = parsedBody(init);
    return jsonResponse(200, { created: 0, data: [{ b64_json: pngBase64 }] });
  });

  const promptSlug = "m10-o-ai-test-image-safe-to-delete";
  const result = await generateImage({ prompt: promptSlug });

  try {
    assert.ok(result.filePath.endsWith(".png"), `expected a .png path, got: ${result.filePath}`);
    assert.ok(
      result.filePath.includes(join("assets", "generated")),
      `expected the file under assets/generated/, got: ${result.filePath}`
    );
    assert.ok(result.filePath.includes(promptSlug), "file name derives from the slugified prompt");

    const written = await readFile(result.filePath);
    assert.deepEqual(written, Buffer.from(pngBase64, "base64"), "written bytes match the decoded b64_json exactly");

    assert.equal(capturedBody["model"], "gpt-image-test-model", "SDK called with the OPENAI_IMAGE_MODEL override");
    assert.equal(capturedBody["size"], "1024x1024", "SDK called with the default size");
    assert.equal(capturedBody["prompt"], promptSlug);
  } finally {
    await rm(result.filePath, { force: true });
    // Best-effort tidy-up: only removes dirs this test's write may have
    // created, and only if now empty; never throws if they pre-existed
    // non-empty or don't exist.
    const generatedDir = dirname(result.filePath);
    await rmdir(generatedDir).catch(() => {});
    await rmdir(dirname(generatedDir)).catch(() => {});
  }
});

test("generateImage throws the exact missing-keys error when OPENAI_API_KEY is unset", async () => {
  await assert.rejects(() => generateImage({ prompt: "x" }), (err: unknown) => {
    assert.ok(err instanceof Error);
    assert.equal(
      err.message,
      "Missing required API key(s): OPENAI_API_KEY. " +
        "Set them in your .env file (see .env.example) or export them in the environment " +
        "the MCP server runs in, then retry."
    );
    return true;
  });
});

// ---------------------------------------------------------------------------
// generateSongSuno — no official SDK, stays on raw fetch; missing-key case
// needs no fetch stub since it throws before any network call.
// ---------------------------------------------------------------------------

test("generateSongSuno throws the exact missing-key error when SUNO_API_KEY is unset", async () => {
  await assert.rejects(() => generateSongSuno({ prompt: "a driving synthwave instrumental" }), (err: unknown) => {
    assert.ok(err instanceof Error);
    assert.equal(
      err.message,
      "Missing required API key(s): SUNO_API_KEY. " +
        "Set them in your .env file (see .env.example) or export them in the environment " +
        "the MCP server runs in, then retry."
    );
    return true;
  });
});
