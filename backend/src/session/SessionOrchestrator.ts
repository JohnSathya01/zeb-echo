/**
 * SessionOrchestrator (CLAUDE.md §3). Wires the pipeline together:
 *
 *   audio chunks → TranscriptionService → QuestionDetectionService
 *               → ResponseService → LlmProvider → response tokens
 *
 * Owns the session lifecycle (start / pause / stop), records latency metrics
 * (question-detected → first response token), and emits ServerMessages via a
 * callback. It does not know about WebSockets — the WsGateway adapts the
 * callback to the wire.
 */
import type { LlmProvider } from '../llm/LlmProvider.js';
import type {
  QuestionDetectionService,
  DetectedQuestion,
} from '../pipeline/QuestionDetectionService.js';
import type { ResponseService } from '../pipeline/ResponseService.js';
import type { TranscriptionService } from '../pipeline/TranscriptionService.js';
import {
  PROTOCOL_VERSION,
  type ResponseMode,
  type ServerMessage,
  type TranscriptSegment,
} from '../protocol/messages.js';

/** Sink for outbound server messages (the gateway encodes + sends them). */
export type ServerMessageSink = (message: ServerMessage) => void;

type SessionState = 'idle' | 'running' | 'paused' | 'stopped';

export interface SessionDependencies {
  /**
   * Optional single transcription for the legacy client-fed audio path
   * (binary audio.chunk frames). When the backend captures audio itself via
   * the AudioSourceManager, segments arrive through {@link SessionOrchestrator.ingestSegment}
   * instead and this is omitted.
   */
  readonly transcription?: TranscriptionService;
  readonly questionDetection: QuestionDetectionService;
  readonly responseService: ResponseService;
  readonly llmProvider: LlmProvider;
}

/** A single recorded latency sample. */
export interface LatencySample {
  readonly questionId: string;
  /** Milliseconds from question detected → first response token. */
  readonly firstTokenLatencyMs: number;
}

export class SessionOrchestrator {
  private readonly deps: SessionDependencies;
  private readonly emit: ServerMessageSink;

  private state: SessionState = 'idle';
  /** Bounded rolling transcript context for the LLM. */
  private readonly context: TranscriptSegment[] = [];
  private readonly maxContext = 50;
  private readonly latencies: LatencySample[] = [];

  /** Phase 3: user-provided Knowledge Base injected into every answer. */
  private knowledgeBase = '';
  /** Phase 3: 'auto' answers on detection; 'manual' waits for generate. */
  private responseMode: ResponseMode = 'auto';
  /**
   * Phase 3: detected questions retained so a manual `response.generate` can
   * rebuild the exact prompt (question + the context snapshot at detection).
   * Bounded to avoid unbounded growth over a long session.
   */
  private readonly pendingQuestions = new Map<
    string,
    { question: DetectedQuestion; context: TranscriptSegment[] }
  >();
  private readonly maxPending = 30;
  /**
   * Delay (ms) between detecting a question and generating, so segments that
   * complete the question can arrive in context first. ~1 STT window.
   */
  private readonly responseDelayMs: number;

  constructor(
    deps: SessionDependencies,
    sink: ServerMessageSink,
    // The LLM detector already reconstructs the full question from context, so
    // no extra wait is needed before responding. Heuristic mode can pass >0.
    responseDelayMs = 0,
  ) {
    this.deps = deps;
    this.emit = sink;
    this.responseDelayMs = responseDelayMs;
    // Legacy client-fed path: a single transcription feeds segments directly.
    this.deps.transcription?.onSegment((segment) => this.handleSegment(segment));
  }

  /**
   * Ingest an already-transcribed (and possibly speaker-labelled) segment from
   * an external source (the backend-side AudioSourceManager). Runs the same
   * transcript → question → response path as the client-fed transcription.
   */
  public ingestSegment(segment: TranscriptSegment): void {
    if (this.state !== 'running') {
      return;
    }
    this.handleSegment(segment);
  }

  /** Start (or resume) processing. */
  public async start(): Promise<void> {
    if (this.state === 'running') {
      return;
    }
    this.state = 'running';
    this.emitStatus('pipeline', 'starting', 'Session starting');

    // Probe the provider so the client learns about provider health up front.
    const available = await this.deps.llmProvider.isAvailable();
    this.emitStatus(
      'provider',
      available ? 'ok' : 'unavailable',
      `LLM provider "${this.deps.llmProvider.id}" ${available ? 'reachable' : 'unavailable'}`,
    );
    this.emitStatus('pipeline', 'ok', 'Session running');
  }

  /** Pause processing without tearing down state. */
  public pause(): void {
    if (this.state !== 'running') {
      return;
    }
    this.state = 'paused';
    this.emitStatus('pipeline', 'degraded', 'Session paused');
  }

  /** Stop the session and release pipeline resources. */
  public stop(): void {
    if (this.state === 'stopped') {
      return;
    }
    this.state = 'stopped';
    // Flush any buffered trailing audio to a final segment before releasing.
    this.deps.transcription?.flush();
    this.deps.transcription?.reset();
    this.emitStatus('pipeline', 'ok', 'Session stopped');
  }

