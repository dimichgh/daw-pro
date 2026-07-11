---
name: mcp-verify
description: Verify the MCP server and control protocol end-to-end — build the TS server, check tool/command parity with Commands.swift, and run live round-trips against the app's control port. Use after changes to mcp-server/ or Sources/DAWControl.
---

# MCP Verify

1. **Build**: `cd mcp-server && npm install --no-audit --no-fund && npm run build` — must compile clean.
2. **Parity audit**: `cd mcp-server && npm test` — the automated audit (`test/audit-tools.test.ts`) spins the real server on an in-memory transport and enforces command↔tool bijection against `Commands.swift` plus schema richness (titles, ≥40-char descriptions, every input property described). Tool registration lives in `mcp-server/src/server.ts` (`index.ts` is only the stdio entry). Exception tables (6 unprefixed generation tools, 3 direct-API tools) are documented in the test and in ARCHITECTURE.md. Any failure blocks roadmap checkboxes.
3. **Live round-trip** (needs the app): if nothing is listening on the control port, start the app in the background: `swift run DAWApp &` and wait for the port (check with `nc -z 127.0.0.1 17600`). Then exercise via a short node script against `ws://127.0.0.1:17600`:
   - `project.snapshot` → valid JSON with tracks/transport
   - `track.add` → snapshot shows the new track
   - `transport.setTempo 128` → snapshot reflects 128
   - malformed JSON and unknown command → structured error, connection survives
4. **MCP layer smoke**: run the server with the stdio inspector pattern (`echo` a `tools/list` JSON-RPC request into `node dist/index.js`) and confirm the tool list parses.
5. Kill anything you started. Report per-step pass/fail; parity drift or a dead round-trip blocks roadmap checkboxes.
