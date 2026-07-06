/**
 * Direct AI-provider clients for the MCP server (docs/AI-INTEGRATIONS.md).
 *
 * These call provider HTTPS APIs directly with the global `fetch` (Node >=
 * 22, no flag needed) — do not add `node-fetch`. Keys are read from
 * environment variables only (populated from `.env` by whatever launches
 * this process) and are never logged or included in thrown error messages.
 */

import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ANTHROPIC_MODEL = "claude-sonnet-5";
const ANTHROPIC_VERSION = "2023-06-01";
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
// Lyrics
// ---------------------------------------------------------------------------

export interface GenerateLyricsInput {
  theme: string;
  style?: string;
  structure?: string;
}

interface AnthropicMessagesResponse {
  content?: Array<{ type: string; text?: string }>;
}

interface OpenAiChatResponse {
  choices?: Array<{ message?: { content?: string | null } }>;
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
  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": apiKey,
      "anthropic-version": ANTHROPIC_VERSION,
    },
    body: JSON.stringify({
      model: ANTHROPIC_MODEL,
      max_tokens: 2048,
      system: LYRICIST_SYSTEM_PROMPT,
      messages: [{ role: "user", content: buildLyricsUserPrompt(input) }],
    }),
  });

  if (!response.ok) {
    const body = await readErrorBody(response);
    throw new Error(`Anthropic API error (${response.status} ${response.statusText}): ${body}`);
  }

  const data = (await response.json()) as AnthropicMessagesResponse;
  const text = data.content
    ?.filter((block) => block.type === "text" && typeof block.text === "string")
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
  const model = process.env["OPENAI_TEXT_MODEL"] || DEFAULT_OPENAI_TEXT_MODEL;
  const response = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model,
      messages: [
        { role: "system", content: LYRICIST_SYSTEM_PROMPT },
        { role: "user", content: buildLyricsUserPrompt(input) },
      ],
    }),
  });

  if (!response.ok) {
    const body = await readErrorBody(response);
    throw new Error(`OpenAI API error (${response.status} ${response.statusText}): ${body}`);
  }

  const data = (await response.json()) as OpenAiChatResponse;
  const text = data.choices?.[0]?.message?.content;
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

interface OpenAiImagesResponse {
  data?: Array<{ b64_json?: string }>;
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

  const response = await fetch("https://api.openai.com/v1/images/generations", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model,
      prompt: input.prompt,
      size: input.size ?? "1024x1024",
    }),
  });

  if (!response.ok) {
    const body = await readErrorBody(response);
    throw new Error(`OpenAI Images API error (${response.status} ${response.statusText}): ${body}`);
  }

  const data = (await response.json()) as OpenAiImagesResponse;
  const b64 = data.data?.[0]?.b64_json;
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
