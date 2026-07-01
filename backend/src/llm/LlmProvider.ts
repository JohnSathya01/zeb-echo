/**
 * Provider-agnostic LLM interface (CLAUDE.md §3.1).
 *
 * Backend pipeline code depends ONLY on these types — never on Ollama, Bedrock,
 * OpenAI, or any SDK directly. Adding a new backend = adding one new class that
 * implements `LlmProvider`, with no changes elsewhere.
 */
import type { TranscriptSegment } from '../protocol/messages.js';

/** Generation parameters, provider-agnostic. */
export interface LlmParams {
  /** Sampling temperature (0 = deterministic). */
  readonly temperature: number;
  /** Hard cap on generated tokens. */
  readonly maxTokens: number;
}

/** A single request to generate a response for a detected question. */
export interface LlmRequest {
  /** The detected question (self-contained). */
  readonly prompt: string;
  /** Bounded recent conversation used as context. */
  readonly context: TranscriptSegment[];
  /** Generation parameters. */
  readonly params: LlmParams;
  /**
   * One-line summary of the conversational context, produced upstream by the
   * question detector (context engineering). Optional — providers fall back to
   * deriving context from the transcript when absent.
   */
  readonly contextSummary?: string;
  /**
   * User-provided Knowledge Base (Phase 3): authoritative domain knowledge
   * injected into the prompt so answers can cite facts absent from the
   * transcript. Optional.
   */
  readonly knowledgeBase?: string;
}

/** The single seam every concrete LLM backend implements. */
export interface LlmProvider {
  /** Stable provider id, e.g. "ollama", "bedrock", "openai", "fake". */
  readonly id: string;

  /**
   * Stream response tokens (preferred — lowest perceived latency).
   * If a backend cannot stream, it wraps its single response as a one-item
   * async iterable.
   */
  generate(request: LlmRequest): AsyncIterable<string>;

  /**
   * One-shot, non-streaming completion for internal tasks like classification
   * (e.g. question detection) where we need the whole answer at once rather
   * than streamed tokens. Returns the full generated text.
   */
  complete(prompt: string, params?: LlmParams): Promise<string>;

  /** Liveness / reachability check (model loaded? endpoint reachable? creds valid?). */
  isAvailable(): Promise<boolean>;
}

/** Sensible default generation params for Phase 1. */
export const DEFAULT_LLM_PARAMS: LlmParams = {
  temperature: 0.7,
  maxTokens: 1024,
};
