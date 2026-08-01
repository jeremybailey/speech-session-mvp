export const VESTABOARD_ROWS = 6;
export const VESTABOARD_COLUMNS = 22;
export const VESTABOARD_CELL_COUNT = VESTABOARD_ROWS * VESTABOARD_COLUMNS;

export type VestaboardApiMode = "cloud" | "local";
export type VestaboardCharacterCode = number;
export type VestaboardCharacterGrid = VestaboardCharacterCode[][];

export interface VestaboardPreview {
  originalText: string;
  normalizedText: string;
  lines: string[];
  characters: VestaboardCharacterGrid;
  warnings: string[];
}

export interface VestaboardSendResult {
  mode: VestaboardApiMode;
  sentAt: string;
  preview: VestaboardPreview;
  apiResponse: unknown;
}

export interface VestaboardCurrentDisplay {
  supported: boolean;
  mode: VestaboardApiMode;
  retrievedAt: string;
  raw: unknown;
  reason?: string;
}

export interface VestaboardClientConfig {
  mode: VestaboardApiMode;
  cloudApiToken?: string;
  localBaseUrl?: string;
  localApiKey?: string;
  requestTimeoutMs: number;
  retryCount: number;
}

export interface AppConfig {
  vestaboard: VestaboardClientConfig;
  logLevel: LogLevel;
}

export type LogLevel = "error" | "warn" | "info" | "debug";
