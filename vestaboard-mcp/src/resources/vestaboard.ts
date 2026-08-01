import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

import type { VestaboardService } from "../services/VestaboardService.js";
import { toVestaboardError } from "../util/errors.js";
import type { Logger } from "../util/logger.js";

const CURRENT_RESOURCE_URI = "resource://vestaboard/current";

/** Registers Vestaboard resources exposed to MCP clients. */
export function registerVestaboardResources(
  server: McpServer,
  service: VestaboardService,
  logger: Logger
): void {
  server.registerResource(
    "vestaboard-current",
    CURRENT_RESOURCE_URI,
    {
      title: "Current Vestaboard Display",
      description: "The current display state reported by the configured Vestaboard API.",
      mimeType: "application/json"
    },
    async (uri) => {
      logger.info("MCP resource read.", { resource: CURRENT_RESOURCE_URI });

      try {
        const current = await service.current();
        return jsonResource(uri.href, current);
      } catch (error) {
        return jsonResource(uri.href, {
          supported: false,
          error: toVestaboardError(error).toStructuredError()
        });
      }
    }
  );
}

function jsonResource(uri: string, value: unknown) {
  return {
    contents: [
      {
        uri,
        mimeType: "application/json",
        text: JSON.stringify(value, null, 2)
      }
    ]
  };
}
