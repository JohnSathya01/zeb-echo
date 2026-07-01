/**
 * Phase 3 integration tests for SessionOrchestrator: Knowledge Base injection
 * and manual/automatic response mode. Uses fakes only (no audio, no network).
 */
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { FakeLlmProvider } from '../llm/FakeLlmProvider.js';
import { LlmResponseService } from '../pipeline/ResponseService.js';
import type {
  DetectedQuestion,
  QuestionDetectionService,
} from '../pipeline/QuestionDetectionService.js';
import type { TranscriptSegment, ServerMessage } from '../protocol/messages.js';
import { SessionOrchestrator } from './SessionOrchestrator.js';

/** Detector that flags every segment as the same question (deterministic). */
class AlwaysQuestion implements QuestionDetectionService {
  private n = 0;
  detect(segment: TranscriptSegment): DetectedQuestion {
    this.n += 1;
    return {
      questionId: `q-${this.n}`,
      text: 'What is the launch date?',
      sourceSegmentId: segment.id,
    };
  }
}

function seg(id: string, text: string): TranscriptSegment {
  return { id, text, startMs: 0, endMs: 0, isFinal: true };
}

function makeOrchestrator(): { orch: SessionOrchestrator; msgs: ServerMessage[] } {
  const provider = new FakeLlmProvider(0);
  const msgs: ServerMessage[] = [];
  const orch = new SessionOrchestrator(
    {
      questionDetection: new AlwaysQuestion(),
      responseService: new LlmResponseService(provider),
      llmProvider: provider,
    },
    (m) => msgs.push(m),
  );
  return { orch, msgs };
}

/** Wait until `predicate` is true or timeout. */
async function until(predicate: () => boolean, ms = 1000): Promise<void> {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((r) => setTimeout(r, 10));
  }
}

test('automatic mode: answer is generated as soon as a question is detected', async () => {
  const { orch, msgs } = makeOrchestrator();
  await orch.start();
  orch.ingestSegment(seg('s1', 'When does it launch?'));

  await until(() => msgs.some((m) => m.type === 'response.done'));
  assert.ok(msgs.some((m) => m.type === 'question.detected'), 'question emitted');
  assert.ok(
    msgs.some((m) => m.type === 'response.token'),
    'auto-answer streamed without an explicit request',
  );
});

test('manual mode: question detected but NO answer until response.generate', async () => {
  const { orch, msgs } = makeOrchestrator();
  await orch.start();
  orch.setResponseMode('manual');
  orch.ingestSegment(seg('s1', 'When does it launch?'));

  // Give it time; in manual mode no tokens should appear.
  await until(() => msgs.some((m) => m.type === 'question.detected'));
  await new Promise((r) => setTimeout(r, 100));
  assert.ok(
    !msgs.some((m) => m.type === 'response.token'),
    'no auto-answer in manual mode',
  );

  // Now explicitly request generation for the detected question.
  const q = msgs.find((m) => m.type === 'question.detected') as
    | { questionId: string }
    | undefined;
  assert.ok(q, 'a question was detected');
  await orch.generateForQuestion(q.questionId);
  await until(() => msgs.some((m) => m.type === 'response.done'));
  assert.ok(
    msgs.some((m) => m.type === 'response.token'),
    'answer generated on demand',
  );
});

test('knowledge base is injected into the response request', async () => {
  const { orch, msgs } = makeOrchestrator();
  await orch.start();
  orch.setKnowledgeBase('Launch date is September 15th.');
  orch.ingestSegment(seg('s1', 'When does it launch?'));

  await until(() => msgs.some((m) => m.type === 'response.done'));
  const answer = msgs
    .filter((m) => m.type === 'response.token')
    .map((m) => (m as { token: string }).token)
    .join('');
  // FakeLlmProvider echoes a [KB:<len>] marker when a KB is present.
  assert.match(answer, /\[KB:\d+\]/, 'KB flowed through to the LLM request');
});

test('no KB → no KB marker in the request', async () => {
  const { orch, msgs } = makeOrchestrator();
  await orch.start();
  orch.ingestSegment(seg('s1', 'When does it launch?'));

  await until(() => msgs.some((m) => m.type === 'response.done'));
  const answer = msgs
    .filter((m) => m.type === 'response.token')
    .map((m) => (m as { token: string }).token)
    .join('');
  assert.doesNotMatch(answer, /\[KB:/, 'no KB marker when none set');
});
