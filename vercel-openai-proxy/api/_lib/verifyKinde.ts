import { createRemoteJWKSet, jwtVerify } from "jose";

let jwks: ReturnType<typeof createRemoteJWKSet> | null = null;

function getIssuerAndJwks(): { issuer: string; jwks: ReturnType<typeof createRemoteJWKSet> } {
  const raw = process.env.KINDE_ISSUER_URL?.trim();
  if (!raw) {
    throw Object.assign(new Error("KINDE_ISSUER_URL not set"), { status: 500 });
  }
  const issuer = raw.replace(/\/$/, "");
  if (!jwks) {
    jwks = createRemoteJWKSet(new URL(`${issuer}/.well-known/jwks`));
  }
  return { issuer, jwks };
}

/**
 * Ensures Authorization is Bearer <Kinde access token> and JWT is valid for configured issuer + audience.
 */
export async function verifyKindeBearer(authHeader: string | undefined): Promise<void> {
  if (!authHeader?.startsWith("Bearer ")) {
    throw Object.assign(new Error("Missing bearer token"), { status: 401 });
  }
  const token = authHeader.slice(7).trim();
  const audience = process.env.KINDE_AUDIENCE?.trim();
  if (!audience) {
    throw Object.assign(new Error("KINDE_AUDIENCE not set"), { status: 500 });
  }
  const { issuer, jwks } = getIssuerAndJwks();
  try {
    await jwtVerify(token, jwks, {
      issuer,
      audience,
    });
  } catch {
    throw Object.assign(new Error("Invalid or expired token"), { status: 401 });
  }
}
