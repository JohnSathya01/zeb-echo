/**
 * CloudflareTranscriptionService — offloads STT to Cloudflare Workers AI
 * Whisper (CLAUDE.md §2 / §9). Chosen over local Vosk to keep local memory
 * near-zero: no model is loaded on this machine.
 *
 * Whisper on Workers AI is request/response (not a continuous stream), so this
 * service buffers incoming PCM into rolling ~windowMs windows, wraps each as a
 * WAV container, base64-encodes it, and POSTs to the Whisper model. The
 * returned text is emitted as a final transcript segment.
 *
 * Config (account/token/model) is owned here via the constructor; the API token
 * is a SECRET sourced from env upstream (never hardcoded). Only built-in `fetch`
 * is used; nothing Cloudflare-specific leaks outside this module + the LLM dir.
 */
import { AUDIO_FORMAT, type TranscriptSegment } from '../protocol/messages.js';
import type { SegmentListener, TranscriptionService } from './TranscriptionService.js';

export interface CloudflareTranscriptionConfig {
  readonly accountId: string;
  readonly whisperModel: string;
  /** SECRET — from env only. */
  readonly apiToken: string;
  /** Window length (ms) of audio sent per Whisper request. Default 4000. */
  readonly windowMs?: number;
  /** Emit verbose per-window logs to the console. */
  readonly debug?: boolean;
  /**
   * RMS amplitude below which a window is treated as silence and skipped
   * (prevents Whisper hallucinating "Thank you." on quiet audio). 0 disables.
   */
  readonly silenceRms?: number;
}

/** Default rolling window: 4s balances latency vs. recognition accuracy. */
const DEFAULT_WINDOW_MS = 4_000;

/** Default silence floor (s16 RMS, 0..32767). Tuned to skip room/quiet audio. */
const DEFAULT_SILENCE_RMS = 350;

export class CloudflareTranscriptionService implements TranscriptionService {
  private readonly listeners: SegmentListener[] = [];
  private readonly config: CloudflareTranscriptionConfig;
  private readonly windowBytes: number;

  /** Accumulates raw PCM until a full window is ready. */
  private buffer: Buffer = Buffer.alloc(0);
  private segmentIndex = 0;
  private startMs = 0;
  /** Serialises Whisper requests so segments stay in order. */
  private flushChain: Promise<void> = Promise.resolve();

  constructor(config: CloudflareTranscriptionConfig) {
    this.config = config;
    const windowMs = config.windowMs ?? DEFAULT_WINDOW_MS;
    // bytes = sampleRate * channels * bytesPerSample * seconds
    const bytesPerSample = AUDIO_FORMAT.bitDepth / 8;
    this.windowBytes = Math.floor(
      AUDIO_FORMAT.sampleRate *
        AUDIO_FORMAT.channels *
        bytesPerSample *
        (windowMs / 1_000),
    );
  }

  public onSegment(listener: SegmentListener): void {
    this.listeners.push(listener);
  }

  public pushAudio(chunk: Uint8Array): void {
    this.buffer = Buffer.concat([this.buffer, Buffer.from(chunk)]);
    while (this.buffer.length >= this.windowBytes) {
      const window = this.buffer.subarray(0, this.windowBytes);
      this.buffer = this.buffer.subarray(this.windowBytes);
      this.enqueueTranscription(Buffer.from(window));
    }
  }

  public flush(): void {
    if (this.buffer.length > 0) {
      const remaining = this.buffer;
      this.buffer = Buffer.alloc(0);
      this.enqueueTranscription(remaining);
    }
  }

  public reset(): void {
    this.buffer = Buffer.alloc(0);
    this.segmentIndex = 0;
    this.startMs = 0;
    this.flushChain = Promise.resolve();
  }

  /** Queue a window for transcription, preserving emission order. */
  private enqueueTranscription(pcm: Buffer): void {
    this.flushChain = this.flushChain.then(() => this.transcribeWindow(pcm));
  }

