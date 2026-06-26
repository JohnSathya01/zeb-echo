/**
 * OllamaProvider — Phase-1 default provider (local Ollama).
 *
 * STATUS: STUB. The HTTP streaming call is NOT yet implemented (see TODO in
 * `generate`). `isAvailable` performs a real reachability probe so the rest of
 * the pipeline can already report provider health. No Ollama SDK is used — only
 * the built-in `fetch` — and nothing from this module leaks outside src/llm.
 *
 * Config is owned by this provider (CLAUDE.md §3.1): OLLAMA_URL / OLLAMA_MODEL.
 */
import type { LlmProvider, LlmRequest } from './LlmProvider.js';

export interface OllamaConfig {
  /** Base URL of the local Ollama server, e.g. "http://127.0.0.1:11434". */
  readonly baseUrl: string;
  /** Model tag to generate with, e.g. "llama3.2". */
  readonly model: string;
}

export class OllamaProvider implements LlmProvider {
  public readonly id = 'ollama';

  private readonly config: OllamaConfig;

  constructor(config: OllamaConfig) {
    this.config = config;
  }

  public async *generate(request: LlmRequest): AsyncIterable<string> {
    // TODO(Phase 1 integration): implement the real Ollama streaming call.
    //
    // POST `${this.config.baseUrl}/api/generate` with
    //   { model: this.config.model, prompt: <built from request>, stream: true,
    //     options: { temperature: request.params.temperature,
    //                num_predict: request.params.maxTokens } }
    // Ollama responds with newline-delimited JSON objects, each containing a
    // `response` token and a final `{ done: true }`. Parse the NDJSON stream
    // from response.body (a ReadableStream) and `yield` each token's text.
    //
    // Until implemented we throw so misconfiguration is loud rather than silent.
    // The `yield` below keeps this a valid async generator while remaining
    // reachable (the throw is gated) so linting stays clean.
    void request;
    if (!this.implemented) {
      throw new Error(
        'OllamaProvider.generate is not implemented yet (Phase 1 stub). ' +
          'Use LLM_PROVIDER=fake for development.',
      );
    }
    yield '';
  }

  public async complete(prompt: string): Promise<string> {
    void prompt;
    throw new Error(
      'OllamaProvider.complete is not implemented yet (Phase 1 stub). ' +
        'Use LLM_PROVIDER=fake or cloudflare for development.',
    );
  }

  /** Flips to true once the real streaming call is implemented. */
  private readonly implemented = false;

  public async isAvailable(): Promise<boolean> {
    try {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 1_000);
      // Ollama's root endpoint returns "Ollama is running" when up.
      const response = await fetch(this.config.baseUrl, {
        method: 'GET',
        signal: controller.signal,
      });
      clearTimeout(timeout);
      return response.ok;
    } catch {
      // Network down / not running / DNS — treat as unavailable, never throw.
      return false;
    }
  }
}
