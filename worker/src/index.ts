/**
 * zeb Echo token-proxy Worker.
 *
 * Holds the Cloudflare Workers AI credentials (account id + API token) as Worker
 * SECRETS so the shipped desktop app never bundles them (PHASE2_PLAN.md §3a,
 * CLAUDE.md §9 secrets decision). The app's backend points `CF_GATEWAY_URL` at
 * this Worker and calls it WITHOUT a token; the Worker injects the real
 * `Authorization` header and forwards to Cloudflare, streaming the response
 * (SSE for the LLM) straight back.
 *
 * Contract (mirrors the direct Cloudflare REST shape the backend already speaks):
 *   POST <worker>/ai/run/<model>   →   .../accounts/<id>/ai/run/<model>
 * Only that path is proxied; everything else gets 404. A shared bearer
 * (`PROXY_SHARED_SECRET`, optional) gates access so the endpoint isn't open.
 */

export interface Env {
  /** Cloudflare account id — Worker secret/var. */
  CF_ACCOUNT_ID: string;
  /** Workers AI API token — Worker SECRET (never returned to clients). */
  CF_API_TOKEN: string;
  /**
   * Optional shared bearer the app must present (`Authorization: Bearer <x>`).
   * When set, requests without it are rejected. Keeps the proxy from being an
   * open relay to your Workers AI quota. Leave unset to allow any caller.
   */
  PROXY_SHARED_SECRET?: string;
}

const CF_API_BASE = 'https://api.cloudflare.com/client/v4';

/** CORS headers — the Flutter app's backend calls server-side, but allow all. */
const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    const url = new URL(request.url);

    // Liveness probe (the backend's isAvailable() and humans can hit this).
    if (request.method === 'GET' && url.pathname === '/health') {
      return json({ ok: true, service: 'zeb-echo-proxy' }, 200);
    }

    // Only POST /ai/run/<model> is proxied.
    if (request.method !== 'POST' || !url.pathname.startsWith('/ai/run/')) {
      return json({ error: 'Not found' }, 404);
    }

    // Optional shared-secret gate.
    if (env.PROXY_SHARED_SECRET) {
      const presented = bearer(request.headers.get('Authorization'));
      if (presented !== env.PROXY_SHARED_SECRET) {
        return json({ error: 'Unauthorized' }, 401);
      }
    }

    if (!env.CF_ACCOUNT_ID || !env.CF_API_TOKEN) {
      return json(
        { error: 'Proxy misconfigured: CF_ACCOUNT_ID / CF_API_TOKEN not set.' },
        500,
      );
    }

    // Rewrite <worker>/ai/run/<model>  →  /accounts/<id>/ai/run/<model>,
    // preserving any query string (none today, but forward-compatible).
    const target = `${CF_API_BASE}/accounts/${env.CF_ACCOUNT_ID}${url.pathname}${url.search}`;

    const upstream = await fetch(target, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.CF_API_TOKEN}`,
        'Content-Type':
          request.headers.get('Content-Type') ?? 'application/json',
      },
      body: request.body,
    });

    // Stream the upstream body straight through (preserves SSE token streaming
    // for the LLM). Copy status + content-type; add CORS.
    const headers = new Headers(CORS_HEADERS);
    const contentType = upstream.headers.get('Content-Type');
    if (contentType) {
      headers.set('Content-Type', contentType);
    }
    return new Response(upstream.body, {
      status: upstream.status,
      headers,
    });
  },
};

/** Extract the bearer value from an `Authorization` header, or null. */
function bearer(header: string | null): string | null {
  if (header === null) {
    return null;
  }
  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  return match ? match[1] : null;
}

/** JSON response with CORS headers. */
function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}
