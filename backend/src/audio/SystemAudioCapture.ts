/**
 * SystemAudioCapture (CLAUDE.md §3 / §10). Captures system audio output on
 * macOS by spawning ffmpeg against an avfoundation input device — in practice
 * the BlackHole virtual device that Teams/system audio is routed into.
 *
 * ffmpeg decodes to raw PCM matching AUDIO_FORMAT (16 kHz mono s16le) on stdout,
 * which we slice into fixed-size chunks and hand to a listener (the transcription
 * pipeline). This keeps all heavy audio/ML work in the backend, off the client.
 */
import { spawn, type ChildProcessWithoutNullStreams, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { AUDIO_FORMAT } from '../protocol/messages.js';

const execFileAsync = promisify(execFile);

/**
 * Path to the ffmpeg binary. In dev it's on PATH ("ffmpeg"); in the packaged
 * desktop app the Flutter launcher sets FFMPEG_PATH to the bundled binary
 * (ffmpeg isn't installed on teammates' machines). Resolved once at load.
 */
const FFMPEG_PATH = process.env.FFMPEG_PATH ?? 'ffmpeg';

/** Listener for captured PCM chunks. */
export type AudioChunkListener = (chunk: Buffer) => void;

export interface SystemAudioCaptureConfig {
  /** avfoundation device index for the audio input (e.g. BlackHole). */
  readonly deviceIndex: string;
  /** Emitted chunk size in bytes. Default ≈ 100ms of audio. */
  readonly chunkBytes?: number;
}

/** Listener for capture lifecycle/health changes. */
export type CaptureStatusListener = (status: {
  ok: boolean;
  detail: string;
}) => void;

export class SystemAudioCapture {
  private readonly listeners: AudioChunkListener[] = [];
  private readonly statusListeners: CaptureStatusListener[] = [];
  private readonly config: SystemAudioCaptureConfig;
  private proc: ChildProcessWithoutNullStreams | null = null;
  private pending: Buffer = Buffer.alloc(0);
  private readonly chunkBytes: number;
  private running = false;
  private restartTimer: NodeJS.Timeout | null = null;
  private gotData = false;

  constructor(config: SystemAudioCaptureConfig) {
    this.config = config;
    // ~100ms windows: sampleRate * channels * bytesPerSample * 0.1
    const bytesPerSample = AUDIO_FORMAT.bitDepth / 8;
    this.chunkBytes =
      config.chunkBytes ??
      Math.floor(AUDIO_FORMAT.sampleRate * AUDIO_FORMAT.channels * bytesPerSample * 0.1);
  }

  public onChunk(listener: AudioChunkListener): void {
    this.listeners.push(listener);
  }

  public onStatus(listener: CaptureStatusListener): void {
    this.statusListeners.push(listener);
  }

  private emitStatus(ok: boolean, detail: string): void {
    for (const l of this.statusListeners) {
      l({ ok, detail });
    }
  }

  /** Start ffmpeg capturing from the configured avfoundation device. */
  public start(): void {
    this.running = true;
    this.spawnFfmpeg();
  }

  private spawnFfmpeg(): void {
    if (this.proc !== null) {
      return;
    }
    // -f avfoundation -i ":<idx>"  => audio-only input from device <idx>.
    // Output raw signed 16-bit LE PCM, mono, 16 kHz, to stdout (pipe:1).
    const args = [
      '-f',
      'avfoundation',
      '-i',
      `:${this.config.deviceIndex}`,
      '-ac',
      String(AUDIO_FORMAT.channels),
      '-ar',
      String(AUDIO_FORMAT.sampleRate),
      '-f',
      's16le',
      '-loglevel',
      'error',
      'pipe:1',
    ];
    const proc = spawn(FFMPEG_PATH, args);
    this.proc = proc;

    proc.stdout.on('data', (data: Buffer) => {
      // Ignore late buffered frames after stop() so we don't re-emit a
      // "capturing" status for a source that was just disabled.
      if (!this.running) {
        return;
      }
      if (!this.gotData) {
        this.gotData = true;
        this.emitStatus(true, `Capturing audio from device :${this.config.deviceIndex}`);
      }
      this.onData(data);
    });
    proc.stderr.on('data', (data: Buffer) => {
      console.warn('[audio] ffmpeg:', data.toString().trim());
    });
    proc.on('error', (err) => {
      console.error('[audio] failed to start ffmpeg:', err.message);
      this.emitStatus(false, `ffmpeg failed to start: ${err.message}`);
    });
    proc.on('close', (code) => {
      this.proc = null;
      if (!this.running) {
        return; // intentional stop
      }
      // Transient device error (avfoundation often returns 255 when the device
      // momentarily has no stream). Retry a few times before giving up.
      console.warn(`[audio] ffmpeg exited with code ${code}; retrying capture…`);
      this.emitStatus(false, `Audio capture interrupted (code ${code}); retrying`);
      this.scheduleRestart();
    });
  }

  private scheduleRestart(): void {
    if (this.restartTimer !== null || !this.running) {
      return;
    }
    this.restartTimer = setTimeout(() => {
      this.restartTimer = null;
      if (this.running) {
        this.spawnFfmpeg();
      }
    }, 1_000);
  }

  /** Stop capturing and release ffmpeg. */
  public stop(): void {
    this.running = false;
    this.gotData = false;
    if (this.restartTimer !== null) {
      clearTimeout(this.restartTimer);
      this.restartTimer = null;
    }
    if (this.proc !== null) {
      this.proc.kill('SIGTERM');
      this.proc = null;
    }
    this.pending = Buffer.alloc(0);
  }

  private onData(data: Buffer): void {
    this.pending = Buffer.concat([this.pending, data]);
    while (this.pending.length >= this.chunkBytes) {
      const chunk = this.pending.subarray(0, this.chunkBytes);
      this.pending = this.pending.subarray(this.chunkBytes);
      const out = Buffer.from(chunk);
      for (const listener of this.listeners) {
        listener(out);
      }
    }
  }
}

/**
 * List avfoundation audio input devices via ffmpeg, returning the raw device
 * listing so the user can find the BlackHole device index. ffmpeg prints the
 * device table to stderr and exits non-zero (no output specified) — that's
 * expected, so we read stderr regardless.
 */
export async function listAudioDevices(): Promise<string> {
  try {
    await execFileAsync(FFMPEG_PATH, [
      '-f',
      'avfoundation',
      '-list_devices',
      'true',
      '-i',
      '',
    ]);
    return '';
  } catch (error) {
    // ffmpeg exits 1 here by design; the device table is on stderr.
    const stderr = (error as { stderr?: string }).stderr;
    return typeof stderr === 'string' ? stderr : String(error);
  }
}
