/**
 * DawBridge — thin client for the DAW's control-protocol WebSocket.
 *
 * The app (`Sources/DAWControl`) runs a JSON command server at
 * ws://127.0.0.1:<DAW_CONTROL_PORT> (default 17600). Every control message is
 * a single JSON text frame:
 *
 *   request:  { "id": string, "command": string, "params": object }
 *   response: { "id": string, "ok": true,  "result"?: unknown }
 *          or { "id": string, "ok": false, "error": string }
 *
 * This class holds no DAW state of its own (see docs/ARCHITECTURE.md,
 * "MCP server is thin") — it only correlates requests to responses by id
 * and manages a single lazily-created, auto-reconnecting connection.
 *
 * Uses the global `WebSocket` (Node >= 22, no flag needed) — do not add the
 * `ws` package.
 */

const DEFAULT_PORT = "17600";
const REQUEST_TIMEOUT_MS = 5000;
/** Per-command override for commands whose app-side work routinely exceeds
 * the default budget — full renders and loudness measurement over a
 * complete mixdown can take tens of seconds of wall time. */
const LONG_RUNNING_TIMEOUT_MS = 180000;
const LONG_RUNNING_COMMANDS: ReadonlySet<string> = new Set([
  "render.bounce",
  "render.mixdown",
  "render.stems",
  "render.measureLoudness",
  // m22-g: reference.import runs a whole-file offline analysis (loudness +
  // spectrum + stereo) before responding — seconds-class for typical songs,
  // but well past the 5 s default for long files on slow disks.
  "reference.import",
]);
/** vc.convertVocals (m10-p-4) BLOCKS on a real RVC voice conversion —
 * measured ~37x real time (m10-p-2) plus a cold-engine load, so a real
 * multi-minute source clip can legitimately take minutes. The app's own
 * HTTP call to the sidecar budgets 300s
 * (`VoiceConversionClient.Configuration.convertTimeoutSeconds`,
 * Sources/AIServices/VoiceConversionClient.swift) — this bridge-side wait
 * must be AT LEAST that plus headroom, not the shorter 180s render budget
 * above (which would time out the MCP call while the app-side conversion is
 * still legitimately in flight and would otherwise succeed). vc.trainVoice
 * stays on the default REQUEST_TIMEOUT_MS: the facade answers today's
 * 400/501 fast, by design. */
const VOICE_CONVERT_TIMEOUT_MS = 330000;
const VOICE_CONVERT_COMMANDS: ReadonlySet<string> = new Set(["vc.convertVocals"]);
/** vc.convertClips (m24-m leg A) converts EACH selected clip SEPARATELY, so
 * its cost is N times vc.convertVocals'. No FIXED budget can cover an
 * unbounded N — a number picked for "a few clips" silently times out a
 * legitimate ten-clip set — so this tier is DERIVED FROM THE REQUEST: one
 * VOICE_CONVERT_TIMEOUT_MS per clip id, which is exactly the app-side budget
 * per conversion (VoiceConversionClient.Configuration.convertTimeoutSeconds
 * applies per convert call, not per wire command). ⚠️ A timeout here does NOT
 * cancel the app-side work: the store completes the set and lands the track
 * regardless, so an agent that sees a timeout should re-read
 * project_snapshot before retrying, or it will convert twice. */
function voiceConvertClipsTimeoutMs(params: Record<string, unknown>): number {
  const ids = params["clipIds"];
  const count = Array.isArray(ids) ? ids.length : 1;
  return VOICE_CONVERT_TIMEOUT_MS * Math.max(1, count);
}
const VOICE_CONVERT_CLIPS_COMMANDS: ReadonlySet<string> = new Set(["vc.convertClips"]);
/** clip.transcribe (m23-n2b) runs on-device WhisperKit (Sources/AIServices/
 * WhisperTranscriber.swift). The FIRST call on any machine pays a one-time
 * CoreML ANE compile the OS then caches — measured 2026-07-27, identical
 * runs: 93.7s cold vs 1.15s warm. A DIFFERENT cost model from
 * VOICE_CONVERT_TIMEOUT_MS above (vc.convertVocals scales with the source
 * clip's length at ~37x real time; this scales with a one-time compile that
 * amortizes to ~1s on every later call), so it is not reused here — reusing
 * a real-time-factor-bound budget for a fixed one-time-compile cost would be
 * coincidence, not justification. Budget = the measured 93.7s cold compile
 * plus generous headroom for the transcription itself on a long clip and for
 * a slower machine than this one, rounded up to 300s — landing deliberately
 * between the 180s render tier and the 330s convert tier above, since a
 * cold-start transcription is heavier than a render but the compile is a
 * fixed one-time cost, not an unbounded multiple of clip length the way
 * voice conversion is. The Swift-side test suite happens to budget the same
 * 5-minute ceiling for this identical cold-start-plus-transcribe operation
 * (WhisperTranscriberFixtureTests, Tests/AIServicesTests/
 * WhisperTranscriberTests.swift, `.timeLimit(.minutes(5))`) — corroboration
 * that the number is generous enough, not the source of it. */
