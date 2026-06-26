/**
 * CloudflareProvider — Cloudflare Workers AI (CLAUDE.md §3.1).
 *
 * Streams tokens from a Workers AI text-generation model (default
 * `@cf/meta/llama-4-scout-17b-16e-instruct`) over Server-Sent Events.
 *
 * Config is owned by this provider: CF_ACCOUNT_ID + CF_MODEL are plain config,
 * but CF_API_TOKEN is a SECRET — it is read from env only, never hardcoded or
 * committed (CLAUDE.md §3.1 secrets rule). No Cloudflare SDK is used; only the
 * built-in `fetch`. Nothing here leaks outside src/llm.
 */
import type { LlmParams, LlmProvider, LlmRequest } from './LlmProvider.js';
import type { TranscriptSegment } from '../protocol/messages.js';

export interface CloudflareConfig {
  /** Cloudflare account id. */
  readonly accountId: string;
  /** Workers AI model, e.g. "@cf/meta/llama-4-scout-17b-16e-instruct". */
  readonly model: string;
  /** API token (SECRET — from env only). Empty string means "not configured". */
  readonly apiToken: string;
}

/** System prompt that shapes the assistant for live-meeting use. */
const SYSTEM_PROMPT =
  'You are zeb Echo, a real-time meeting copilot. A question was just asked in a ' +
  'live meeting. Using the recent transcript as context, give the user a clear, ' +
  'well-reasoned, directly-usable answer they can say out loud.\n\n' +
  'Guidelines:\n' +
  '- Lead with the direct answer in the first sentence, then add 2-4 sentences of ' +
  'useful supporting detail, reasoning, or relevant specifics.\n' +
  '- Ground your answer in the transcript context when it is relevant; if the ' +
  'question refers to something discussed earlier, address that explicitly.\n' +
  '- Be confident and specific. Include concrete examples, names, or numbers when ' +
  'they help.\n' +
  '- If the transcript lacks the detail needed, answer from general knowledge ' +
  'rather than saying you lack context.\n' +
  '- Do not preface with filler like "Sure" or "Great question". Do not use ' +
  'markdown headings.';

export class CloudflareProvider implements LlmProvider {
  public readonly id = 'cloudflare';

  private readonly config: CloudflareConfig;

  constructor(config: CloudflareConfig) {
    this.config = config;
  }

  private get endpoint(): string {
    return `https://api.cloudflare.com/client/v4/accounts/${this.config.accountId}/ai/run/${this.config.model}`;
  }

  public async *generate(request: LlmRequest): AsyncIterable<string> {
    if (this.config.apiToken.length === 0) {
      throw new Error(
        'CloudflareProvider: CF_API_TOKEN is not set. Export it before starting the backend.',
      );
    }

    const response = await fetch(this.endpoint, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${this.config.apiToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        messages: buildMessages(request),
        stream: true,
        max_tokens: request.params.maxTokens,
        temperature: request.params.temperature,
      }),
    });

    if (!response.ok || response.body === null) {
      const detail = await safeReadText(response);
      throw new Error(
        `CloudflareProvider: request failed (${response.status}) ${detail}`,
      );
    }

    // Workers AI streams Server-Sent Events: lines of `data: {json}` plus a
    // terminal `data: [DONE]`. Parse the SSE frames and yield each token.
    yield* parseSseTokens(response.body);
  }

  public async complete(prompt: string, params?: LlmParams): Promise<string> {
    if (this.config.apiToken.length === 0) {
      throw new Error('CloudflareProvider: CF_API_TOKEN is not set.');
    }
    const response = await fetch(this.endpoint, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${this.config.apiToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        messages: [{ role: 'user', content: prompt }],
        max_tokens: params?.maxTokens ?? 256,
        temperature: params?.temperature ?? 0,
      }),
    });
    if (!response.ok) {
      throw new Error(`CloudflareProvider.complete failed (${response.status})`);
    }
    // Non-streaming Workers AI responses are { result: { response: ... } }.
    // `response` is usually a string, but when the model emits JSON the API
    // parses it into an object — re-stringify so callers get the JSON text.
    const json = (await response.json()) as { result?: { response?: unknown } };
    const text = json.result?.response;
    if (typeof text === 'string') {
      return text;
    }
    if (text !== null && text !== undefined && typeof text === 'object') {
      return JSON.stringify(text);
    }
    return '';
  }

  public async isAvailable(): Promise<boolean> {
    if (this.config.apiToken.length === 0) {
      return false;
    }
    try {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 2_000);
      // A tiny non-streaming probe confirms creds + model are reachable.
      const response = await fetch(this.endpoint, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${this.config.apiToken}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          messages: [{ role: 'user', content: 'ping' }],
          max_tokens: 1,
        }),
        signal: controller.signal,
      });
      clearTimeout(timeout);
      return response.ok;
    } catch {
      return false;
    }
  }
}

