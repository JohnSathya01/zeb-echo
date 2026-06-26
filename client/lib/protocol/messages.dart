// Client <-> Backend wire protocol (CLAUDE.md §3.2).
//
// IMPORTANT: This file is a hand-mirrored Dart port of the backend protocol.
// It MUST stay in sync with `backend/src/protocol/messages.ts` (the single
// source of truth). Any change to message `type` strings, fields, or the
// PROTOCOL_VERSION on either side must be mirrored here, and vice versa.
//
// Rules (CLAUDE.md §3.2):
//  - Every message carries a `type` and protocol `version`.
//  - Messages are discriminated unions keyed on `type`.
//  - Unknown inbound types are ignored forward-compatibly (see
//    [ServerMessage.fromJson] returning an [UnknownServerMessage]).

import 'dart:typed_data';

/// Protocol version. Bump in lockstep with the backend.
///
/// MUST be a number (not a string) to match `PROTOCOL_VERSION = 1` in
/// `backend/src/protocol/messages.ts`; the backend drops messages whose
/// `version` is not strictly equal to the numeric `1`.
const int protocolVersion = 1;

// ---------------------------------------------------------------------------
// Shared DTOs
// ---------------------------------------------------------------------------

/// A transcript segment with timestamps (CLAUDE.md §3.2 / §4.2).
///
/// [startMs] / [endMs] are milliseconds relative to session start.
/// [isFinal] distinguishes `transcript.partial` from `transcript.final`.
class TranscriptSegment {
  const TranscriptSegment({
    required this.id,
    required this.text,
    required this.startMs,
    required this.endMs,
    required this.isFinal,
    this.speaker,
  });

  final String id;
  final String text;
  final int startMs;
  final int endMs;
  final bool isFinal;

  /// Optional speaker label (backend may omit in Phase 1).
  final String? speaker;

  factory TranscriptSegment.fromJson(Map<String, dynamic> json) {
    return TranscriptSegment(
      id: json['id'] as String,
      text: json['text'] as String,
      startMs: (json['startMs'] as num).toInt(),
      endMs: (json['endMs'] as num).toInt(),
      isFinal: json['isFinal'] as bool? ?? false,
      speaker: json['speaker'] as String?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'text': text,
        'startMs': startMs,
        'endMs': endMs,
        'isFinal': isFinal,
        if (speaker != null) 'speaker': speaker,
      };
}

/// A detected question (CLAUDE.md §3.2: `question.detected`).
class DetectedQuestion {
  const DetectedQuestion({
    required this.id,
    required this.text,
    required this.sourceSegmentId,
  });

  final String id;
  final String text;

  /// Reference to the transcript segment the question was detected from.
  final String sourceSegmentId;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'text': text,
        'sourceSegmentId': sourceSegmentId,
      };
}

/// PCM audio chunk format, pinned once (CLAUDE.md §3.2 / Decision Log §9).
///
/// Phase-1 default: 16 kHz, mono, signed 16-bit little-endian — the format
/// Vosk expects. Confirm against the backend before changing.
class AudioFormat {
  const AudioFormat({
    this.sampleRate = 16000,
    this.channels = 1,
    this.encoding = 'pcm_s16le',
  });

  final int sampleRate;
  final int channels;
  final String encoding;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'sampleRate': sampleRate,
        'channels': channels,
        'encoding': encoding,
      };
}

/// The two independently-toggleable capture sources (CLAUDE.md §4.1).
/// Wire values are `mic` / `system` (match backend `AudioSourceId`).
enum AudioSourceId { mic, system }

String _audioSourceIdToWire(AudioSourceId id) =>
    id == AudioSourceId.mic ? 'mic' : 'system';

AudioSourceId? _audioSourceIdFromWire(String? value) {
  switch (value) {
    case 'mic':
      return AudioSourceId.mic;
    case 'system':
      return AudioSourceId.system;
    default:
      return null;
  }
}

/// Which subsystem a [StatusMessage] refers to (backend `domain`).
enum StatusDomain { pipeline, provider, audio }

