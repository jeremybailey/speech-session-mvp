import type { VercelRequest, VercelResponse } from "@vercel/node";
import { verifyKindeBearer } from "../../_lib/verifyKinde";

function jsonError(res: VercelResponse, status: number, message: string) {
  return res.status(status).json({ error: { message } });
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") {
    return jsonError(res, 405, "Method not allowed");
  }

  try {
    await verifyKindeBearer(req.headers.authorization);
  } catch (e: unknown) {
    const err = e as { status?: number; message?: string };
    return jsonError(res, err.status ?? 401, err.message ?? "Unauthorized");
  }

  const key = process.env.OPENAI_API_KEY?.trim();
  if (!key) {
    return jsonError(
      res,
      500,
      "OPENAI_API_KEY is missing in Vercel environment variables (Production)."
    );
  }

  try {
    const upstreamHeaders: Record<string, string> = {
      Authorization: `Bearer ${key}`,
    };
    const ct = req.headers["content-type"];
    if (typeof ct === "string") {
      upstreamHeaders["Content-Type"] = ct;
    } else if (Array.isArray(ct) && ct[0]) {
      upstreamHeaders["Content-Type"] = ct[0];
    } else {
      upstreamHeaders["Content-Type"] = "application/json";
    }

    const body =
      typeof req.body === "string" ? req.body : req.body != null ? JSON.stringify(req.body) : "";

    const r = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: upstreamHeaders,
      body,
    });

    const text = await r.text();
    const outCt = r.headers.get("content-type");
    if (outCt) {
      res.setHeader("content-type", outCt);
    }
    return res.status(r.status).send(text);
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : "Unknown error";
    console.error("[chat/completions] proxy error", msg);
    return jsonError(res, 502, `Proxy could not complete the OpenAI request: ${msg}`);
  }
}
