import type { VestaboardClient } from "../clients/VestaboardClient.js";
import {
  VESTABOARD_COLUMNS,
  VESTABOARD_ROWS,
  type VestaboardCharacterGrid,
  type VestaboardCurrentDisplay,
  type VestaboardPreview,
  type VestaboardSendResult
} from "../models/Vestaboard.js";
import { VestaboardError } from "../util/errors.js";
import type { Logger } from "../util/logger.js";

const CHARACTER_CODES = createCharacterCodeMap();

/** Owns Vestaboard business operations, formatting, and validation. */
export class VestaboardService {
  private readonly client: VestaboardClient;
  private readonly logger: Logger;

  public constructor(client: VestaboardClient, logger: Logger) {
    this.client = client;
    this.logger = logger;
  }

  public validate(text: string): void {
    this.format(text);
  }

  public preview(text: string): VestaboardPreview {
    return this.format(text);
  }

  public async send(text: string): Promise<VestaboardSendResult> {
    const preview = this.format(text);
    const apiResponse = await this.client.sendCharacters(preview.characters);

    return {
      mode: this.client.mode,
      sentAt: new Date().toISOString(),
      preview,
      apiResponse
    };
  }

  public async clear(): Promise<VestaboardSendResult> {
    const preview = blankPreview();
    const apiResponse = await this.client.sendCharacters(preview.characters);

    return {
      mode: this.client.mode,
      sentAt: new Date().toISOString(),
      preview,
      apiResponse
    };
  }

  public async current(): Promise<VestaboardCurrentDisplay> {
    const raw = await this.client.getCurrent();

    return {
      supported: true,
      mode: this.client.mode,
      retrievedAt: new Date().toISOString(),
      raw
    };
  }

  public format(text: string): VestaboardPreview {
    if (text.trim().length === 0) {
      throw new VestaboardError("OVERSIZED_MESSAGE", "Vestaboard messages cannot be empty.");
    }

    const { normalizedText, warnings } = normalizeText(text);
    const contentLines = wrapText(normalizedText);
    const lines = centerVertically(contentLines);
    const characters = lines.map((line) => encodeLine(line));

    this.logger.debug("Formatted Vestaboard message.", {
      originalLength: text.length,
      normalizedLength: normalizedText.length,
      warnings
    });

    return {
      originalText: text,
      normalizedText,
      lines,
      characters,
      warnings
    };
  }
}

function blankPreview(): VestaboardPreview {
  const lines = Array.from({ length: VESTABOARD_ROWS }, () => " ".repeat(VESTABOARD_COLUMNS));
  const characters = createBlankGrid();

  return {
    originalText: "",
    normalizedText: "",
    lines,
    characters,
    warnings: []
  };
}

function normalizeText(text: string): { normalizedText: string; warnings: string[] } {
  const warnings: string[] = [];
  let normalized = text
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n")
    .replace(/\u2018|\u2019/g, "'")
    .replace(/\u201c|\u201d/g, "\"")
    .replace(/\u2013|\u2014/g, "-")
    .toUpperCase()
    .trim();

  const chars = [...normalized].map((char) => {
    if (char === "\n" || CHARACTER_CODES.has(char)) {
      return char;
    }

    warnings.push(`Unsupported character replaced with blank: ${char}`);
    return " ";
  });

  normalized = chars.join("").replace(/[ \t]+/g, " ");
  return { normalizedText: normalized, warnings };
}

function wrapText(text: string): string[] {
  const lines: string[] = [];

  for (const paragraph of text.split("\n")) {
    if (paragraph.trim().length === 0) {
      lines.push("");
      continue;
    }

    for (const line of wrapParagraph(paragraph.trim())) {
      lines.push(line);
    }
  }

  if (lines.length > VESTABOARD_ROWS) {
    throw new VestaboardError(
      "OVERSIZED_MESSAGE",
      `Message does not fit on a ${VESTABOARD_ROWS}x${VESTABOARD_COLUMNS} Vestaboard display.`,
      {
        details: {
          lineCount: lines.length,
          maxLines: VESTABOARD_ROWS
        }
      }
    );
  }

  return lines;
}

function wrapParagraph(paragraph: string): string[] {
  const words = paragraph.split(/\s+/);
  const lines: string[] = [];
  let current = "";

  for (const word of words) {
    const chunks = splitLongWord(word);

    for (const chunk of chunks) {
      if (current.length === 0) {
        current = chunk;
        continue;
      }

      const candidate = `${current} ${chunk}`;
      if (candidate.length <= VESTABOARD_COLUMNS) {
        current = candidate;
      } else {
        lines.push(current);
        current = chunk;
      }
    }
  }

  if (current.length > 0) {
    lines.push(current);
  }

  return lines;
}

function splitLongWord(word: string): string[] {
  if (word.length <= VESTABOARD_COLUMNS) {
    return [word];
  }

  const chunks: string[] = [];
  for (let index = 0; index < word.length; index += VESTABOARD_COLUMNS) {
    chunks.push(word.slice(index, index + VESTABOARD_COLUMNS));
  }

  return chunks;
}

function centerVertically(contentLines: string[]): string[] {
  const topPadding = Math.floor((VESTABOARD_ROWS - contentLines.length) / 2);
  const lines = [
    ...Array.from({ length: topPadding }, () => ""),
    ...contentLines
  ];

  while (lines.length < VESTABOARD_ROWS) {
    lines.push("");
  }

  return lines.map((line) => centerLine(line));
}

function centerLine(line: string): string {
  if (line.length > VESTABOARD_COLUMNS) {
    throw new VestaboardError("OVERSIZED_MESSAGE", "A formatted line exceeds Vestaboard width.", {
      details: {
        line,
        maxColumns: VESTABOARD_COLUMNS
      }
    });
  }

  const leftPadding = Math.floor((VESTABOARD_COLUMNS - line.length) / 2);
  return `${" ".repeat(leftPadding)}${line}`.padEnd(VESTABOARD_COLUMNS, " ");
}

function encodeLine(line: string): number[] {
  return [...line].map((char) => {
    const code = CHARACTER_CODES.get(char);

    if (code === undefined) {
      throw new VestaboardError("UNSUPPORTED_CHARACTER", `Unsupported Vestaboard character: ${char}`);
    }

    return code;
  });
}

function createBlankGrid(): VestaboardCharacterGrid {
  return Array.from({ length: VESTABOARD_ROWS }, () =>
    Array.from({ length: VESTABOARD_COLUMNS }, () => 0)
  );
}

function createCharacterCodeMap(): Map<string, number> {
  const entries: Array<[string, number]> = [[" ", 0]];

  for (let index = 0; index < 26; index += 1) {
    entries.push([String.fromCharCode(65 + index), index + 1]);
  }

  for (let index = 1; index <= 9; index += 1) {
    entries.push([String(index), 26 + index]);
  }
  entries.push(["0", 36]);

  entries.push(
    ["!", 37],
    ["@", 38],
    ["#", 39],
    ["$", 40],
    ["(", 41],
    [")", 42],
    ["-", 44],
    ["+", 46],
    ["&", 47],
    ["=", 48],
    [";", 49],
    [":", 50],
    ["'", 52],
    ["\"", 53],
    ["%", 54],
    [",", 55],
    [".", 56],
    ["/", 59],
    ["?", 60]
  );

  return new Map(entries);
}
