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
    const timeoutMs = VOICE_CONVERT_COMMANDS.has(command)
      ? VOICE_CONVERT_TIMEOUT_MS
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
