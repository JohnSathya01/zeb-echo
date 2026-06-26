import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../protocol/messages.dart';
import '../services/audio_capture_service.dart';
import '../services/backend_client.dart';

/// Lifecycle of an assistance session (CLAUDE.md §3 / §4.2 Session Controls).
enum SessionStatus { idle, running, paused }

/// Immutable session state exposed to the UI.
class SessionState {
  const SessionState({
    this.status = SessionStatus.idle,
    this.errorMessage,
  });

  final SessionStatus status;

  /// Last non-fatal error to surface (does not stop the session, §4.3).
  final String? errorMessage;

  bool get isIdle => status == SessionStatus.idle;
  bool get isRunning => status == SessionStatus.running;
  bool get isPaused => status == SessionStatus.paused;

  SessionState copyWith({SessionStatus? status, String? errorMessage}) {
    return SessionState(
      status: status ?? this.status,
      errorMessage: errorMessage,
    );
  }
}

/// Owns session lifecycle + start/pause/stop, bridging the audio capture
/// service to the backend client (CLAUDE.md §3). Forwards captured PCM frames
/// upstream as `audio.chunk` messages and translates control intents into
/// `session.*` messages.
class SessionController extends StateNotifier<SessionState> {
  SessionController({
    required BackendClient backend,
    required AudioCaptureService audio,
    bool clientSendsAudio = false,
  })  : _backend = backend,
        _audio = audio,
        _clientSendsAudio = clientSendsAudio,
        super(const SessionState()) {
    // Ensure the transport is connecting from the start (auto-reconnects).
    unawaited(_backend.connect());
    // Only forward client-captured audio when the backend is NOT capturing its
    // own (e.g. macOS ffmpeg/BlackHole capture). With backend-side capture the
    // client just drives start/stop and displays results.
    if (_clientSendsAudio) {
      _audioSub = _audio.chunks.listen(_onAudioChunk);
    }
  }

  final BackendClient _backend;
  final AudioCaptureService _audio;
  final bool _clientSendsAudio;
  StreamSubscription<PcmChunk>? _audioSub;

  void _onAudioChunk(PcmChunk chunk) {
    if (state.status != SessionStatus.running) return;
    _backend.send(
      AudioChunkMessage(pcm: chunk.bytes, sequence: chunk.sequence),
    );
  }

  Future<void> start() async {
    if (state.status == SessionStatus.running) return;
    _backend.send(const SessionStartMessage());
    await _audio.start();
    state = state.copyWith(status: SessionStatus.running);
  }

  Future<void> pause() async {
    if (state.status != SessionStatus.running) return;
    _backend.send(const SessionPauseMessage());
    await _audio.pause();
    state = state.copyWith(status: SessionStatus.paused);
  }

  Future<void> resume() async {
    if (state.status != SessionStatus.paused) return;
    _backend.send(const SessionStartMessage());
    await _audio.start();
    state = state.copyWith(status: SessionStatus.running);
  }

  Future<void> stop() async {
    if (state.status == SessionStatus.idle) return;
    _backend.send(const SessionStopMessage());
    await _audio.stop();
    state = state.copyWith(status: SessionStatus.idle);
  }

  @override
  void dispose() {
    _audioSub?.cancel();
    super.dispose();
  }
}
