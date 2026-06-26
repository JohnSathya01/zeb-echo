# zeb Echo — token-proxy Worker

A tiny Cloudflare Worker that holds the Workers AI credentials so the **shipped
desktop app never bundles a secret** (PHASE2_PLAN.md §3a, CLAUDE.md §9).

## What it does

The app's backend points `CF_GATEWAY_URL` at this Worker and calls it **without**
a Cloudflare token. The Worker injects the real `Authorization` header and
forwards to Cloudflare Workers AI, streaming the response (SSE for the LLM)
straight back.

```
backend (no CF token)
  POST  https://zeb-echo-proxy.<you>.workers.dev/ai/run/<model>
        │  optional: Authorization: Bearer <PROXY_SHARED_SECRET>
        ▼
Worker  ── injects Bearer <CF_API_TOKEN> ──▶
  POST  https://api.cloudflare.com/client/v4/accounts/<CF_ACCOUNT_ID>/ai/run/<model>
```

Only `POST /ai/run/<model>` is proxied; `GET /health` is a liveness probe;
everything else is 404.

## Deploy

Requires a Cloudflare account and `wrangler` (bundled as a dev dependency).

```bash
cd worker
npm install
npx wrangler login                       # one-time browser auth

# Account id the proxy spends Workers AI quota for (plain config):
#   either uncomment [vars].CF_ACCOUNT_ID in wrangler.toml, or:
npx wrangler secret put CF_ACCOUNT_ID     # paste the account id

# The Workers AI API token (SECRET — never committed):
npx wrangler secret put CF_API_TOKEN      # paste the token

# OPTIONAL: a shared bearer so the proxy isn't an open relay to your quota.
# If you set this, also set CF_GATEWAY_TOKEN to the same value in the backend.
npx wrangler secret put PROXY_SHARED_SECRET

npm run deploy
```

`wrangler deploy` prints the public URL, e.g.
`https://zeb-echo-proxy.<your-subdomain>.workers.dev`.

## Point the app at it

In the backend env (or the packaged app's launch env):

```bash
CF_GATEWAY_URL=https://zeb-echo-proxy.<your-subdomain>.workers.dev
# CF_GATEWAY_TOKEN=<same as PROXY_SHARED_SECRET, if you set one>
# CF_API_TOKEN can now be left blank — the proxy holds it.
```

When `CF_GATEWAY_URL` is set, both the LLM (`CloudflareProvider`) and STT
(`CloudflareTranscriptionService`) route through the proxy and send no CF token.

## Verify

```bash
curl https://zeb-echo-proxy.<you>.workers.dev/health
# → {"ok":true,"service":"zeb-echo-proxy"}
```