const CLIP_TRANSCRIBE_TIMEOUT_MS = 300000;
const CLIP_TRANSCRIBE_COMMANDS: ReadonlySet<string> = new Set(["clip.transcribe"]);
/** clip.detectPitch (m23-ap-3) runs on-device SwiftF0 inference (ONNX Runtime,
 * Sources/DAWEngine/Analysis/PitchTracker.swift). MEASURED 2026-08-16 on this
 * machine: analyze() over a 3-minute (180s) 48kHz buffer takes 4.27-4.83s
 * wall time, and SwiftF0PitchTracker construction (~400KB vendored weights,
 * no CoreML ANE compile unlike WhisperKit) takes ~14ms -- so a worst-case
 * whole-clip call (the default when fromSeconds/durationSeconds are omitted,
 * see PitchDetectionResult's payload-arithmetic doc) sits close to the flat
 * 5s REQUEST_TIMEOUT_MS default already. This budget is the measurement
 * rounded up with >10x headroom for a slower machine, a longer-than-3-minute
 * clip (nothing caps clip length), and 48kHz->16kHz resample overhead the
 * measurement's synthetic buffer paid too (it was already 48kHz) but a
 * source at an unusual rate might pay differently. Deliberately NOT reusing
 * CLIP_TRANSCRIBE_TIMEOUT_MS's 300s (WhisperKit's cost model is a ONE-TIME
 * compile that amortizes to ~1s; SwiftF0 has no comparable compile step, so
 * borrowing that number would be coincidence, not justification) or
 * VOICE_CONVERT_TIMEOUT_MS's 330s (RVC's ~37x-real-time model; SwiftF0
 * measured at roughly 40x FASTER than real time, the opposite shape). */
const CLIP_DETECT_PITCH_TIMEOUT_MS = 60000;
const CLIP_DETECT_PITCH_COMMANDS: ReadonlySet<string> = new Set(["clip.detectPitch"]);