  /** Feed a raw PCM audio chunk into the pipeline (ignored unless running). */
  public pushAudio(chunk: Uint8Array): void {
    if (this.state !== 'running') {
      return;
    }
    this.deps.transcription?.pushAudio(chunk);
  }

  /** Snapshot of recorded latency samples (for metrics/inspection). */
  public getLatencies(): readonly LatencySample[] {
    return this.latencies;
  }

  // -------------------------------------------------------------------------

  private handleSegment(segment: TranscriptSegment): void {
    // Stream transcript to the client (partial or final).
    this.emit({
      type: segment.isFinal ? 'transcript.final' : 'transcript.partial',
      version: PROTOCOL_VERSION,
      segment,
    });

    if (!segment.isFinal) {
      return;
    }

    // Maintain bounded context.
    this.context.push(segment);
    if (this.context.length > this.maxContext) {
      this.context.shift();
    }

    // Question detection runs on finalised segments only. It may be async (an
    // LLM-backed detector), so run it without blocking transcript streaming.
    void this.detectAndRespond(segment);
  }

  private async detectAndRespond(segment: TranscriptSegment): Promise<void> {
    let question: DetectedQuestion | null;
    try {
      // Pass recent context so the detector can reconstruct a question split
      // across short STT segments.
      question = await this.deps.questionDetection.detect(segment, [...this.context]);
    } catch {
      return; // Detection failure must never crash the session.
    }
    if (question === null || this.state !== 'running') {
      return;
    }
    this.emit({
      type: 'question.detected',
      version: PROTOCOL_VERSION,
      questionId: question.questionId,
      text: question.text,
      sourceSegmentId: question.sourceSegmentId,
    });

    // Retain the question + its context snapshot so manual mode can generate
    // later. Snapshot now so the answer uses the context as it was when asked.
    this.retainQuestion(question, [...this.context]);

    // Manual mode: stop here — the user clicks ▶ (response.generate) to answer.
    if (this.responseMode === 'manual') {
      return;
    }
    // Automatic mode: fire-and-forget the response stream immediately.
    void this.respond(question, [...this.context]);
  }

  /** Retain a detected question (+ context) for on-demand manual generation. */
  private retainQuestion(
    question: DetectedQuestion,
    context: TranscriptSegment[],
  ): void {
    this.pendingQuestions.set(question.questionId, { question, context });
    // Evict oldest if over the cap (Map preserves insertion order).
    while (this.pendingQuestions.size > this.maxPending) {
      const oldest = this.pendingQuestions.keys().next().value;
      if (oldest === undefined) {
        break;
      }
      this.pendingQuestions.delete(oldest);
    }
  }

  // ------------------------------- Phase 3 API -----------------------------

  /** Set/replace the session Knowledge Base (injected into every answer). */
  public setKnowledgeBase(content: string): void {
    this.knowledgeBase = content.trim();
  }

  /** Switch response generation mode (auto answers on detection; manual waits). */
  public setResponseMode(mode: ResponseMode): void {
    this.responseMode = mode;
  }

  /** Generate the answer for a previously-detected question (manual ▶). */
  public async generateForQuestion(questionId: string): Promise<void> {
    if (this.state !== 'running') {
      return;
    }
    const pending = this.pendingQuestions.get(questionId);
    if (pending === undefined) {
      return; // Unknown/expired question id — ignore.
    }
    await this.respond(pending.question, pending.context);
  }

  private async respond(
    question: DetectedQuestion,
    contextSnapshot: TranscriptSegment[],
  ): Promise<void> {
    const detectedAt = performance.now();
    let firstTokenLatencyMs: number | undefined;

    // In auto mode we wait briefly so segments completing a split question
    // arrive first; in manual mode the user already chose to answer, so the
    // context is whatever was captured at detection (no extra wait).
    await new Promise((resolve) => setTimeout(resolve, this.responseDelayMs));
    if (this.state !== 'running') {
      return;
    }

    try {
      for await (const token of this.deps.responseService.respond(
        question,
        contextSnapshot,
        this.knowledgeBase,
      )) {
        if (firstTokenLatencyMs === undefined) {
          firstTokenLatencyMs = performance.now() - detectedAt;
          this.latencies.push({ questionId: question.questionId, firstTokenLatencyMs });
        }
        this.emit({
          type: 'response.token',
          version: PROTOCOL_VERSION,
          questionId: question.questionId,
          token,
        });
      }
      this.emit({
        type: 'response.done',
        version: PROTOCOL_VERSION,
        questionId: question.questionId,
        ...(firstTokenLatencyMs !== undefined ? { firstTokenLatencyMs } : {}),
      });
    } catch (err) {
      // Provider failure must NOT crash the session (§3.1).
      const message = err instanceof Error ? err.message : String(err);
      this.emit({
        type: 'error',
        version: PROTOCOL_VERSION,
        code: 'response_failed',
        message: `Response generation failed: ${message}`,
      });
      this.emitStatus('provider', 'degraded', message);
    }
  }

  private emitStatus(
    domain: 'pipeline' | 'provider' | 'audio',
    state: 'ok' | 'starting' | 'degraded' | 'unavailable',
    detail: string,
  ): void {
    this.emit({ type: 'status', version: PROTOCOL_VERSION, domain, state, detail });
  }
}
