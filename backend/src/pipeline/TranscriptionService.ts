/**
 * TranscriptionService (CLAUDE.md §3). Consumes PCM audio chunks and emits
 * partial + final transcript segments with timestamps.
 *
 * Phase 1 ships a FakeTranscriptionService (deterministic, no audio hardware).
 * The real Vosk-backed implementation is a TODO stub.
 */
import type { TranscriptSegment } from '../protocol/messages.js';

/** Callback invoked for every emitted (partial or final) segment. */
export type SegmentListener = (segment: TranscriptSegment) => void;

export interface TranscriptionService {
  /** Register a listener for emitted transcript segments. */
  onSegment(listener: SegmentListener): void;
  /** Feed a raw PCM audio chunk into the recogniser. */
  pushAudio(chunk: Uint8Array): void;
  /** Flush any in-flight hypothesis as a final segment. */
  flush(): void;
  /** Release resources (e.g. the Vosk recogniser). */
  reset(): void;
}

/**
 * Deterministic fake. Ignores actual audio content and, every N chunks, emits
 * a partial then a final segment drawn from a canned script — enough to drive
 * question detection and the rest of the pipeline end-to-end without Vosk.
 */
export class FakeTranscriptionService implements TranscriptionService {
  private readonly listeners: SegmentListener[] = [];
  private readonly chunksPerSegment: number;
  private readonly script: readonly string[];

  private chunkCount = 0;
  private segmentIndex = 0;
  private startMs = Date.now();

  constructor(
    script: readonly string[] = [
      'Hello everyone and thanks for joining.',
      'What is the timeline for the next release?',
      'We should review the budget before Friday.',
      'How will this affect the onboarding flow?',
    ],
    chunksPerSegment = 3,
  ) {
    this.script = script;
    this.chunksPerSegment = chunksPerSegment;
  }

  public onSegment(listener: SegmentListener): void {
    this.listeners.push(listener);
  }

  public pushAudio(_chunk: Uint8Array): void {
    this.chunkCount += 1;

    const text = this.script[this.segmentIndex % this.script.length] ?? '';
    const now = Date.now() - this.startMs;
    const id = `seg-${this.segmentIndex}`;

    // Emit a partial on each chunk; finalise on the Nth chunk.
    const isFinal = this.chunkCount % this.chunksPerSegment === 0;
    this.emit({
      id,
      text,
      startMs: now,
      endMs: now,
      isFinal,
    });

    if (isFinal) {
      this.segmentIndex += 1;
    }
  }

  public flush(): void {
    const text = this.script[this.segmentIndex % this.script.length] ?? '';
    if (text.length === 0) {
      return;
    }
    const now = Date.now() - this.startMs;
    this.emit({ id: `seg-${this.segmentIndex}`, text, startMs: now, endMs: now, isFinal: true });
    this.segmentIndex += 1;
  }

  public reset(): void {
    this.chunkCount = 0;
    this.segmentIndex = 0;
    this.startMs = Date.now();
  }

  private emit(segment: TranscriptSegment): void {
    for (const listener of this.listeners) {
      listener(segment);
    }
  }
}

/**
 * VoskTranscriptionService — real offline STT (CLAUDE.md §2). STUB.
 *
 * TODO(Phase 1 integration): load a Vosk model and recogniser (the exact Node
 * binding is not yet pinned — see §8/§9), feed `pushAudio` chunks into
 * `recognizer.acceptWaveform(chunk)`, and emit partial results from
 * `recognizer.partialResult()` and finals from `recognizer.result()`.
 */
export class VoskTranscriptionService implements TranscriptionService {
  private readonly listeners: SegmentListener[] = [];

  public onSegment(listener: SegmentListener): void {
    this.listeners.push(listener);
  }

  public pushAudio(_chunk: Uint8Array): void {
    // TODO: feed into the Vosk recogniser and emit partial/final segments.
    throw new Error('VoskTranscriptionService is not implemented yet (Phase 1 stub).');
  }

  public flush(): void {
    // TODO: emit recognizer.finalResult().
  }

  public reset(): void {
    // TODO: free the Vosk recogniser/model.
  }
}
