/**
 * Cloudflare access mode — the single seam that decides WHERE Workers AI calls
 * go and HOW they authenticate. Two modes:
 *
 *  - **Direct** (dev / local): call `api.cloudflare.com` for our account and
 *    send `Authorization: Bearer <CF_API_TOKEN>`. The token lives in env.
 *  - **Proxy** (shipped app): call a `CF_GATEWAY_URL` (our token-proxy Worker,
 *    CLAUDE.md §9 secrets decision). The Worker holds the token + account id and
 *    injects them, so the desktop app ships NO secret. We send no auth header.
 *
 * Both `CloudflareProvider` and `CloudflareTranscriptionService` build their
 * endpoints + headers through here so the two modes stay consistent and the
 * "never ship the token" rule is enforced in one place.
 */

export interface CloudflareAccess {
  /** Cloudflare account id (direct mode). Empty/ignored in proxy mode. */
  readonly accountId: string;
  /** API token — SECRET (direct mode only). Empty means not configured. */
  readonly apiToken: string;
  /**
   * Base URL of the token-proxy Worker (e.g. `https://zeb-echo-proxy.acme.workers.dev`).
   * When non-empty, proxy mode is used and the token is never read or sent.
   */
  readonly gatewayUrl: string;
  /**
   * Optional shared bearer the proxy requires (matches the Worker's
   * `PROXY_SHARED_SECRET`). Low-value vs. the real CF token — it only gates the
   * proxy, which itself caps usage to one account's Workers AI quota. Empty =
   * the proxy is open. Only used in proxy mode.
   */
  readonly gatewayToken?: string;
}

/** True when calls go through the proxy Worker rather than direct to Cloudflare. */
export function usesProxy(access: CloudflareAccess): boolean {
  return access.gatewayUrl.length > 0;
}

/**
 * Build the `ai/run/<model>` endpoint for a Workers AI model.
 *
 * Proxy mode forwards the same `/ai/run/<model>` suffix to the Worker, which
 * rewrites it onto the real account path. Direct mode hits Cloudflare straight.
 */
export function runEndpoint(access: CloudflareAccess, model: string): string {
  if (usesProxy(access)) {
    const base = access.gatewayUrl.replace(/\/+$/, '');
    return `${base}/ai/run/${model}`;
  }
  return `https://api.cloudflare.com/client/v4/accounts/${access.accountId}/ai/run/${model}`;
}

/**
 * Auth headers for a Workers AI request.
 *
 * Direct mode sends the real CF token. Proxy mode sends NO CF token — the Worker
 * injects it server-side — but optionally presents the low-value shared bearer
 * that gates the proxy, when one is configured.
 */
export function authHeaders(access: CloudflareAccess): Record<string, string> {
  if (usesProxy(access)) {
    return access.gatewayToken
      ? { Authorization: `Bearer ${access.gatewayToken}` }
      : {};
  }
  return { Authorization: `Bearer ${access.apiToken}` };
}

/**
 * Whether Cloudflare calls can be made at all: a reachable proxy (no token
 * needed locally) OR a configured token for direct mode.
 */
export function isConfigured(access: CloudflareAccess): boolean {
  return usesProxy(access) || access.apiToken.length > 0;
}
