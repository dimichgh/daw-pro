/**
 * Direct AI-provider clients for the MCP server (docs/AI-INTEGRATIONS.md).
 *
 * Anthropic and OpenAI calls go through the official `@anthropic-ai/sdk` and
 * `openai` npm packages (m10-o — USER DIRECTIVE: use the standard SDKs
 * instead of hand-rolled HTTP/JSON parsing). Suno has no official SDK as of
 * 2026-07, so `generateSongSuno` remains a hand-rolled `fetch` call — see its
 * doc comment below for why. Keys are read from environment variables only
 * (populated from `.env` by whatever launches this process), passed
 * explicitly to each SDK client constructor (never relying on the SDKs'
 * ambient env pickup, since the anthropic-first selection logic below needs
 * to inspect the keys itself anyway), and are never logged or included in
 * thrown error messages.
 */

import Anthropic, { APIError as AnthropicAPIError } from "@anthropic-ai/sdk";
import OpenAI, { APIError as OpenAiAPIError } from "openai";

import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ANTHROPIC_MODEL = "claude-sonnet-5";
const DEFAULT_OPENAI_TEXT_MODEL = "gpt-4o";
const DEFAULT_OPENAI_IMAGE_MODEL = "gpt-image-2";
const DEFAULT_SUNO_API_BASE = "https://api.suno.com/v1";

const LYRICIST_SYSTEM_PROMPT =
  "You are a professional lyricist and songwriter who works inside a digital audio " +
  "workstation, writing lyrics that a producer will drop straight into a session. " +
  "Always return clearly section-labeled lyrics using bracketed tags on their own " +
  "line — e.g. [Verse 1], [Pre-Chorus], [Chorus], [Verse 2], [Bridge], [Outro] — " +
  "followed by the lyric lines for that section. Match the requested theme, style, " +
  "and song structure. Do not add commentary, explanations, or anything outside the " +
  "lyrics themselves.";

/** Repo-root `assets/generated/` — resolved from this module's own URL, never `process.cwd()`. */
function generatedAssetsDir(): string {
  const moduleDir = dirname(fileURLToPath(import.meta.url));
  // dist/ai.js (or src/ai.ts under tsx) -> mcp-server/ -> repo root -> assets/generated
  return resolve(moduleDir, "..", "..", "assets", "generated");
}

function slugify(input: string): string {
  const slug = input
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return slug.length > 0 ? slug.slice(0, 60) : "generated";
}

function missingKeysError(...envVars: string[]): Error {
  return new Error(
    `Missing required API key(s): ${envVars.join(", ")}. ` +
      "Set them in your .env file (see .env.example) or export them in the environment " +
      "the MCP server runs in, then retry."
  );
}

async function readErrorBody(response: Response): Promise<string> {
  try {
    return await response.text();
  } catch {
    return "<could not read response body>";
  }
}

// ---------------------------------------------------------------------------
// SDK client construction (test-only fetch-injection seam)
// ---------------------------------------------------------------------------

type FetchLike = (input: string | URL | Request, init?: RequestInit) => Promise<Response>;

/**
 * Test-only fetch injection seam. Both official SDKs accept a custom `fetch`
 * in their client constructor options; `test/ai.test.ts` uses this to stub
 * provider HTTP calls (success and error responses) without touching the
 * network or needing real API keys. This is NOT part of the public tool
 * surface — never call it from server.ts or any tool handler, only from
 * tests. Passing `undefined` restores the SDKs' normal behavior (global
 * `fetch`).
 */
let testFetch: FetchLike | undefined;
export function __setFetchForTests(fn: FetchLike | undefined): void {
  testFetch = fn;
}

/**
 * DECISION (m10-o): both SDKs default to `maxRetries: 2` with their own
 * backoff/timeout policy; the hand-rolled `fetch` code this replaces never
 * retried a failed request. We pin `maxRetries: 0` on both clients so
 * call-count and error-surfacing behavior stay identical to before rather
 * than silently gaining retries. Revisit if flaky-provider retries become
 * desirable — that would be a deliberate, separately-tested behavior change.
 */