  private async transcribeWindow(pcm: Buffer): Promise<void> {
    // Silence gate: skip near-silent windows so Whisper doesn't hallucinate
    // filler ("Thank you.", "Thanks for watching.") on quiet audio.
    const rms = computeRms(pcm);
    const floor = this.config.silenceRms ?? DEFAULT_SILENCE_RMS;
    if (rms < floor) {
      if (this.config.debug) {
        console.log(`[stt] skip silent window (rms=${rms.toFixed(0)} < ${floor})`);
      }
      return;
    }

    const text = await this.callWhisper(pcm);
    const trimmed = text.trim();
    if (this.config.debug) {
      console.log(`[stt] rms=${rms.toFixed(0)} → ${JSON.stringify(trimmed)}`);
    }
    if (trimmed.length === 0 || isHallucination(trimmed)) {
      return;
    }
    if (this.startMs === 0) {
      this.startMs = Date.now();
    }
    const now = Date.now() - this.startMs;
    const segment: TranscriptSegment = {
      id: `seg-${this.segmentIndex}`,
      text: trimmed,
      startMs: now,
      endMs: now,
      isFinal: true,
    };
    this.segmentIndex += 1;
    this.emit(segment);
  }

  /** POST a WAV-wrapped window to Whisper; return recognised text ("" on failure). */
  private async callWhisper(pcm: Buffer): Promise<string> {
    const endpoint = `https://api.cloudflare.com/client/v4/accounts/${this.config.accountId}/ai/run/${this.config.whisperModel}`;
    const wav = pcmToWav(pcm);
    const audioBase64 = wav.toString('base64');
    try {
      const response = await fetch(endpoint, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${this.config.apiToken}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ audio: audioBase64 }),
      });
      if (!response.ok) {
        console.warn(`[whisper] request failed (${response.status})`);
        return '';
      }
      const json = (await response.json()) as {
        result?: { text?: unknown };
      };
      const text = json.result?.text;
      return typeof text === 'string' ? text : '';
    } catch (error) {
      console.warn('[whisper] request error:', error);
      return '';
    }
  }

  private emit(segment: TranscriptSegment): void {
    for (const listener of this.listeners) {
      listener(segment);
    }
  }
}

/** Root-mean-square amplitude of signed-16-bit-LE PCM (0..32767). */
function computeRms(pcm: Buffer): number {
  const sampleCount = Math.floor(pcm.length / 2);
  if (sampleCount === 0) {
    return 0;
  }
  let sumSquares = 0;
  for (let i = 0; i + 1 < pcm.length; i += 2) {
    const sample = pcm.readInt16LE(i);
    sumSquares += sample * sample;
  }
  return Math.sqrt(sumSquares / sampleCount);
}

/** Common Whisper-on-silence outputs we never want to surface as a transcript. */
const HALLUCINATIONS = new Set<string>([
  'thank you.',
  'thank you',
  'thanks for watching.',
  'thanks for watching!',
  'you',
  '.',
  'bye.',
  'bye bye.',
  'okay.',
]);

function isHallucination(text: string): boolean {
  return HALLUCINATIONS.has(text.toLowerCase().trim());
}

/**
 * Wrap raw PCM (16 kHz mono s16le per AUDIO_FORMAT) in a minimal 44-byte WAV
 * header so Whisper can decode it as a self-describing audio file.
 */
function pcmToWav(pcm: Buffer): Buffer {
  const { sampleRate, channels, bitDepth } = AUDIO_FORMAT;
  const bytesPerSample = bitDepth / 8;
  const byteRate = sampleRate * channels * bytesPerSample;
  const blockAlign = channels * bytesPerSample;
  const dataSize = pcm.length;

  const header = Buffer.alloc(44);
  header.write('RIFF', 0);
  header.writeUInt32LE(36 + dataSize, 4); // ChunkSize
  header.write('WAVE', 8);
  header.write('fmt ', 12);
  header.writeUInt32LE(16, 16); // Subchunk1Size (PCM)
  header.writeUInt16LE(1, 20); // AudioFormat = PCM
  header.writeUInt16LE(channels, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(byteRate, 28);
  header.writeUInt16LE(blockAlign, 32);
  header.writeUInt16LE(bitDepth, 34);
  header.write('data', 36);
  header.writeUInt32LE(dataSize, 40);

  return Buffer.concat([header, pcm]);
}
