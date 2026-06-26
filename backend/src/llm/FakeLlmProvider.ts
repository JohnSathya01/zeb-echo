/**
 * FakeLlmProvider — deterministic, dependency-free provider for tests and
 * client/UI development (CLAUDE.md §3.1). Streams a canned response token by
 * token with small delays to mimic real streaming latency.
 */
import type { LlmProvider, LlmRequest } from './LlmProvider.js';

const CANNED_RESPONSE =
  'That is a great question. Based on the recent discussion, here is a concise, ' +
  'helpful answer streamed token by token for testing.';

/** Resolve after `ms` milliseconds. */
function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export class FakeLlmProvider implements LlmProvider {
  public readonly id = 'fake';

  /** Per-token streaming delay (ms). Kept small so tests stay fast. */
  private readonly tokenDelayMs: number;

  constructor(tokenDelayMs = 5) {
    this.tokenDelayMs = tokenDelayMs;
  }

  public async *generate(request: LlmRequest): AsyncIterable<string> {
    // Echo the question so callers can verify the request flowed through,
    // then stream the canned response word by word as "tokens".
    const preamble = request.prompt ? `Re: "${request.prompt}" — ` : '';
    const text = preamble + CANNED_RESPONSE;
    for (const token of text.split(/(\s+)/).filter((t) => t.length > 0)) {
      await delay(this.tokenDelayMs);
      yield token;
    }
  }

  public async complete(prompt: string): Promise<string> {
    // Deterministic: if the prompt looks like the question-detection classifier,
    // echo back a plausible JSON so tests/dev exercise the parsing path.
    if (/is.*a question/i.test(prompt)) {
      return '{"isQuestion": true, "question": "What is the deadline?"}';
    }
    return CANNED_RESPONSE;
  }

  public async isAvailable(): Promise<boolean> {
    return true;
  }
}