function anthropicClient(apiKey: string): Anthropic {
  return new Anthropic({ apiKey, maxRetries: 0, fetch: testFetch });
}

function openAiClient(apiKey: string): OpenAI {
  return new OpenAI({ apiKey, maxRetries: 0, fetch: testFetch });
}

/**
 * Map an error thrown by an SDK call into an `Error` safe to surface to MCP
 * callers: informative (status + provider error detail when available) but
 * never containing key material — the SDKs' `APIError.message` already
 * embeds `${status} ${body}` from the provider's own response, never the
 * request we sent.
 */
function wrapProviderError(label: string, err: unknown): Error {
  if (err instanceof AnthropicAPIError || err instanceof OpenAiAPIError || err instanceof Error) {
    return new Error(`${label}: ${err.message}`);
  }
  return new Error(`${label}: ${String(err)}`);
}

// ---------------------------------------------------------------------------
// Lyrics
// ---------------------------------------------------------------------------

export interface GenerateLyricsInput {
  theme: string;
  style?: string;
  structure?: string;
}

function buildLyricsUserPrompt({ theme, style, structure }: GenerateLyricsInput): string {
  const lines = [`Theme: ${theme}`];
  if (style) lines.push(`Style / genre: ${style}`);
  if (structure) lines.push(`Requested structure: ${structure}`);
  else lines.push("Requested structure: use your best judgement for a strong pop/song structure.");
  lines.push("Write the full lyrics now.");
  return lines.join("\n");
}

async function generateLyricsWithAnthropic(
  input: GenerateLyricsInput,
  apiKey: string
): Promise<string> {
  const client = anthropicClient(apiKey);

  let message: Anthropic.Message;
  try {
    message = await client.messages.create({
      model: ANTHROPIC_MODEL,
      max_tokens: 2048,
      system: LYRICIST_SYSTEM_PROMPT,
      messages: [{ role: "user", content: buildLyricsUserPrompt(input) }],
    });
  } catch (err) {
    throw wrapProviderError("Anthropic API error", err);
  }

  // Collect ALL text blocks (not just content[0]) — modern models can emit
  // thinking/tool_use blocks before the text block(s); see m10-a.
  const text = message.content
    .filter((block): block is Anthropic.TextBlock => block.type === "text")
    .map((block) => block.text)
    .join("\n");

  if (!text) {
    throw new Error("Anthropic API returned no text content for the lyrics request.");
  }
  return text;
}

async function generateLyricsWithOpenAi(
  input: GenerateLyricsInput,
  apiKey: string
): Promise<string> {
  const client = openAiClient(apiKey);
  const model = process.env["OPENAI_TEXT_MODEL"] || DEFAULT_OPENAI_TEXT_MODEL;

  let completion: OpenAI.Chat.ChatCompletion;
  try {
    completion = await client.chat.completions.create({
      model,
      messages: [
        { role: "system", content: LYRICIST_SYSTEM_PROMPT },
        { role: "user", content: buildLyricsUserPrompt(input) },
      ],
    });
  } catch (err) {
    throw wrapProviderError("OpenAI API error", err);
  }

  const text = completion.choices?.[0]?.message?.content;
  if (!text) {
    throw new Error("OpenAI API returned no content for the lyrics request.");
  }
  return text;
}

export interface GenerateLyricsResult {
  lyrics: string;
  provider: "anthropic" | "openai";
}

/**
 * Generate song lyrics. Prefers Anthropic (Claude); falls back to OpenAI
 * chat completions when only `OPENAI_API_KEY` is set. Throws if neither key
 * is configured.
 */
