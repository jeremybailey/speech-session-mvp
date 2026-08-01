import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

import type { VestaboardService } from "../services/VestaboardService.js";
import { toVestaboardError } from "../util/errors.js";
import type { Logger } from "../util/logger.js";

/** Registers atomic Vestaboard tools with thin MCP handlers. */
export function registerVestaboardTools(
  server: McpServer,
  service: VestaboardService,
  logger: Logger
): void {
  server.registerTool(
    "vestaboard_send",
    {
      title: "Send Vestaboard Message",
      description: "Format and send text to the configured Vestaboard.",
      inputSchema: {
        text: z.string().min(1).describe("Text to display on the Vestaboard.")
      }
    },
    async ({ text }) => {
      logger.info("MCP tool invoked.", { tool: "vestaboard_send" });

      try {
        const result = await service.send(text);
        return success(result, "Sent message to Vestaboard.");
      } catch (error) {
        return failure(error);
      }
    }
  );

  server.registerTool(
    "vestaboard_preview",
    {
      title: "Preview Vestaboard Message",
      description: "Format text for the Vestaboard without sending it.",
      inputSchema: {
        text: z.string().min(1).describe("Text to preview on the Vestaboard.")
      }
    },
    async ({ text }) => {
      logger.info("MCP tool invoked.", { tool: "vestaboard_preview" });

      try {
        const result = service.preview(text);
        return success(result, "Generated Vestaboard preview.");
      } catch (error) {
        return failure(error);
      }
    }
  );

  server.registerTool(
    "vestaboard_clear",
    {
      title: "Clear Vestaboard",
      description: "Clear the configured Vestaboard display.",
      inputSchema: {}
    },
    async () => {
      logger.info("MCP tool invoked.", { tool: "vestaboard_clear" });

      try {
        const result = await service.clear();
        return success(result, "Cleared Vestaboard display.");
      } catch (error) {
        return failure(error);
      }
    }
  );
}

function success(value: unknown, message: string) {
  const structuredContent = toStructuredContent(value);

  return {
    content: [
      {
        type: "text" as const,
        text: `${message}\n\n${JSON.stringify(structuredContent, null, 2)}`
      }
    ],
    structuredContent
  };
}

function failure(error: unknown) {
  const structuredContent = { error: toVestaboardError(error).toStructuredError() };

  return {
    isError: true,
    content: [
      {
        type: "text" as const,
        text: `${structuredContent.error.code}: ${structuredContent.error.message}`
      }
    ],
    structuredContent
  };
}

function toStructuredContent(value: unknown): Record<string, unknown> {
  if (typeof value === "object" && value !== null && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }

  return { value };
}