/** Build chat messages from the system prompt, transcript context, and question. */
function buildMessages(
  request: LlmRequest,
): Array<{ role: 'system' | 'user'; content: string }> {
  const messages: Array<{ role: 'system' | 'user'; content: string }> = [
    { role: 'system', content: SYSTEM_PROMPT },
  ];

  const contextText = request.context
    .map((segment: TranscriptSegment) => segment.text)
    .join(' ')
    .trim();

  // The detected "question" is often just the FRAGMENT where detection fired
  // (e.g. "How do you book") because speech is split across short STT windows.
  // So we give the LLM the full recent transcript as the source of truth and
  // use the fragment only as a pointer to which question to answer.
  if (contextText.length > 0) {
    messages.push({
      role: 'user',
      content:
        `Recent meeting transcript (most recent last):\n` +
        `"""\n${contextText}\n"""\n\n` +
        `The most recent question in this conversation is around: "${request.prompt}".\n` +
        `Speech-to-text may have split or mis-cut it, so silently work out the ` +
        `actual question being asked from the transcript, then answer it.\n\n` +
        `IMPORTANT: Reply with ONLY the answer itself — do NOT restate or quote ` +
        `the question, and do NOT say things like "the full question appears to ` +
        `be". Just give the answer directly, grounded in the conversation above.`,
    });
  } else {
    messages.push({
      role: 'user',
      content: `Answer this question directly: "${request.prompt}"`,
    });
  }

  return messages;
}

/** Read a streamed SSE body and yield the text token from each `data:` frame. */
async function* parseSseTokens(
  body: ReadableStream<Uint8Array>,
): AsyncIterable<string> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';

  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) {
        break;
      }
      buffer += decoder.decode(value, { stream: true });

      // SSE frames are separated by newlines; process complete lines only.
      let newlineIndex = buffer.indexOf('\n');
      while (newlineIndex !== -1) {
        const line = buffer.slice(0, newlineIndex).trim();
        buffer = buffer.slice(newlineIndex + 1);
        const token = tokenFromSseLine(line);
        if (token !== null) {
          yield token;
        }
        newlineIndex = buffer.indexOf('\n');
      }
    }
  } finally {
    reader.releaseLock();
  }
}

/** Extract the response token from a single SSE line, or null to skip it. */
function tokenFromSseLine(line: string): string | null {
  if (!line.startsWith('data:')) {
    return null;
  }
  const payload = line.slice('data:'.length).trim();
  if (payload.length === 0 || payload === '[DONE]') {
    return null;
  }
  try {
    // Each frame looks like { "response": "<token>", ... }.
    const parsed = JSON.parse(payload) as { response?: unknown };
    if (typeof parsed.response === 'string') {
      return parsed.response;
    }
    return null;
  } catch {
    // Partial / non-JSON frame — skip rather than crash the stream.
    return null;
  }
}

/** Read a response body as text without throwing (for error detail). */
async function safeReadText(response: Response): Promise<string> {
  try {
    return (await response.text()).slice(0, 500);
  } catch {
    return '';
  }
}