export async function generateLyrics(input: GenerateLyricsInput): Promise<GenerateLyricsResult> {
  const anthropicKey = process.env["ANTHROPIC_API_KEY"];
  const openAiKey = process.env["OPENAI_API_KEY"];

  if (anthropicKey) {
    return { lyrics: await generateLyricsWithAnthropic(input, anthropicKey), provider: "anthropic" };
  }
  if (openAiKey) {
    return { lyrics: await generateLyricsWithOpenAi(input, openAiKey), provider: "openai" };
  }
  throw missingKeysError("ANTHROPIC_API_KEY", "OPENAI_API_KEY");
}

// ---------------------------------------------------------------------------
// Suno (full song / vocal generation)
// ---------------------------------------------------------------------------

export interface GenerateSongSunoInput {
  prompt: string;
  lyrics?: string;
  instrumental?: boolean;
}

/**
 * Generate a song via the Suno API.
 *
 * No official Suno SDK exists (checked as of m10-o) — this stays a
 * hand-rolled `fetch` call, unlike the Anthropic/OpenAI paths above.
 *
 * UNVERIFIED: the official Suno API's endpoint path, request body shape, and
 * response shape have not been confirmed against current provider docs — see
 * docs/AI-INTEGRATIONS.md, "Research items (M6)" #1. This implementation is a
 * best-effort placeholder (`POST {SUNO_API_BASE}/generate` with a Bearer
 * token) that must be validated once the official API is confirmed. Until
 * then it is written defensively: it returns the raw parsed JSON response
 * as-is rather than assuming a specific shape, and surfaces the raw response
 * body text on any non-2xx response so callers can see exactly what the
 * provider said.
 */
export async function generateSongSuno(input: GenerateSongSunoInput): Promise<unknown> {
  const apiKey = process.env["SUNO_API_KEY"];
  if (!apiKey) {
    throw missingKeysError("SUNO_API_KEY");
  }
  const base = process.env["SUNO_API_BASE"] || DEFAULT_SUNO_API_BASE;

  const response = await fetch(`${base}/generate`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      prompt: input.prompt,
      lyrics: input.lyrics,
      instrumental: input.instrumental ?? false,
    }),
  });

  if (!response.ok) {
    const body = await readErrorBody(response);
    throw new Error(
      `Suno API error (${response.status} ${response.statusText}): ${body} ` +
        "[NOTE: the Suno API integration is unverified — see docs/AI-INTEGRATIONS.md]"
    );
  }

  return (await response.json()) as unknown;
}

// ---------------------------------------------------------------------------
// Images (OpenAI GPT Image)
// ---------------------------------------------------------------------------

export interface GenerateImageInput {
  prompt: string;
  size?: string;
}

export interface GenerateImageResult {
  filePath: string;
}

/**
 * Generate an image with OpenAI's images API and save it as a PNG under
 * `assets/generated/` at the repo root. Returns the absolute file path.
 */
export async function generateImage(input: GenerateImageInput): Promise<GenerateImageResult> {
  const apiKey = process.env["OPENAI_API_KEY"];
  if (!apiKey) {
    throw missingKeysError("OPENAI_API_KEY");
  }
  const model = process.env["OPENAI_IMAGE_MODEL"] || DEFAULT_OPENAI_IMAGE_MODEL;
  const client = openAiClient(apiKey);

  let images: OpenAI.Images.ImagesResponse;
  try {
    images = await client.images.generate({
      model,
      prompt: input.prompt,
      size: input.size ?? "1024x1024",
    });
  } catch (err) {
    throw wrapProviderError("OpenAI Images API error", err);
  }

  const b64 = images.data?.[0]?.b64_json;
  if (!b64) {
    throw new Error("OpenAI Images API returned no image data.");
  }

  const dir = generatedAssetsDir();
  await mkdir(dir, { recursive: true });
  const fileName = `${slugify(input.prompt)}-${Date.now()}.png`;
  const filePath = resolve(dir, fileName);
  await writeFile(filePath, Buffer.from(b64, "base64"));

  return { filePath };
}
