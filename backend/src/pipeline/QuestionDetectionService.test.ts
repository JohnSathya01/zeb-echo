/**
 * Tests for the heuristic question detector (node:test).
 */
import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { TranscriptSegment } from '../protocol/messages.js';
import { HeuristicQuestionDetectionService } from './QuestionDetectionService.js';

function segment(text: string, id = 'seg-0'): TranscriptSegment {
  return { id, text, startMs: 0, endMs: 0, isFinal: true };
}

test('detects sentences ending with a question mark', () => {
  const detector = new HeuristicQuestionDetectionService();
  const result = detector.detect(segment('We are shipping this week, right?'));
  assert.notEqual(result, null);
  assert.equal(result?.text, 'We are shipping this week, right?');
  assert.equal(result?.sourceSegmentId, 'seg-0');
});

test('detects sentences starting with a question word (no "?")', () => {
  const detector = new HeuristicQuestionDetectionService();
  for (const q of [
    'What is the deadline',
    'How does the onboarding work',
    'Can we ship on Friday',
    'Is the budget approved',
    'Should we delay the launch',
  ]) {
    assert.notEqual(detector.detect(segment(q)), null, `expected a question: "${q}"`);
  }
});

test('ignores plain statements', () => {
  const detector = new HeuristicQuestionDetectionService();
  for (const s of [
    'We should review the budget before Friday.',
    'Thanks everyone for joining today.',
    'The release is on track.',
    '',
    '   ',
  ]) {
    assert.equal(detector.detect(segment(s)), null, `expected NOT a question: "${s}"`);
  }
});

test('ignores bare conversational tag fragments', () => {
  const detector = new HeuristicQuestionDetectionService();
  // Bare tags STT emits as their own segment are not real questions.
  for (const s of ['right?', 'you know?', 'okay?', 'yeah?']) {
    assert.equal(detector.detect(segment(s)), null, `expected NOT a question: "${s}"`);
  }
  // But a substantive clause with a trailing tag IS still a question.
  assert.notEqual(
    detector.detect(segment('We are shipping this week, right?')),
    null,
  );
});

test('detection is case-insensitive for leading question words', () => {
  const detector = new HeuristicQuestionDetectionService();
  assert.notEqual(detector.detect(segment('WHO is presenting next')), null);
});

test('assigns unique, incrementing question ids', () => {
  const detector = new HeuristicQuestionDetectionService();
  const a = detector.detect(segment('What time is it?'));
  const b = detector.detect(segment('Where are we meeting?'));
  assert.notEqual(a?.questionId, b?.questionId);
});
