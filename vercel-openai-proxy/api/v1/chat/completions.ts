import type { VercelRequest, VercelResponse } from "@vercel/node";
import { verifyKindeBearer } from "../../_lib/verifyKinde";

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
}
