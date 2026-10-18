#!/usr/bin/env node

/**
 * Roblox Studio MCP Server
 *
 * An MCP server that bridges AI tool calls to a running Roblox Studio instance
 * via an HTTP polling bridge. The Studio plugin polls for commands; this server
 * translates MCP tool invocations into bridge commands and returns results.
 *
 * Architecture:
 *   OpenCode <--stdio/MCP--> This Server <--HTTP--> Studio Plugin (Lua)
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { StudioBridge } from "./bridge.js";
import { getToolDefinitions, getToolHandler } from "./tools.js";

// ------------------------------------------------------------------
// Configuration
// ------------------------------------------------------------------

const BRIDGE_PORT = parseInt(process.env.ROBLOX_MCP_PORT ?? "28821", 10);

// ------------------------------------------------------------------
// Initialize Bridge
// ------------------------------------------------------------------

const bridge = new StudioBridge(BRIDGE_PORT);

// ------------------------------------------------------------------
// Initialize MCP Server
// ------------------------------------------------------------------

const server = new Server(
  {
    name: "roblox-studio",
    version: "1.0.0",
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

// Handle list_tools
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: getToolDefinitions().map((def) => ({
      name: def.name,
      description: def.description,
      inputSchema: def.inputSchema,
    })),
  };
});

// Handle call_tool
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  const handler = getToolHandler(name);

  if (!handler) {
    return {
      content: [{ type: "text" as const, text: `Unknown tool: ${name}` }],
      isError: true,
    };
  }

  try {
    return await handler(args ?? {}, bridge);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return {
      content: [{ type: "text" as const, text: `Error: ${message}` }],
      isError: true,
    };
  }
});

// ------------------------------------------------------------------
// Start
// ------------------------------------------------------------------

async function main() {
  const log = (msg: string) =>
    process.stderr.write(
      `[roblox-studio-mcp ${new Date().toLocaleTimeString()}] ${msg}\n`
    );

  // Start the HTTP bridge server
  try {
    await bridge.start();
    log(`Bridge listening on http://127.0.0.1:${BRIDGE_PORT}`);
    log("Waiting for Roblox Studio plugin to connect...");
    log(
      "  Tip: Open Studio and click the MCP Bridge toolbar button"
    );
  } catch (error) {
    log(`Failed to start bridge: ${error}`);
    process.exit(1);
  }

  // Connect MCP over stdio
  const transport = new StdioServerTransport();
  await server.connect(transport);
  log("MCP server ready on stdio (6 tools registered)");

  // Graceful shutdown
  const shutdown = async () => {
    process.stderr.write("[roblox-studio-mcp] Shutting down...\n");
    await bridge.stop();
    await server.close();
    process.exit(0);
  };

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((error) => {
  process.stderr.write(`[roblox-studio-mcp] Fatal error: ${error}\n`);
  process.exit(1);
});
