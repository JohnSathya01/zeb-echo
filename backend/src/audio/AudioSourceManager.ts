/**
 * AudioSourceManager (CLAUDE.md §3 / §4.1). Owns the two independently
 * toggleable capture sources — microphone and system audio — each with its own
 * ffmpeg capture (SystemAudioCapture) and its own TranscriptionService.
 *
 * Each source's transcript segments are tagged with a speaker label ("You" for
 * the mic, "Them" for system audio) and a source-prefixed id so segments from
 * the two streams never collide. Disabling a source stops its ffmpeg, so its
 * audio is never transcribed (exactly: off = no data leaves that source).
 */
import {
  type AudioSourceId,
  type TranscriptSegment,
} from '../protocol/messages.js';
import type { TranscriptionService } from '../pipeline/TranscriptionService.js';
import { SystemAudioCapture } from './SystemAudioCapture.js';

/** Human-facing speaker label per source. */
const SPEAKER_LABEL: Record<AudioSourceId, string> = {
  mic: 'You',
  system: 'Them',
};

/** Emitted when a source produces a (labelled) transcript segment. */
export type LabeledSegmentListener = (segment: TranscriptSegment) => void;

/** Emitted on a source's capture health change. */
export type SourceStatusListener = (status: {
  source: AudioSourceId;
  ok: boolean;
  detail: string;
}) => void;

/** Builds a fresh TranscriptionService instance (one per source). */
export type TranscriptionFactory = () => TranscriptionService;

export interface AudioSourceManagerConfig {
  /** avfoundation device index for the microphone. */
  readonly micDeviceIndex: string;
  /** avfoundation device index for system audio (BlackHole). */
  readonly systemDeviceIndex: string;
  /** Whether each source starts enabled. */
  readonly micEnabled: boolean;
  readonly systemEnabled: boolean;
  /** Factory for a per-source transcription service. */
  readonly createTranscription: TranscriptionFactory;
}

/** Internal per-source state. */
interface SourceRuntime {
  readonly id: AudioSourceId;
  readonly deviceIndex: string;
  enabled: boolean;
  capture: SystemAudioCapture | null;
  transcription: TranscriptionService | null;
}

export class AudioSourceManager {
  private readonly cfg: AudioSourceManagerConfig;
  private readonly segmentListeners: LabeledSegmentListener[] = [];
  private readonly statusListeners: SourceStatusListener[] = [];
  private readonly sources: Record<AudioSourceId, SourceRuntime>;
  private started = false;

  constructor(cfg: AudioSourceManagerConfig) {
    this.cfg = cfg;
    this.sources = {
      mic: {
        id: 'mic',
        deviceIndex: cfg.micDeviceIndex,
        enabled: cfg.micEnabled,
        capture: null,
        transcription: null,
      },
      system: {
        id: 'system',
        deviceIndex: cfg.systemDeviceIndex,
        enabled: cfg.systemEnabled,
        capture: null,
        transcription: null,
      },
    };
  }

  public onSegment(listener: LabeledSegmentListener): void {
    this.segmentListeners.push(listener);
  }

  public onStatus(listener: SourceStatusListener): void {
    this.statusListeners.push(listener);
  }

  /** Start every currently-enabled source. */
  public start(): void {
    this.started = true;
    for (const id of Object.keys(this.sources) as AudioSourceId[]) {
      const src = this.sources[id];
      if (src.enabled) {
        this.startSource(src);
      } else {
        // Report the disabled state so the UI chip shows "off", not "error".
        this.emitStatus(id, false, 'Source disabled');
      }
    }
  }

  /** Stop all capture and release per-source transcription. */
  public stop(): void {
    this.started = false;
    for (const id of Object.keys(this.sources) as AudioSourceId[]) {
      this.stopSource(this.sources[id]);
    }
  }

  /** Enable/disable one source at runtime (idempotent). */
  public setEnabled(id: AudioSourceId, enabled: boolean): void {
    const src = this.sources[id];
    if (src.enabled === enabled) {
      return;
    }
    src.enabled = enabled;
    if (!this.started) {
      return; // Will take effect on next start().
    }
    if (enabled) {
      this.startSource(src);
    } else {
      this.stopSource(src);
      this.emitStatus(id, false, 'Source disabled');
    }
  }

  // -------------------------------------------------------------------------

  private startSource(src: SourceRuntime): void {
    if (src.capture !== null) {
      return; // Already running.
    }
    const transcription = this.cfg.createTranscription();
    transcription.onSegment((segment) => {
      // Tag with speaker + source-prefixed id so streams never collide.
      this.emitSegment({
        ...segment,
        id: `${src.id}-${segment.id}`,
        speaker: SPEAKER_LABEL[src.id],
      });
    });

    const capture = new SystemAudioCapture({ deviceIndex: src.deviceIndex });
    capture.onChunk((chunk) => transcription.pushAudio(chunk));
    capture.onStatus(({ ok, detail }) => this.emitStatus(src.id, ok, detail));

    src.transcription = transcription;
    src.capture = capture;
    capture.start();
  }

  private stopSource(src: SourceRuntime): void {
    if (src.capture !== null) {
      src.capture.stop();
      src.capture = null;
    }
    if (src.transcription !== null) {
      src.transcription.flush();
      src.transcription.reset();
      src.transcription = null;
    }
  }

  private emitSegment(segment: TranscriptSegment): void {
    for (const l of this.segmentListeners) {
      l(segment);
    }
  }

  private emitStatus(source: AudioSourceId, ok: boolean, detail: string): void {
    for (const l of this.statusListeners) {
      l({ source, ok, detail });
    }
  }
}
