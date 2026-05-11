import type { VercelRequest, VercelResponse } from "@vercel/node";
import type { IncomingMessage } from "http";
import { verifyKindeBearer } from "../../_lib/verifyKinde";

export const config = {
  api: {
    bodyParser: false,
  },
};

function readRawBody(req: IncomingMessage): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: string | Buffer) => {
      chunks.push(typeof c === "string" ? Buffer.from(c) : c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") {
    return res.status(405).json({ error: { message: "Method not allowed" } });
  }

  try {
    await verifyKindeBearer(req.headers.authorization);
  } catch (e: unknown) {
    const err = e as { status?: number; message?: string };
    return res.status(err.status ?? 401).json({ error: { message: err.message ?? "Unauthorized" } });
  }

  const key = process.env.OPENAI_API_KEY?.trim();
  if (!key) {
    return res.status(500).json({ error: { message: "Server misconfigured" } });
  }

  const buf = await readRawBody(req);
  const ct = req.headers["content-type"];
  const contentType = Array.isArray(ct) ? ct[0] : ct ?? "application/octet-stream";

  const r = await fetch("https://api.openai.com/v1/audio/transcriptions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${key}`,
      "Content-Type": contentType,
    },
    body: new Uint8Array(buf),
  });

  const text = await r.text();
  const outCt = r.headers.get("content-type");
  if (outCt) {
    res.setHeader("content-type", outCt);
  }
  return res.status(r.status).send(text);
}
