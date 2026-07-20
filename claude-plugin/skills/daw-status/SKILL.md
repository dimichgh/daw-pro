---
name: daw-status
description: Connection sanity check for DAW Pro — confirm the app is reachable over its control port, report which cloud AI providers are configured, and show a quick project overview. Use this first when starting work in a new session, or whenever a DAW Pro tool call fails unexpectedly, to figure out what's wrong before retrying.
---

# /daw-status — first-run diagnostic

Run these three read-only checks, in order, and report a short summary.
None of them mutate the project or require picking a specific specialist
agent — they're plain MCP tool calls available directly in this session.

## 1. Is the app reachable?

Call `app_connection_info`. It never throws — it reports the loopback
WebSocket URL/port this MCP server would use (`ws://127.0.0.1:17600` by
default, or whatever `DAW_CONTROL_PORT` overrides it to) and where that
port setting came from (`environment`, `settings`, or `default`).

Then make one real call that requires the app to actually be up —
`project_overview` is the cheapest — to distinguish "the app isn't running"
from "the port info is fine but nothing's listening there." If that call
fails with a connection error, tell the user plainly:

> DAW Pro isn't reachable on `ws://127.0.0.1:<port>`. Launch the app (or run
> `swift run DAWApp` from the repo) and try again. If it's running on a
> different port, set the `DAW_CONTROL_PORT` environment variable before
> starting Claude Code and reconnect.

Do not guess at other causes (firewall, permissions, etc.) — the app not
running is by far the most common reason, and the error message from the
bridge should already say so.

## 2. Which AI providers are configured?

Call `ai_provider_status`. Report each of `anthropic`/`openai`/`suno`'s
`configured`/`source` state in one line each. If a provider a planned task
needs is `none`, say so up front and point the user at the app's Settings
panel (⌘,) or the matching environment variable
(`ANTHROPIC_API_KEY`/`OPENAI_API_KEY`/`SUNO_API_KEY`) — never ask them to
paste a key into chat. Note that the local ACE-Step song-generation sidecar
is separate and keyless — check it with `ai_sidecar_status` (held by the
`composer` agent) instead, not through this tool.

## 3. What's in the project right now?

Call `project_overview` (you'll already have this from step 1) and
summarize: tempo, track count/roster with kind and routing, and whether
there's already musical content (clip counts) or it's an empty session.
This gives whoever picks up next (the user, or a delegated agent) a
starting point without a second round-trip.

## Output

A few short lines covering all three checks — this is a diagnostic, not a
report to write to disk. If everything's healthy, say so plainly and stop;
don't pad it out.
