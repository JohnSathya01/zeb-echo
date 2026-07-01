/**
 * zeb Echo — Client ↔ Backend wire protocol (CLAUDE.md §3.2).
 *
 * This module is the SINGLE SOURCE OF TRUTH for the localhost WebSocket protocol.
 * The Flutter client's Dart DTOs must mirror these definitions exactly.
 *
 * Design rules (per §3.2):
 *  - Every message carries a `type` (discriminator) and a protocol `version`.
 *  - Messages are modelled as discriminated unions on `type`.
 *  - Unknown message types are ignored forward-compatibly by both sides.
 *  - Phase 1 assumes a single local client.
 *
 * Transport note: control/data messages travel as JSON text frames. The one
 * exception is `audio.chunk`, whose PCM payload travels as a *binary* WebSocket
 * frame (see AUDIO_FORMAT below); only its envelope is described here so both
 * sides agree on the pinned audio format.
 */

/**
 * Protocol version. Bump on any breaking change to message shapes.
 * The client and backend compare this to detect version mismatch.
 */
export const PROTOCOL_VERSION = 1 as const;
export type ProtocolVersion = typeof PROTOCOL_VERSION;

/**
 * Pinned PCM audio format for `audio.chunk` binary frames (CLAUDE.md §3.2 / §10).
 * Defined once here so client capture and backend STT agree.
 */
export const AUDIO_FORMAT = {
  /** Samples per second. 16 kHz is the standard Vosk input rate. */
  sampleRate: 16_000,
  /** Mono — mic + system audio are mixed to one channel client-side. */
  channels: 1,
  /** 16-bit signed little-endian PCM. */
  encoding: 'pcm_s16le',
  bitDepth: 16,
} as const;

// ---------------------------------------------------------------------------
// Shared payload types
// ---------------------------------------------------------------------------

/**
 * A single transcript segment with timestamps (relative to session start, ms).
 * Used by transcript.partial / transcript.final and as LLM context.
 */
export interface TranscriptSegment {
  /** Stable id for the segment (lets the client update partial → final). */
  readonly id: string;
  /** Recognised text for this segment. */
  readonly text: string;
  /** Start time in milliseconds from session start. */
  readonly startMs: number;
  /** End time in milliseconds from session start. */
  readonly endMs: number;
  /** `false` for in-progress (partial) hypotheses, `true` once finalised. */
  readonly isFinal: boolean;
  /**
   * Which capture source produced this segment ("You" = mic, "Them" = system
   * audio). Optional — omitted when capture is single-source/unlabelled.
   */
  readonly speaker?: string;
}

/** The two independently-toggleable capture sources (CLAUDE.md §4.1). */
export type AudioSourceId = 'mic' | 'system';

/** Health domains reported via `status`. */
export type StatusDomain = 'pipeline' | 'provider' | 'audio';

/** Coarse health state for a `status` message. */
export type StatusState = 'ok' | 'starting' | 'degraded' | 'unavailable';

// ---------------------------------------------------------------------------
// Client → Backend messages
// ---------------------------------------------------------------------------

/** Begin (or resume into) an active assistance session. */
export interface SessionStartMessage {
  readonly type: 'session.start';
  readonly version: ProtocolVersion;
}

/** Temporarily pause processing without tearing down the session. */
export interface SessionPauseMessage {
  readonly type: 'session.pause';
  readonly version: ProtocolVersion;
}

/** Stop the session and release pipeline resources. */
export interface SessionStopMessage {
  readonly type: 'session.stop';
  readonly version: ProtocolVersion;
}

/**
 * Envelope describing a PCM audio chunk. In transit the PCM bytes are sent as a
 * *binary* WebSocket frame (AUDIO_FORMAT); this type documents the logical
 * message and is used when an implementation chooses to wrap chunks as JSON
 * (e.g. base64) for testing. `seq` lets the backend detect drops/reordering.
 */
export interface AudioChunkMessage {
  readonly type: 'audio.chunk';
  readonly version: ProtocolVersion;
  /** Monotonically increasing chunk sequence number. */
  readonly seq: number;
}

/**
 * Enable or disable one capture source at runtime. When a source is disabled
 * its audio is never fed to transcription (the backend stops that source's
 * ffmpeg). Independent of session lifecycle.
 */
export interface SourceToggleMessage {
  readonly type: 'source.toggle';
  readonly version: ProtocolVersion;
  readonly source: AudioSourceId;
  readonly enabled: boolean;
}

/**
 * Set/replace the session Knowledge Base — free-text domain knowledge the user
 * provides (Phase 3). Injected into the LLM prompt as authoritative context so
 * answers can cite facts not present in the meeting transcript.
 */
export interface KbSetMessage {
  readonly type: 'kb.set';
  readonly version: ProtocolVersion;
  /** Full KB text (replaces any previous KB). Empty clears it. */
  readonly content: string;
}

/** How responses are generated (Phase 3). */
export type ResponseMode = 'auto' | 'manual';

