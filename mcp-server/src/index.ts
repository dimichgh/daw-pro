#!/usr/bin/env node
/**
 * DAW Pro MCP server — entry point.
 *
 * All tool registration lives in `src/server.ts` (see that file for why).
 * This module's only job is to connect the exported `server` to a real
 * stdio transport when run as a process.
 *
 * This process is a stdio MCP server: stdout is the transport wire, so
 * nothing may ever `console.log`. All diagnostics go to `console.error`
 * (stderr), which MCP clients treat as a log stream, not protocol data.
 */

import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { server } from "./server.js";

// ---------------------------------------------------------------------------
// Connect
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("[daw-pro-mcp] connected via stdio");
}

main().catch((err: unknown) => {
  console.error("[daw-pro-mcp] fatal error:", err instanceof Error ? err.stack ?? err.message : err);
  process.exit(1);
});
