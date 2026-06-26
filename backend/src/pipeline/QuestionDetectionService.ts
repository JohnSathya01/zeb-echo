/**
 * QuestionDetectionService (CLAUDE.md §3). Consumes transcript segments and
 * emits detected questions. Phase 1 uses a lightweight heuristic; a smarter
 * model can replace it behind the same interface later.
 */
import type { TranscriptSegment } from '../protocol/messages.js';

/** A question detected within a transcript segment. */
export interface DetectedQuestion {
  /** Stable id (correlates with response tokens downstream). */
  readonly questionId: string;
  /** The question text. */
  readonly text: string;
  /** Id of the source transcript segment. */
  readonly sourceSegmentId: string;
}

export interface QuestionDetectionService {
  /**
   * Inspect a (final) transcript segment — with optional recent context — and
   * return a detected question, or `null` if there is no genuine question.
   *
   * May be async (e.g. an LLM-backed detector). `recentContext` is the recent
   * transcript so a detector can reconstruct a question split across segments.
   */
  detect(
    segment: TranscriptSegment,
    recentContext?: readonly TranscriptSegment[],
  ): DetectedQuestion | null | Promise<DetectedQuestion | null>;
}

/** Interrogative words that, when leading a sentence, signal a question. */
const QUESTION_WORDS: ReadonlySet<string> = new Set([
  'who',
  'what',
  'when',
  'where',
  'why',
  'how',
  'can',
  'could',
  'would',
  'should',
  'is',
  'are',
  'do',
  'does',
]);

/**
 * Trailing conversational "tag" that STT appends (e.g. "..., right?"). On its
 * own a tag isn't a question; we strip it and judge the remaining clause.
 */
const TRAILING_TAG =
  /,?\s*(right|okay|ok|yeah|yes|no|you know|isn't it|aren't they|huh)\s*\?$/i;

/**
 * Heuristic detector: a segment is a question if its text ends with "?" OR its
 * first word is an interrogative/auxiliary word — minus low-signal fragments.
 */
export class HeuristicQuestionDetectionService implements QuestionDetectionService {
  private counter = 0;

  public detect(segment: TranscriptSegment): DetectedQuestion | null {
    const text = segment.text.trim();
    if (text.length === 0) {
      return null;
    }

    const words = text.split(/\s+/);
    const endsWithQuestionMark = text.endsWith('?');
    const firstWord = text
      .toLowerCase()
      .replace(/^[^a-z]+/, '') // strip leading punctuation/whitespace
      .split(/\s+/)[0];
    const startsWithQuestionWord = firstWord !== undefined && QUESTION_WORDS.has(firstWord);

    if (!endsWithQuestionMark && !startsWithQuestionWord) {
      return null;
    }

    // Filter out low-signal fragments that STT splitting produces. Strip any
    // trailing conversational tag ("..., right?") and judge what's left: a real
    // question either leads with an interrogative word or has enough substance.
    // This keeps "We are shipping this week, right?" but drops bare tags like
    // "scrolling or whatever you call it, right?" only when the lead-in is weak.
    const core = text.replace(TRAILING_TAG, '').trim();
    const coreWords = core.length === 0 ? words : core.split(/\s+/);
    if (!startsWithQuestionWord && coreWords.length < 4) {
      return null;
    }

    this.counter += 1;
    return {
      questionId: `q-${this.counter}`,
      text,
      sourceSegmentId: segment.id,
    };
  }
}
