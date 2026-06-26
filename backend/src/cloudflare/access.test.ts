/**
 * Tests for the Cloudflare access seam (direct vs. proxy mode).
 */
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  authHeaders,
  isConfigured,
  runEndpoint,
  usesProxy,
  type CloudflareAccess,
} from './access.js';

const MODEL = '@cf/openai/whisper-large-v3-turbo';

const direct: CloudflareAccess = {
  accountId: 'acct123',
  apiToken: 'secret-token',
  gatewayUrl: '',
};

const proxy: CloudflareAccess = {
  accountId: 'acct123',
  apiToken: '', // no token needed in proxy mode
  gatewayUrl: 'https://zeb-echo-proxy.example.workers.dev',
};

test('direct mode hits api.cloudflare.com with the account path', () => {
  assert.equal(usesProxy(direct), false);
  assert.equal(
    runEndpoint(direct, MODEL),
    `https://api.cloudflare.com/client/v4/accounts/acct123/ai/run/${MODEL}`,
  );
  assert.deepEqual(authHeaders(direct), {
    Authorization: 'Bearer secret-token',
  });
});

test('proxy mode forwards /ai/run/<model> to the gateway with no auth header', () => {
  assert.equal(usesProxy(proxy), true);
  assert.equal(
    runEndpoint(proxy, MODEL),
    `https://zeb-echo-proxy.example.workers.dev/ai/run/${MODEL}`,
  );
  // The token never leaves the server in proxy mode — no auth header is sent.
  assert.deepEqual(authHeaders(proxy), {});
});

test('proxy mode tolerates a trailing slash on the gateway URL', () => {
  const trailing: CloudflareAccess = { ...proxy, gatewayUrl: `${proxy.gatewayUrl}/` };
  assert.equal(
    runEndpoint(trailing, MODEL),
    `https://zeb-echo-proxy.example.workers.dev/ai/run/${MODEL}`,
  );
});

test('proxy mode presents the shared bearer when a gateway token is set', () => {
  const gated: CloudflareAccess = { ...proxy, gatewayToken: 'shared-xyz' };
  assert.deepEqual(authHeaders(gated), { Authorization: 'Bearer shared-xyz' });
  // Still no CF token leaks — the bearer is the low-value proxy secret.
  assert.notEqual(authHeaders(gated).Authorization, 'Bearer ');
});

test('isConfigured: true with a token (direct) OR a gateway (proxy), false with neither', () => {
  assert.equal(isConfigured(direct), true);
  assert.equal(isConfigured(proxy), true);
  assert.equal(
    isConfigured({ accountId: 'acct123', apiToken: '', gatewayUrl: '' }),
    false,
  );
});
