import type { LogLevel } from "../models/Vestaboard.js";

const levelPriority: Record<LogLevel, number> = {
  error: 0,
  warn: 1,
  info: 2,
  debug: 3
};

export interface Logger {
  error(message: string, metadata?: Record<string, unknown>): void;
  warn(message: string, metadata?: Record<string, unknown>): void;
  info(message: string, metadata?: Record<string, unknown>): void;
  debug(message: string, metadata?: Record<string, unknown>): void;
}

/** Creates a lightweight stderr logger that is safe for stdio MCP servers. */
export function createLogger(level: LogLevel): Logger {
  const shouldLog = (candidate: LogLevel): boolean =>
    levelPriority[candidate] <= levelPriority[level];

  const write = (candidate: LogLevel, message: string, metadata?: Record<string, unknown>): void => {
    if (!shouldLog(candidate)) {
      return;
    }

    const payload = {
      level: candidate,
      message,
      timestamp: new Date().toISOString(),
      ...(metadata === undefined ? {} : { metadata })
    };

    console.error(JSON.stringify(payload));
  };

  return {
    error: (message, metadata) => write("error", message, metadata),
    warn: (message, metadata) => write("warn", message, metadata),
    info: (message, metadata) => write("info", message, metadata),
    debug: (message, metadata) => write("debug", message, metadata)
  };
}
