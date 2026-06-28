/**
 * LlmQuestionDetectionService (CLAUDE.md §3). A smarter question detector that
 * uses the LLM to decide whether a genuine, answerable question was just asked
 * — and to reconstruct the FULL question even when speech-to-text split it
 * across several short segments.
 *
 * It depends only on the provider-agnostic `LlmProvider` (§3.1), never on a
 * specific backend. A cheap heuristic pre-gate avoids an LLM call on segments
 * that clearly aren't question-like, keeping cost/latency down.
 */
import type { LlmProvider } from '../llm/LlmProvider.js';
import type { TranscriptSegment } from '../protocol/messages.js';
import type {
  DetectedQuestion,
  QuestionDetectionService,
} from './QuestionDetectionService.js';

/**
 * Interrogative / auxiliary words that hint at a question, used by the cheap
 * pre-gate. Kept broad so we rarely miss a real question; the LLM makes the
 * final call, so false positives here only cost an extra check.
 */
const QUESTION_HINTS: ReadonlySet<string> = new Set([
  'who', 'what', 'whats', 'when', 'where', 'why', 'how', 'hows', 'which', 'whom', 'whose',
  'can', 'could', 'would', 'should', 'shall', 'will', 'is', 'are', 'am', 'was', 'were',
  'do', 'does', 'did', 'has', 'have', 'had', 'may', 'might', 'must',
  'any', 'anyone', 'anybody',
]);

/** Phrases that commonly introduce an (implicit) question mid-sentence. */
const QUESTION_PHRASES: readonly string[] = [
  'what about', 'how about', 'what if', 'tell me', 'explain', 'wondering',
  'curious', 'question is', 'do you think', 'what do you', 'how do you',
  'any idea', 'anyone know', 'thoughts on',
];

export class LlmQuestionDetectionService implements QuestionDetectionService {
  private counter = 0;
  private readonly provider: LlmProvider;
  private readonly debug: boolean;
  /** De-dupe: avoid re-detecting the same reconstructed question back-to-back. */
  private lastQuestion = '';

  constructor(provider: LlmProvider, debug = false) {
    this.provider = provider;
    this.debug = debug;
  }

  public async detect(
    segment: TranscriptSegment,
    recentContext: readonly TranscriptSegment[] = [],
  ): Promise<DetectedQuestion | null> {
    const text = segment.text.trim();
    if (text.length === 0) {
      return null;
    }

    // Cheap pre-gate: spend an LLM call when this segment looks question-like,
    // OR when a very recent segment did (the question may be split across STT
    // windows, e.g. "How do you book" + "your hotels or flights today.").
    const recentLooksQuestion = recentContext
      .slice(-2)
      .some((s) => this.looksQuestionLike(s.text.trim()));
    if (!this.looksQuestionLike(text) && !recentLooksQuestion) {
      return null;
    }

    const contextText = recentContext
      .map((s) => s.text)
      .join(' ')
      .trim();

    const prompt = this.buildPrompt(contextText, text);

    let raw: string;
    try {
      // 200 tokens: room for the question + one-sentence contextSummary JSON
      // without truncation. Still tiny — no meaningful latency impact.
      raw = await this.provider.complete(prompt, { temperature: 0, maxTokens: 200 });
    } catch (err) {
      // On any provider error, fail safe: emit nothing (the session continues).
      if (this.debug) {
        console.warn('[qdetect] LLM error:', err instanceof Error ? err.message : err);
      }
      return null;
    }

    const parsed = parseDecision(raw);
    if (this.debug) {
      console.log(`[qdetect] seg=${JSON.stringify(text)} → ${JSON.stringify(parsed)}`);
    }
    if (parsed === null || !parsed.isQuestion) {
      return null;
    }

    const question = parsed.question.trim();
    if (question.length === 0 || question === this.lastQuestion) {
      return null;
    }
    this.lastQuestion = question;

    this.counter += 1;
    return {
      questionId: `q-${this.counter}`,
      text: question,
      sourceSegmentId: segment.id,
      contextSummary: parsed.contextSummary.trim(),
    };
  }

  private looksQuestionLike(text: string): boolean {
    if (text.includes('?')) {
      return true;
    }
    const lower = text.toLowerCase();
    // Any interrogative/auxiliary word ANYWHERE (not just the first) — speech
    // is split mid-sentence, so the question word may not lead the segment.
    const words = lower.replace(/[^a-z\s]/g, ' ').split(/\s+/).filter(Boolean);
    if (words.some((w) => QUESTION_HINTS.has(w))) {
      return true;
    }
    // Common question-introducing phrases.
    return QUESTION_PHRASES.some((p) => lower.includes(p));
  }

  private buildPrompt(contextText: string, latest: string): string {
    return (
      `You are analysing a live meeting transcript to find genuine questions ` +
      `someone would want an answer to.\n\n` +
      (contextText.length > 0
        ? `Recent transcript (most recent last):\n"""\n${contextText}\n"""\n\n`
        : '') +
      `The latest line is: "${latest}"\n\n` +
      `Decide whether a genuine, answerable question was just asked. Rules:\n` +
      `- Ignore rhetorical filler and conversational tags ("right?", "you ` +
      `know?", "okay?").\n` +
      `- Speech-to-text may split one question across several lines — if so, ` +
      `stitch them into the complete question.\n` +
      `- Make the question SELF-CONTAINED: resolve vague references using the ` +
      `transcript. E.g. if someone asks "What is that?" right after discussing ` +
      `an orchestration system, rewrite it as "What is an orchestration ` +
      `system?". Replace pronouns like "it/that/this/they" with the actual ` +
      `subject from the conversation.\n` +
      `- Capture the question even when it is embedded mid-sentence ("And what ` +
      `is an agent harness? Think of it...").\n` +
      `- Also write a ONE-SENTENCE "contextSummary": the topic/situation the ` +
      `question sits in, drawn from the transcript (e.g. "Discussion about the ` +
      `economic impact of AI coding tools and historical GDP growth."). This ` +
      `grounds the downstream answer. Empty if there is no question.\n\n` +
      `Respond with ONLY a JSON object, no prose:\n` +
      `{"isQuestion": true|false, "question": "<the full, self-contained question, or empty>", ` +
      `"contextSummary": "<one-sentence topic summary, or empty>"}`
    );
  }
}

/** Decision shape returned by the classifier prompt. */
interface Decision {
  isQuestion: boolean;
  question: string;
  contextSummary: string;
}

/** Parse the model's JSON decision, tolerating surrounding prose/code fences. */
function parseDecision(raw: string): Decision | null {
  const match = raw.match(/\{[\s\S]*\}/);
  if (match === null) {
    return null;
  }
  try {
    const obj = JSON.parse(match[0]) as {
      isQuestion?: unknown;
      question?: unknown;
      contextSummary?: unknown;
    };
    return {
      isQuestion: obj.isQuestion === true,
      question: typeof obj.question === 'string' ? obj.question : '',
      contextSummary:
        typeof obj.contextSummary === 'string' ? obj.contextSummary : '',
    };
  } catch {
    return null;
  }
}