interface ControlResponse {
  id: string;
  ok: boolean;
  result?: unknown;
  error?: string;
}

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (reason: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

function isControlResponse(value: unknown): value is ControlResponse {
  if (typeof value !== "object" || value === null) return false;
  const record = value as Record<string, unknown>;
  return typeof record["id"] === "string" && typeof record["ok"] === "boolean";
}

export class DawBridge {
  private readonly url: string;
  private socket: WebSocket | undefined;
  /** Resolves once the current socket has reached OPEN; rejects if it fails to open. */
  private connecting: Promise<WebSocket> | undefined;
  private readonly pending = new Map<string, PendingRequest>();
  private nextId = 1;

  constructor(port: string = process.env["DAW_CONTROL_PORT"] || DEFAULT_PORT) {
    this.url = `ws://127.0.0.1:${port}`;
  }

  /**
   * Send a command to the DAW app and wait for its response.
   *
   * Resolves with `result` (may be `undefined`) on `ok: true`.
   * Rejects with an Error carrying an actionable message on `ok: false`,
   * connection failure, or a timeout (5s by default; longer for commands in
   * `LONG_RUNNING_COMMANDS`).
   */
  async send(command: string, params: Record<string, unknown> = {}): Promise<unknown> {
    const socket = await this.ensureConnected();
    const id = `mcp-${this.nextId++}-${Date.now()}`;
    const timeoutMs = VOICE_CONVERT_CLIPS_COMMANDS.has(command)
      ? voiceConvertClipsTimeoutMs(params)
      : VOICE_CONVERT_COMMANDS.has(command)
      ? VOICE_CONVERT_TIMEOUT_MS
      : CLIP_TRANSCRIBE_COMMANDS.has(command)
        ? CLIP_TRANSCRIBE_TIMEOUT_MS
        : CLIP_DETECT_PITCH_COMMANDS.has(command)
          ? CLIP_DETECT_PITCH_TIMEOUT_MS
          : LONG_RUNNING_COMMANDS.has(command)
            ? LONG_RUNNING_TIMEOUT_MS
            : REQUEST_TIMEOUT_MS;

    return new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(
          new Error(
            `Timed out waiting ${timeoutMs}ms for the DAW app to respond to "${command}". ` +
              "Is the app running and responsive?"
          )
        );
      }, timeoutMs);

      this.pending.set(id, { resolve, reject, timer });

      try {
        socket.send(JSON.stringify({ id, command, params }));
      } catch (err) {
        this.pending.delete(id);
        clearTimeout(timer);
        reject(this.describeConnectionError(err));
      }
    });
  }

  /**
   * True if a WebSocket connection to the DAW app is currently OPEN.
   *
   * A pure state read — NEVER initiates a connection. Used by call logging
   * (m23-ca, src/mcp-log.ts) to decide whether an opportunistic before-state
   * read (`project.overview`) is safe to attempt without paying — or, worse,
   * forcing every caller to pay — a fresh connection's cost just to produce a
   * log line. When this is false, logging records an honest
   * `beforeCaptured: false` instead of connecting on the log's behalf.
   */
  isConnected(): boolean {
    return this.socket !== undefined && this.socket.readyState === WebSocket.OPEN;
  }

  /** Close the socket, if any. Pending requests are rejected. */
  close(): void {
    this.socket?.close();
    this.socket = undefined;
    this.connecting = undefined;
  }

  private async ensureConnected(): Promise<WebSocket> {
    const existing = this.socket;
    if (existing && existing.readyState === WebSocket.OPEN) {
      return existing;
    }
    if (this.connecting) {
      return this.connecting;
    }

    this.connecting = new Promise<WebSocket>((resolve, reject) => {
      let socket: WebSocket;
      try {
        socket = new WebSocket(this.url);
      } catch (err) {
        this.connecting = undefined;
        reject(this.describeConnectionError(err));
        return;
      }

      const onOpen = () => {
        cleanup();
        this.socket = socket;
        this.connecting = undefined;
        resolve(socket);
      };

      const onError = (event: Event) => {
        cleanup();
        this.connecting = undefined;
        const err = "error" in event ? (event as unknown as { error?: unknown }).error : undefined;
        reject(this.describeInitialConnectError(err));
      };

      const onClose = () => {
        cleanup();
        this.connecting = undefined;
        this.socket = undefined;
        this.failAllPending(
          new Error("Connection to the DAW app closed before the request completed.")
        );
      };

      const onMessage = (event: MessageEvent) => {
        this.handleMessage(event.data);
      };

      const cleanup = () => {
        socket.removeEventListener("open", onOpen);
        socket.removeEventListener("error", onError);
      };

      socket.addEventListener("open", onOpen);
      socket.addEventListener("error", onError);
      socket.addEventListener("close", onClose);
      socket.addEventListener("message", onMessage);
    });

    return this.connecting;
  }

  private handleMessage(data: unknown): void {
    let parsed: unknown;
    try {
      const text = typeof data === "string" ? data : String(data);
      parsed = JSON.parse(text);
    } catch {
      console.error("[daw-bridge] received a non-JSON frame from the DAW control server");
      return;
    }

    // Unsolicited broadcast frames — e.g. `{"event":"transport","transport":{…}}` —
    // are pushed to all control clients (not just the one that asked) and carry
    // no `id`/`ok`, so they never match a pending request. Skip them silently.
    if (typeof parsed === "object" && parsed !== null && "event" in parsed) {
      return;
    }

    if (!isControlResponse(parsed)) {
      console.error("[daw-bridge] received a malformed control response");
      return;
    }

    const pending = this.pending.get(parsed.id);
    if (!pending) {
      // No matching request (e.g. it already timed out) — ignore.
      return;
    }
    this.pending.delete(parsed.id);
    clearTimeout(pending.timer);

    if (parsed.ok) {
      pending.resolve(parsed.result);
    } else {
      pending.reject(new Error(parsed.error || "The DAW app reported an unspecified error."));
    }
  }

  private failAllPending(error: Error): void {
    for (const [id, pending] of this.pending) {
      clearTimeout(pending.timer);
      pending.reject(error);
      this.pending.delete(id);
    }
  }

  /**
   * Build the error for a failed initial connection attempt (the WebSocket
   * "error" event fired before "open").
   *
   * Node's global `WebSocket` (backed by undici) does not reliably surface
   * the underlying socket error (e.g. `ECONNREFUSED`) — the error event's
   * `.error` is frequently an empty-message `TypeError` with no `cause`. So
   * rather than pattern-matching an error message that may not exist, we
   * treat any failure to establish the initial connection to a loopback
   * control port as what it almost always is in practice: the DAW app isn't
   * running (or is listening on a different port).
   */
  private describeInitialConnectError(cause: unknown): Error {
    const detail = cause instanceof Error && cause.message ? ` (${cause.message})` : "";
    return new Error(
      `Could not reach the DAW app at ${this.url}${detail}. ` +
        "The DAW app is not running — start it with `swift run DAWApp`, then retry. " +
        "If it is running, check that DAW_CONTROL_PORT matches the app's control port."
    );
  }

  /** Build the error for a synchronous failure constructing the WebSocket itself. */
  private describeConnectionError(cause: unknown): Error {
    const message = cause instanceof Error ? cause.message : String(cause ?? "unknown error");
    return new Error(`Could not connect to the DAW app at ${this.url}: ${message}`);
  }
}
