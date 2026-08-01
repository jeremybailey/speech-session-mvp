export type VestaboardErrorCode =
  | "INVALID_CONFIG"
  | "INVALID_CREDENTIALS"
  | "NETWORK_FAILURE"
  | "OFFLINE"
  | "MALFORMED_RESPONSE"
  | "OVERSIZED_MESSAGE"
  | "UNSUPPORTED_CHARACTER"
  | "RATE_LIMITED"
  | "API_ERROR"
  | "UNSUPPORTED_OPERATION";

export interface StructuredError {
  code: VestaboardErrorCode;
  message: string;
  statusCode?: number | undefined;
  retryAfterSeconds?: number | undefined;
  details?: unknown;
}

/** Base error type used across client, service, and MCP response mapping. */
export class VestaboardError extends Error {
  public readonly code: VestaboardErrorCode;
  public readonly statusCode: number | undefined;
  public readonly retryAfterSeconds: number | undefined;
  public readonly details: unknown | undefined;

  public constructor(
    code: VestaboardErrorCode,
    message: string,
    options: {
      statusCode?: number | undefined;
      retryAfterSeconds?: number | undefined;
      details?: unknown;
      cause?: unknown;
    } = {}
  ) {
    super(message, { cause: options.cause });
    this.name = "VestaboardError";
    this.code = code;
    this.statusCode = options.statusCode;
    this.retryAfterSeconds = options.retryAfterSeconds;
    this.details = options.details;
  }

  public toStructuredError(): StructuredError {
    const structured: StructuredError = {
      code: this.code,
      message: this.message
    };

    if (this.statusCode !== undefined) {
      structured.statusCode = this.statusCode;
    }

    if (this.retryAfterSeconds !== undefined) {
      structured.retryAfterSeconds = this.retryAfterSeconds;
    }

    if (this.details !== undefined) {
      structured.details = this.details;
    }

    return structured;
  }
}

export function toVestaboardError(error: unknown): VestaboardError {
  if (error instanceof VestaboardError) {
    return error;
  }

  if (error instanceof Error) {
    return new VestaboardError("API_ERROR", error.message, { cause: error });
  }

  return new VestaboardError("API_ERROR", "An unknown Vestaboard error occurred.", {
    details: error
  });
}
