/**
 * ResponseService (CLAUDE.md §3). Consumes a detected question plus bounded
 * recent transcript context, builds an LlmRequest, and yields response tokens
 * by delegating to the injected LlmProvider.
 *
 * Critically, this service does NOT know which LLM backend is in use — it only
 * depends on the LlmProvider interface (§3.1).
 */
import type { LlmParams, LlmProvider } from '../llm/LlmProvider.js';
import { DEFAULT_LLM_PARAMS } from '../llm/LlmProvider.js';
import type { TranscriptSegment } from '../protocol/messages.js';
import type { DetectedQuestion } from './QuestionDetectionService.js';

export interface ResponseService {
  /**
   * Generate a streamed response for `question`, using up to the last
   * `context` segments as conversation context.
   */
  respond(
    question: DetectedQuestion,
    context: readonly TranscriptSegment[],
  ): AsyncIterable<string>;
}

/** ResponseService backed by an injected LlmProvider. */
export class LlmResponseService implements ResponseService {
  private readonly provider: LlmProvider;
  private readonly params: LlmParams;
  /** Max number of recent segments passed to the LLM as context. */
  private readonly maxContextSegments: number;

  constructor(
    provider: LlmProvider,
    params: LlmParams = DEFAULT_LLM_PARAMS,
    maxContextSegments = 30,
  ) {
    this.provider = provider;
    this.params = params;
    this.maxContextSegments = maxContextSegments;
  }

  public async *respond(
    question: DetectedQuestion,
    context: readonly TranscriptSegment[],
  ): AsyncIterable<string> {
    // Bound the context to the most recent N segments (§9: context window).
    const bounded = context.slice(-this.maxContextSegments);
    const request = {
      prompt: question.text,
      context: [...bounded],
      params: this.params,
    };
    for await (const token of this.provider.generate(request)) {
      yield token;
    }
  }
}
