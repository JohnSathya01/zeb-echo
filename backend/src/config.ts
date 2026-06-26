/**
 * Backend configuration, loaded from environment variables with safe defaults
 * (CLAUDE.md §3.1, §6). No secrets live in source — anything sensitive must come
 * from env / a git-ignored .env file.
 */
import type { ProviderId } from './llm/index.js';

export interface AppConfig {
  /** WebSocket listen port (localhost only). */
  readonly port: number;
  /** Host to bind — pinned to localhost in Phase 1 for privacy. */
  readonly host: string;
  /** Selected LLM provider id. */
  readonly llmProvider: ProviderId;
  /** Ollama base URL (owned by OllamaProvider). */
  readonly ollamaUrl: string;
  /** Ollama model tag. */
  readonly ollamaModel: string;
  /** Cloudflare account id (owned by CloudflareProvider). */
  readonly cfAccountId: string;
  /** Cloudflare Workers AI model. */
  readonly cfModel: string;
  /** Cloudflare API token — SECRET, from env only (empty = not configured). */
  readonly cfApiToken: string;
  /** Cloudflare Whisper STT model (used by CloudflareTranscriptionService). */
  readonly cfWhisperModel: string;
  /** Transcription engine: "cloudflare" (Whisper) | "fake". */
  readonly transcriptionEngine: TranscriptionEngine;
  /** Audio capture source: "blackhole" (ffmpeg) | "none" (client-fed/fake). */
  readonly audioSource: AudioSource;
  /** avfoundation device index for SYSTEM audio (BlackHole loopback). */
  readonly audioDeviceIndex: string;
  /** avfoundation device index for the MICROPHONE input. */
  readonly micDeviceIndex: string;
  /** Whether the system-audio source starts enabled (default true). */
  readonly systemEnabledDefault: boolean;
  /** Whether the microphone source starts enabled (default false, avoids echo). */
  readonly micEnabledDefault: boolean;
  /** Verbose transcription logging (per-window RMS + text) to the console. */
  readonly sttDebug: boolean;
  /**
   * Whisper rolling-window length in ms. Smaller = lower latency but choppier
   * and slightly less accurate; larger = more accurate but more lag. Default 2000.
   */
  readonly sttWindowMs: number;
  /**
   * Question detector: "llm" (LLM-based, reconstructs full questions, more
   * accurate, small cost per check) | "heuristic" (keyword rules, free). Default "llm".
   */
  readonly questionDetector: QuestionDetector;
}

/** Which question-detection strategy to use. */
export type QuestionDetector = 'llm' | 'heuristic';

/** Which transcription backend to use. */
export type TranscriptionEngine = 'cloudflare' | 'fake';

/** Where backend-side audio capture reads from. */
export type AudioSource = 'blackhole' | 'none';

/** Parse an env value as a port, falling back to `fallback` if invalid. */
function parsePort(raw: string | undefined, fallback: number): number {
  if (raw === undefined) {
    return fallback;
  }
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isInteger(parsed) || parsed <= 0 || parsed > 65_535) {
    console.warn(`[config] Invalid PORT "${raw}"; using default ${fallback}.`);
    return fallback;
  }
  return parsed;
}

/** Parse a positive integer env value, falling back to `fallback` if invalid. */
function parsePositiveInt(raw: string | undefined, fallback: number): number {
  if (raw === undefined) {
    return fallback;
  }
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    console.warn(`[config] Invalid integer "${raw}"; using default ${fallback}.`);
    return fallback;
  }
  return parsed;
}

/** Load and freeze the application config from `process.env`. */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): AppConfig {
  const llmProvider = (env.LLM_PROVIDER ?? 'ollama') as ProviderId;
  return Object.freeze({
    port: parsePort(env.PORT, 8787),
    host: env.HOST ?? '127.0.0.1',
    llmProvider,
    ollamaUrl: env.OLLAMA_URL ?? 'http://127.0.0.1:11434',
    ollamaModel: env.OLLAMA_MODEL ?? 'llama3.2',
    cfAccountId: env.CF_ACCOUNT_ID ?? '',
    cfModel: env.CF_MODEL ?? '@cf/meta/llama-4-scout-17b-16e-instruct',
    // SECRET — never hardcode; only ever read from the environment.
    cfApiToken: env.CF_API_TOKEN ?? '',
    cfWhisperModel: env.CF_WHISPER_MODEL ?? '@cf/openai/whisper-large-v3-turbo',
    transcriptionEngine: (env.TRANSCRIPTION_ENGINE ?? 'fake') as TranscriptionEngine,
    audioSource: (env.AUDIO_SOURCE ?? 'none') as AudioSource,
    audioDeviceIndex: env.AUDIO_DEVICE_INDEX ?? '',
    micDeviceIndex: env.MIC_DEVICE_INDEX ?? '',
    // Default: system on, mic off. Mic-on while system audio plays through
    // speakers can echo back into the mic; the user opts in via the UI toggle.
    systemEnabledDefault: env.SYSTEM_ENABLED_DEFAULT !== 'false',
    micEnabledDefault: env.MIC_ENABLED_DEFAULT === 'true',
    sttDebug: env.STT_DEBUG === 'true',
    sttWindowMs: parsePositiveInt(env.STT_WINDOW_MS, 2_000),
    questionDetector: (env.QUESTION_DETECTOR ?? 'llm') as QuestionDetector,
  });
}
