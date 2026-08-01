import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

import type { Logger } from "../util/logger.js";
import { VestaboardError } from "../util/errors.js";

/** Future extension point for Streamable HTTP transport. */
export async function startHttpTransport(_server: McpServer, _logger: Logger): Promise<never> {
  throw new VestaboardError(
    "UNSUPPORTED_OPERATION",
    "HTTP transport is not implemented yet. Add Streamable HTTP here without changing services or clients."
  );
}