StatusDomain _statusDomainFromString(String? value) {
  switch (value) {
    case 'provider':
      return StatusDomain.provider;
    case 'audio':
      return StatusDomain.audio;
    case 'pipeline':
    default:
      return StatusDomain.pipeline;
  }
}

/// Coarse health state for a [StatusMessage] (backend `state`).
enum StatusState { ok, starting, degraded, unavailable }

StatusState _statusStateFromString(String? value) {
  switch (value) {
    case 'starting':
      return StatusState.starting;
    case 'degraded':
      return StatusState.degraded;
    case 'unavailable':
      return StatusState.unavailable;
    case 'ok':
    default:
      return StatusState.ok;
  }
}

// ---------------------------------------------------------------------------
// Client -> Backend messages
// ---------------------------------------------------------------------------

/// Base type for all client-originated messages.
///
/// Each carries the protocol [version] and a discriminating [type] string
/// matching CLAUDE.md §3.2 (e.g. `session.start`, `audio.chunk`).
sealed class ClientMessage {
  const ClientMessage();

  String get type;

  Map<String, dynamic> toJson();
}

/// `session.start` — begin an assistance session.
class SessionStartMessage extends ClientMessage {
  const SessionStartMessage({this.audioFormat = const AudioFormat()});

  final AudioFormat audioFormat;

  @override
  String get type => 'session.start';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type,
        'version': protocolVersion,
        'audioFormat': audioFormat.toJson(),
      };
}

/// `session.pause` — pause processing without ending the session.
class SessionPauseMessage extends ClientMessage {
  const SessionPauseMessage();

  @override
  String get type => 'session.pause';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type,
        'version': protocolVersion,
      };
}

/// `session.stop` — end the session.
class SessionStopMessage extends ClientMessage {
  const SessionStopMessage();

  @override
  String get type => 'session.stop';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type,
        'version': protocolVersion,
      };
}

/// `source.toggle` — enable/disable one capture source at runtime.
///
/// When disabled, the backend stops that source's capture so its audio is never
/// transcribed. Independent of session start/stop.
class SourceToggleMessage extends ClientMessage {
  const SourceToggleMessage({required this.source, required this.enabled});

  final AudioSourceId source;
  final bool enabled;

  @override
  String get type => 'source.toggle';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type,
        'version': protocolVersion,
        'source': _audioSourceIdToWire(source),
        'enabled': enabled,
      };
}

/// `audio.chunk` — a binary PCM frame.
///
/// On the wire this is sent as a binary frame (see [WebSocketBackendClient]),
/// not JSON, to avoid base64 overhead. [toJson] is provided only for logging /
/// the fake transport and excludes the raw bytes.
class AudioChunkMessage extends ClientMessage {
  const AudioChunkMessage({required this.pcm, required this.sequence});

  /// Signed 16-bit little-endian PCM samples (see [AudioFormat]).
  final Uint8List pcm;

  /// Monotonic frame sequence number for ordering / loss detection.
  final int sequence;

  @override
  String get type => 'audio.chunk';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type,
        'version': protocolVersion,
        'sequence': sequence,
        'byteLength': pcm.lengthInBytes,
      };
}

// ---------------------------------------------------------------------------
// Backend -> Client messages
// ---------------------------------------------------------------------------

/// Base type for all server-originated messages.
sealed class ServerMessage {
  const ServerMessage();

  String get type;

