import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

import { VestaboardClient } from "./clients/VestaboardClient.js";
import { loadEnv } from "./config/env.js";
import { registerVestaboardPrompts } from "./prompts/vestaboard.js";
import { registerVestaboardResources } from "./resources/vestaboard.js";
import { VestaboardService } from "./services/VestaboardService.js";
import { registerVestaboardTools } from "./tools/vestaboard.js";
import { startStdioTransport } from "./transport/stdio.js";
import { toVestaboardError } from "./util/errors.js";
import { createLogger } from "./util/logger.js";

/** Creates the MCP server and registers Vestaboard capabilities. */
export function createVestaboardMcpServer(): McpServer {
  const config = loadEnv();
  const logger = createLogger(config.logLevel);
  const client = new VestaboardClient(config.vestaboard, logger);
  const service = new VestaboardService(client, logger);

  const server = new McpServer({
    name: "vestaboard-mcp",
    version: "0.1.0"
  });

  registerVestaboardTools(server, service, logger);
  registerVestaboardResources(server, service, logger);
  registerVestaboardPrompts(server);

  return server;
}

async function main(): Promise<void> {
  const config = loadEnv();
  const logger = createLogger(config.logLevel);
  const client = new VestaboardClient(config.vestaboard, logger);
  const service = new VestaboardService(client, logger);

  const server = new McpServer({
    name: "vestaboard-mcp",
    version: "0.1.0"
  });

  registerVestaboardTools(server, service, logger);
  registerVestaboardResources(server, service, logger);
  registerVestaboardPrompts(server);

  await startStdioTransport(server, logger);
}

main().catch((error: unknown) => {
  const structured = toVestaboardError(error).toStructuredError();
  console.error(JSON.stringify({
    level: "error",
    message: "Vestaboard MCP server failed to start.",
    timestamp: new Date().toISOString(),
    error: structured
  }));
  process.exit(1);
});
