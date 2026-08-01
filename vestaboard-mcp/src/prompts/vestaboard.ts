import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

/** Registers an optional reusable prompt for composing board-sized messages. */
export function registerVestaboardPrompts(server: McpServer): void {
  server.registerPrompt(
    "vestaboard_compose_message",
    {
      title: "Compose Vestaboard Message",
      description: "Help compose a concise message that fits well on a 6x22 Vestaboard.",
      argsSchema: {
        intent: z.string().optional().describe("The purpose or theme of the message.")
      }
    },
    ({ intent }) => ({
      messages: [
        {
          role: "user",
          content: {
            type: "text",
            text: [
              "Compose a concise Vestaboard message.",
              "Keep it readable on a 6 row by 22 column split-flap display.",
              "Avoid unsupported symbols and prefer short words.",
              intent ? `Intent: ${intent}` : undefined
            ].filter(Boolean).join("\n")
          }
        }
      ]
    })
  );
}
