# Kinde + Vercel OpenAI proxy (CollectiveCare)

Follow these steps once per environment (staging / production). The **iOS app** keeps all visit data on-device; only authenticated **API calls** go through your Vercel proxy to OpenAI.

## 1. Kinde application

### 1a. Register a **dedicated API** for the OpenAI proxy (native apps)

**Do not** use the **Kinde Management API** audience (for example `https://<subdomain>.kinde.com/api`) as the `audience` in your iOS app. Kinde returns *“Only M2M applications can access the Kinde Management API”* if you try to authorize that API on a **Native** application.

Instead:

1. In Kinde go to **Settings → APIs** → **Add API**.
2. Choose a **name** (e.g. `CollectiveCare OpenAI proxy`).
3. Set **Audience** to a **new**, unique value you control — for this project we standardize on:  
   **`https://collectivecare.pilot/openai-proxy`**  
   (You may use another string, but it must match exactly in **three** places: Kinde API definition, `kinde-auth.json`, and Vercel `KINDE_AUDIENCE`.)
4. Save, open that API’s details → **Applications** → **Authorize application** → select your **Native / iOS** CollectiveCare app (not an M2M app).

After this, login from the device can request that audience and your Vercel proxy can validate the same `aud` claim.

---

1. Create (or open) your app in [Kinde](https://kinde.com).
2. Under **Applications → your app → Authentication**:
   - Enable **Sign in with Apple** (and optionally Google later) per [Kinde Apple social sign-in](https://docs.kinde.com/authenticate/social-sign-in/apple/).
   - In Apple Developer: **Services ID** return URLs must include Kinde’s callback URL (shown in Kinde).
3. Ensure the **dedicated** proxy API from §1a is **authorized** for this native app (not the Management API).
4. **Allowed callback URLs**: must match `kinde-auth.json` exactly, e.g. `comcollectivecarepilotkinde://kinde_callback`.
5. **Allowed logout redirect URLs**: e.g. `comcollectivecarepilotkinde://kinde_logoutcallback`.

Copy:

- **Kinde domain** (issue URL), e.g `https://YOUR_SUBDOMAIN.kinde.com`
- **Client ID** (native application)
- **Audience** — the **dedicated** proxy API from §1a (e.g. `https://collectivecare.pilot/openai-proxy`), not the Kinde Management API

## 2. Vercel deployment

1. In repo root folder `vercel-openai-proxy/`, connect the directory to a new Vercel project (or deploy with Vercel CLI from that folder).
2. Set **environment variables** (Production / Preview as needed):

| Variable | Description |
|----------|-------------|
| `OPENAI_API_KEY` | Your OpenAI project API key (never commit). |
| `KINDE_ISSUER_URL` | Issuer URL, e.g. `https://YOUR_SUBDOMAIN.kinde.com` (no trailing slash). |
| `KINDE_AUDIENCE` | Same string as in `kinde-auth.json` `audience` (e.g. dedicated API `https://collectivecare.pilot/openai-proxy` — **not** the Kinde Management API URL). |

3. Deploy. Note the app URL, e.g. `https://your-proxy.vercel.app`.

**Routes:**

- `POST /api/v1/chat/completions` — same JSON body as OpenAI; `Authorization: Bearer <Kinde access_token>`.
- `POST /api/v1/audio/transcriptions` — same multipart as OpenAI Whisper; same `Authorization` header.

Proxy verifies the JWT (JWKS from `${KINDE_ISSUER_URL}/.well-known/jwks`) and forwards **without** persisting request bodies. Disable verbose access logs for these paths in production if your host logs bodies.

### Troubleshooting (Health Summary / chat `500`)

1. **Vercel → Project → Settings → Environment Variables:** confirm `OPENAI_API_KEY`, `KINDE_ISSUER_URL`, and `KINDE_AUDIENCE` are set for **Production**, then **redeploy** (changing env vars alone does not always apply to old deployments).
2. **Runtime logs:** Vercel → Project → **Logs** (or the deployment’s **Functions** tab) while reproducing from the device. Look for crashes, timeouts, or upstream errors.
3. **Function duration:** Large multi-entry summaries can exceed the default timeout on some plans. `vercel.json` in `vercel-openai-proxy` requests up to **60s** / **120s** for chat / audio; on **Hobby**, Vercel may still cap execution time — upgrade or reduce payload if you see timeouts.
4. **App error text:** If the proxy returns JSON `{ "error": { "message": "…" } }`, the app should show that message. A generic “Server error (500)” often means the response body was not parseable (check logs).
5. **`ERR_MODULE_NOT_FOUND` in Vercel logs:** The proxy targets **CommonJS** and **`jose` v4** so `@vercel/node` can bundle `node_modules` reliably. Pull latest `vercel-openai-proxy`, run `npm install` there if you deploy manually, and **redeploy**; stale builds that mixed ESM-only `jose` v5 with `"type": "module"` often throw this at runtime.

## 3. iOS app configuration

1. Edit `SpeechSessionApp/kinde-auth.json`: replace `YOUR_SUBDOMAIN`, client id, and ensure redirect URIs match Kinde and **Info.plist** URL schemes.
2. In `SpeechSessionApp/Info.plist`, set **CloudOpenAIBaseURL** to your Vercel base **including** `/api`, e.g. `https://your-proxy.vercel.app/api`. Release builds require this for Kinde-authenticated cloud features; an empty value disables the proxy path until configured.
3. Xcode: ensure **Sign in with Apple** capability is on the main app target (**Signing & Capabilities** should match `SpeechSessionApp.entitlements`).

## 4. Canadian / privacy checklist

See [CanadianPrivacyComplianceChecklist.md](CanadianPrivacyComplianceChecklist.md) for items to gather for counsel. Also update [TESTFLIGHT_NOTES.md](../TESTFLIGHT_NOTES.md) and App Store privacy labels.

## 5. Google sign-in later

1. Add **Google** as another social connection on the **same** Kinde application.  
2. No second auth stack in the app—continue using the Kinde iOS SDK / hosted login.
