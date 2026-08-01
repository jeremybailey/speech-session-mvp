import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import dotenv from "dotenv";
import { z } from "zod";

import type { AppConfig, LogLevel, VestaboardApiMode } from "../models/Vestaboard.js";
import { VestaboardError } from "../util/errors.js";

const moduleDirectory = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(moduleDirectory, "../..");
dotenv.config({ path: resolve(projectRoot, ".env"), quiet: true });

const envSchema = z.object({
  VESTABOARD_API_MODE: z.enum(["cloud", "local"]).default("cloud"),
  VESTABOARD_CLOUD_API_TOKEN: z.string().optional(),
  VESTABOARD_LOCAL_BASE_URL: z.string().url().default("http://vestaboard.local:7000"),
  VESTABOARD_LOCAL_API_KEY: z.string().optional(),
  VESTABOARD_REQUEST_TIMEOUT_MS: z.coerce.number().int().positive().default(10_000),
  VESTABOARD_RETRY_COUNT: z.coerce.number().int().min(0).max(5).default(2),
  LOG_LEVEL: z.enum(["error", "warn", "info", "debug"]).default("info")
});

/** Loads and validates process environment for the MCP server. */
export function loadEnv(): AppConfig {
  const parsed = envSchema.safeParse(process.env);

  if (!parsed.success) {
    throw new VestaboardError("INVALID_CONFIG", "Invalid environment configuration.", {
      details: parsed.error.flatten()
    });
  }

  const mode: VestaboardApiMode = parsed.data.VESTABOARD_API_MODE;
  const vestaboard = {
    mode,
    requestTimeoutMs: parsed.data.VESTABOARD_REQUEST_TIMEOUT_MS,
    retryCount: parsed.data.VESTABOARD_RETRY_COUNT,
    ...(parsed.data.VESTABOARD_CLOUD_API_TOKEN === undefined
      ? {}
      : { cloudApiToken: parsed.data.VESTABOARD_CLOUD_API_TOKEN }),
    localBaseUrl: parsed.data.VESTABOARD_LOCAL_BASE_URL,
    ...(parsed.data.VESTABOARD_LOCAL_API_KEY === undefined
      ? {}
      : { localApiKey: parsed.data.VESTABOARD_LOCAL_API_KEY })
  };

  return {
    vestaboard,
    logLevel: parsed.data.LOG_LEVEL as LogLevel
  };
}