  /// Decode an inbound JSON message into a typed [ServerMessage].
  ///
  /// Unknown `type` values are returned as [UnknownServerMessage] so callers
  /// can ignore them forward-compatibly (CLAUDE.md §3.2).
  factory ServerMessage.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    switch (type) {
      case 'transcript.partial':
        return TranscriptPartialMessage(
          segment: TranscriptSegment.fromJson(
            json['segment'] as Map<String, dynamic>,
          ),
        );
      case 'transcript.final':
        return TranscriptFinalMessage(
          segment: TranscriptSegment.fromJson(
            json['segment'] as Map<String, dynamic>,
          ),
        );
      case 'question.detected':
        // Backend sends flat fields (questionId/text/sourceSegmentId), NOT a
        // nested `question` object — see backend QuestionDetectedMessage.
        return QuestionDetectedMessage(
          question: DetectedQuestion(
            id: json['questionId'] as String,
            text: json['text'] as String,
            sourceSegmentId: json['sourceSegmentId'] as String,
          ),
        );
      case 'response.token':
        return ResponseTokenMessage(
          questionId: json['questionId'] as String,
          token: json['token'] as String,
        );
      case 'response.done':
        return ResponseDoneMessage(
          questionId: json['questionId'] as String,
          // Backend field is `firstTokenLatencyMs` (question-detected -> first
          // response token); may be absent if not measured.
          latencyMs: (json['firstTokenLatencyMs'] as num?)?.toInt(),
        );
      case 'status':
        return StatusMessage(
          domain: _statusDomainFromString(json['domain'] as String?),
          state: _statusStateFromString(json['state'] as String?),
          source: _audioSourceIdFromWire(json['source'] as String?),
          detail: json['detail'] as String?,
        );
      case 'error':
        return ErrorMessage(
          code: json['code'] as String? ?? 'unknown',
          message: json['message'] as String? ?? '',
        );
      default:
        return UnknownServerMessage(rawType: type, raw: json);
    }
  }
}

/// `transcript.partial` — interim transcript segment (may be revised).
class TranscriptPartialMessage extends ServerMessage {
  const TranscriptPartialMessage({required this.segment});

  final TranscriptSegment segment;

  @override
  String get type => 'transcript.partial';
}

/// `transcript.final` — finalized transcript segment.
class TranscriptFinalMessage extends ServerMessage {
  const TranscriptFinalMessage({required this.segment});

  final TranscriptSegment segment;

  @override
  String get type => 'transcript.final';
}

/// `question.detected` — a question identified from the transcript.
class QuestionDetectedMessage extends ServerMessage {
  const QuestionDetectedMessage({required this.question});

  final DetectedQuestion question;

  @override
  String get type => 'question.detected';
}

/// `response.token` — one streamed LLM token for [questionId].
class ResponseTokenMessage extends ServerMessage {
  const ResponseTokenMessage({required this.questionId, required this.token});

  final String questionId;
  final String token;

  @override
  String get type => 'response.token';
}

/// `response.done` — the response for [questionId] is complete.
///
/// [latencyMs] is the question-detected -> response-complete time the backend
/// measured (CLAUDE.md §4.3 latency metric), when available.
class ResponseDoneMessage extends ServerMessage {
  const ResponseDoneMessage({required this.questionId, this.latencyMs});

  final String questionId;
  final int? latencyMs;

  @override
  String get type => 'response.done';
}

/// `status` — pipeline / provider / audio health.
class StatusMessage extends ServerMessage {
  const StatusMessage({
    required this.domain,
    required this.state,
    this.source,
    this.detail,
  });

  /// Which subsystem this status is about.
  final StatusDomain domain;

  /// Coarse health state.
  final StatusState state;

  /// For [StatusDomain.audio], which capture source this refers to. Null
  /// otherwise.
  final AudioSourceId? source;

  /// Optional human-readable detail (e.g. "Ollama model loading").
  final String? detail;

  @override
  String get type => 'status';
}

/// `error` — structured error the client can render.
class ErrorMessage extends ServerMessage {
  const ErrorMessage({required this.code, required this.message});

  final String code;
  final String message;

  @override
  String get type => 'error';
}

/// An inbound message whose `type` is not recognized — ignored by the UI but
/// retained for logging (CLAUDE.md §3.2 forward-compatibility rule).
class UnknownServerMessage extends ServerMessage {
  const UnknownServerMessage({required this.rawType, required this.raw});

  final String? rawType;
  final Map<String, dynamic> raw;

  @override
  String get type => rawType ?? 'unknown';
}
