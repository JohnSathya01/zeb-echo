/**
 * LLM provider registry / factory (CLAUDE.md §3.1).
 *
 * `selectProvider` returns the configured provider based on `LLM_PROVIDER`.
 * Default is "ollama" (Phase-1 local default); if an unknown id is given we
 * fall back to the FakeLlmProvider so the pipeline always boots.
 *
 * This is the ONLY place providers are constructed — pipeline code receives an
 * already-selected `LlmProvider` via dependency injection.
 */
import type { AppConfig } from '../config.js';
import { CloudflareProvider } from './CloudflareProvider.js';
import { FakeLlmProvider } from './FakeLlmProvider.js';
import type { LlmProvider } from './LlmProvider.js';
import { OllamaProvider } from './OllamaProvider.js';

export type { LlmProvider, LlmRequest, LlmParams } from './LlmProvider.js';
export { DEFAULT_LLM_PARAMS } from './LlmProvider.js';
export { CloudflareProvider } from './CloudflareProvider.js';
export { FakeLlmProvider } from './FakeLlmProvider.js';
export { OllamaProvider } from './OllamaProvider.js';

/** Provider ids that ship in Phase 1. */
export type ProviderId = 'ollama' | 'cloudflare' | 'fake';

/**
 * Construct the provider chosen by config. Falls back to "fake" for any
 * unrecognised id so the backend never fails to start over a config typo.
 */
export function selectProvider(config: AppConfig): LlmProvider {
  switch (config.llmProvider) {
    case 'ollama':
      return new OllamaProvider({
        baseUrl: config.ollamaUrl,
        model: config.ollamaModel,
      });
    case 'cloudflare':
      return new CloudflareProvider({
        accountId: config.cfAccountId,
        model: config.cfModel,
        apiToken: config.cfApiToken,
        gatewayUrl: config.cfGatewayUrl,
        gatewayToken: config.cfGatewayToken,
      });
    case 'fake':
      return new FakeLlmProvider();
    default:
      // Unknown provider id — log and fall back to the deterministic fake.
      console.warn(
        `[llm] Unknown LLM_PROVIDER "${String(config.llmProvider)}"; falling back to "fake".`,
      );
      return new FakeLlmProvider();
  }
}