/**
 * Switch response generation between automatic (answer as soon as a question is
 * detected) and manual (wait for an explicit `response.generate`).
 */
export interface ResponseModeMessage {
  readonly type: 'response.mode';
  readonly version: ProtocolVersion;
  readonly mode: ResponseMode;
}

/**
 * (Manual mode) Generate the answer for a previously-detected question, on user
 * demand (the ▶ play button).
 */
export interface ResponseGenerateMessage {
  readonly type: 'response.generate';
  readonly version: ProtocolVersion;
  readonly questionId: string;
}

/** Union of all messages the client may send to the backend. */
export type ClientMessage =
  | SessionStartMessage
  | SessionPauseMessage
  | SessionStopMessage
  | SourceToggleMessage
  | AudioChunkMessage
  | KbSetMessage
  | ResponseModeMessage
  | ResponseGenerateMessage;

export type ClientMessageType = ClientMessage['type'];

// ---------------------------------------------------------------------------
// Backend → Client messages
// ---------------------------------------------------------------------------

/** An in-progress transcript hypothesis (may be revised). */
export interface TranscriptPartialMessage {
  readonly type: 'transcript.partial';
  readonly version: ProtocolVersion;
  readonly segment: TranscriptSegment;
}

/** A finalised transcript segment. */
export interface TranscriptFinalMessage {
  readonly type: 'transcript.final';
  readonly version: ProtocolVersion;
  readonly segment: TranscriptSegment;
}

/** A question detected in the ongoing transcript. */
export interface QuestionDetectedMessage {
  readonly type: 'question.detected';
  readonly version: ProtocolVersion;
  /** Stable id for this detected question (correlates with response tokens). */
  readonly questionId: string;
  /** The question text. */
  readonly text: string;
  /** Id of the transcript segment the question was detected in. */
  readonly sourceSegmentId: string;
}

/** A single streamed LLM response token (for the given question). */
export interface ResponseTokenMessage {
  readonly type: 'response.token';
  readonly version: ProtocolVersion;
  readonly questionId: string;
  readonly token: string;
}

/** Signals that the LLM response for a question is complete. */
export interface ResponseDoneMessage {
  readonly type: 'response.done';
  readonly version: ProtocolVersion;
  readonly questionId: string;
  /** Latency (ms) from question detected → first response token, if measured. */
  readonly firstTokenLatencyMs?: number;
}

/** Pipeline / provider / audio health update. */
export interface StatusMessage {
  readonly type: 'status';
  readonly version: ProtocolVersion;
  readonly domain: StatusDomain;
  readonly state: StatusState;
  /**
   * For `domain: 'audio'`, which capture source this status refers to
   * (`mic` | `system`). Omitted for non-audio domains.
   */
  readonly source?: AudioSourceId;
  /** Human-readable detail (e.g. "Ollama model loading"). */
  readonly detail?: string;
}

/** A structured error the client can render without crashing. */
export interface ErrorMessage {
  readonly type: 'error';
  readonly version: ProtocolVersion;
  /** Machine-readable error code (e.g. "provider_unavailable"). */
  readonly code: string;
  readonly message: string;
}

/** Union of all messages the backend may send to the client. */
export type ServerMessage =
  | TranscriptPartialMessage
  | TranscriptFinalMessage
  | QuestionDetectedMessage
  | ResponseTokenMessage
  | ResponseDoneMessage
  | StatusMessage
  | ErrorMessage;

export type ServerMessageType = ServerMessage['type'];

// ---------------------------------------------------------------------------
// Decode helpers (forward-compatible)
// ---------------------------------------------------------------------------

/** Known client message types — anything else is ignored per §3.2. */
const CLIENT_MESSAGE_TYPES: ReadonlySet<string> = new Set<ClientMessageType>([
  'session.start',
  'session.pause',
  'session.stop',
  'source.toggle',
  'audio.chunk',
  'kb.set',
  'response.mode',
  'response.generate',
]);

/**
 * Narrow an arbitrary parsed JSON value to a known ClientMessage, or return
 * `null` for unknown/malformed types (which the caller ignores forward-
 * compatibly). This is intentionally lenient: it validates the discriminator
 * and version, not every field.
 */
export function parseClientMessage(value: unknown): ClientMessage | null {
  if (typeof value !== 'object' || value === null) {
    return null;
  }
  const record = value as Record<string, unknown>;
  const type = record['type'];
  if (typeof type !== 'string' || !CLIENT_MESSAGE_TYPES.has(type)) {
    return null;
  }
  if (record['version'] !== PROTOCOL_VERSION) {
    return null;
  }
  // The discriminator + version are validated; trust the rest of the shape for
  // Phase 1's single trusted local client.
  return value as ClientMessage;
}

/** Serialise a ServerMessage to a JSON text frame. */
export function encodeServerMessage(message: ServerMessage): string {
  return JSON.stringify(message);
}
