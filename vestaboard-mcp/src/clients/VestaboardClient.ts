import type {
  VestaboardApiMode,
  VestaboardCharacterGrid,
  VestaboardClientConfig
} from "../models/Vestaboard.js";
import { VestaboardError } from "../util/errors.js";
import type { Logger } from "../util/logger.js";

interface RequestOptions {
  method: "GET" | "POST";
  url: string;
  headers: Record<string, string>;
  body?: unknown;
}

/** Handles authentication, HTTP requests, retries, timeouts, and API response parsing. */
export class VestaboardClient {
  private readonly config: VestaboardClientConfig;
  private readonly logger: Logger;

  public constructor(config: VestaboardClientConfig, logger: Logger) {
    this.config = config;
    this.logger = logger;
  }

  public get mode(): VestaboardApiMode {
    return this.config.mode;
  }

  public async sendCharacters(characters: VestaboardCharacterGrid): Promise<unknown> {
    const request = this.createMessageRequest("POST", characters);
    return this.requestWithRetries(request);
  }

  public async getCurrent(): Promise<unknown> {
    const request = this.createMessageRequest("GET");
    return this.requestWithRetries(request);
  }

  private createMessageRequest(method: "GET" | "POST", characters?: VestaboardCharacterGrid): RequestOptions {
    if (this.config.mode === "cloud") {
      if (!this.config.cloudApiToken) {
        throw new VestaboardError("INVALID_CONFIG", "Missing Vestaboard cloud API token.");
      }

      return {
        method,
        url: "https://cloud.vestaboard.com/",
        headers: {
          "Content-Type": "application/json",
          "X-Vestaboard-Token": this.config.cloudApiToken
        },
        ...(characters === undefined ? {} : { body: { characters } })
      };
    }

    if (!this.config.localBaseUrl || !this.config.localApiKey) {
      throw new VestaboardError("INVALID_CONFIG", "Missing Vestaboard local API configuration.");
    }

    return {
      method,
      url: `${this.config.localBaseUrl.replace(/\/$/, "")}/local-api/message`,
      headers: {
        "Content-Type": "application/json",
        "X-Vestaboard-Local-Api-Key": this.config.localApiKey
      },
      ...(characters === undefined ? {} : { body: { characters } })
    };
  }

  private async requestWithRetries(options: RequestOptions): Promise<unknown> {
    let lastError: VestaboardError | undefined;

    for (let attempt = 0; attempt <= this.config.retryCount; attempt += 1) {
      try {
        this.logger.info("Vestaboard API request.", {
          method: options.method,
          url: redactUrl(options.url),
          attempt: attempt + 1
        });

        return await this.requestOnce(options);
      } catch (error) {
        const vestaboardError = error instanceof VestaboardError
          ? error
          : new VestaboardError("NETWORK_FAILURE", "Vestaboard request failed.", { cause: error });

        lastError = vestaboardError;

        if (!this.shouldRetry(vestaboardError) || attempt === this.config.retryCount) {
          throw vestaboardError;
        }

        const delayMs = this.retryDelayMs(attempt, vestaboardError);
        this.logger.warn("Retrying Vestaboard API request.", {
          code: vestaboardError.code,
          attempt: attempt + 1,
          delayMs
        });
        await delay(delayMs);
      }
    }

    throw lastError ?? new VestaboardError("API_ERROR", "Vestaboard request failed.");
  }

  private async requestOnce(options: RequestOptions): Promise<unknown> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.config.requestTimeoutMs);

    try {
      const requestInit: RequestInit = {
        method: options.method,
        headers: options.headers,
        signal: controller.signal
      };

      if (options.body !== undefined) {
        requestInit.body = JSON.stringify(options.body);
      }

      const response = await fetch(options.url, requestInit);

      const parsed = await parseResponse(response);

      if (!response.ok) {
        throw errorForResponse(response, parsed);
      }

      return parsed;
    } catch (error) {
      if (error instanceof VestaboardError) {
        this.logger.error("Vestaboard API failure.", { error: error.toStructuredError() });
        throw error;
      }

      const code = error instanceof DOMException && error.name === "AbortError"
        ? "OFFLINE"
        : "NETWORK_FAILURE";

      const wrapped = new VestaboardError(code, "Unable to reach Vestaboard API.", { cause: error });
      this.logger.error("Vestaboard network failure.", { error: wrapped.toStructuredError() });
      throw wrapped;
    } finally {
      clearTimeout(timeout);
    }
  }

  private shouldRetry(error: VestaboardError): boolean {
    return ["NETWORK_FAILURE", "OFFLINE", "RATE_LIMITED", "API_ERROR"].includes(error.code);
  }

  private retryDelayMs(attempt: number, error: VestaboardError): number {
    if (error.retryAfterSeconds !== undefined) {
      return error.retryAfterSeconds * 1000;
    }

    return Math.min(250 * 2 ** attempt, 2_000);
  }
}

async function parseResponse(response: Response): Promise<unknown> {
  const text = await response.text();

  if (text.trim().length === 0) {
    return null;
  }

  try {
    return JSON.parse(text);
  } catch (error) {
    throw new VestaboardError("MALFORMED_RESPONSE", "Vestaboard API returned malformed JSON.", {
      statusCode: response.status,
      details: text,
      cause: error
    });
  }
}

function errorForResponse(response: Response, body: unknown): VestaboardError {
  const message = extractErrorMessage(body) ?? `Vestaboard API returned HTTP ${response.status}.`;

  if (response.status === 401 || response.status === 403) {
    return new VestaboardError("INVALID_CREDENTIALS", message, {
      statusCode: response.status,
      details: body
    });
  }

  if (response.status === 429) {
    const retryAfterSeconds = parseRetryAfter(response.headers.get("retry-after"));
    return new VestaboardError("RATE_LIMITED", message, {
      statusCode: response.status,
      ...(retryAfterSeconds === undefined ? {} : { retryAfterSeconds }),
      details: body
    });
  }

  return new VestaboardError("API_ERROR", message, {
    statusCode: response.status,
    details: body
  });
}

function extractErrorMessage(body: unknown): string | undefined {
  if (typeof body === "object" && body !== null && "message" in body) {
    const message = (body as { message?: unknown }).message;
    return typeof message === "string" ? message : undefined;
  }

  return undefined;
}

function parseRetryAfter(value: string | null): number | undefined {
  if (value === null) {
    return undefined;
  }

  const seconds = Number.parseInt(value, 10);
  return Number.isFinite(seconds) ? seconds : undefined;
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function redactUrl(url: string): string {
  return url.replace(/([?&](?:token|key|secret)=)[^&]+/gi, "$1[redacted]");
}
