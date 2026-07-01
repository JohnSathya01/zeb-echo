import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../protocol/messages.dart';
import '../services/audio_capture_service.dart';
import '../services/backend_client.dart';
import '../services/backend_launcher.dart';
import 'session_controller.dart';

/// Riverpod is the chosen state-management library (CLAUDE.md §6 recommendation;
/// see client/README.md). All session wiring flows through these providers.

/// Toggle between fake and real services.
///
///  - `true`  → standalone demo mode: in-app fake backend, no Node process
///              (CLAUDE.md §8). Default for UI development.
///  - `false` → connect to the real Node backend over WebSocket. The backend
///              captures audio itself (ffmpeg) and runs Whisper + the LLM, so
///              the client only drives start/stop and renders results.
///
/// Overridden at the `ProviderScope` in `main` based on a build flag.
final useFakeServicesProvider = Provider<bool>((ref) => true);

/// Default WebSocket endpoint of the local backend.
///
/// In a packaged desktop app this is overridden at the `ProviderScope` in
/// `main` with the dynamic `ws://127.0.0.1:<port>` the [BackendLauncher] chose
/// when it spawned the bundled backend.
final backendEndpointProvider =
    Provider<Uri>((ref) => Uri.parse('ws://127.0.0.1:8787'));

/// The [BackendLauncher] that spawned the bundled backend, if any.
///
/// Null when no backend was spawned (web, or when the client connects to a
/// separately-run backend). Overridden at the `ProviderScope` in `main` with
/// the already-started instance so it can be stopped on app exit.
final backendLauncherProvider = Provider<BackendLauncher?>((ref) => null);

/// The active [BackendClient]. Disposed with the provider container.
final backendClientProvider = Provider<BackendClient>((ref) {
  final useFake = ref.watch(useFakeServicesProvider);
  final client = useFake
      ? FakeBackendClient()
      : WebSocketBackendClient(endpoint: ref.watch(backendEndpointProvider));
  ref.onDispose(client.dispose);
  return client;
});

/// The active [AudioCaptureService].
///
/// Always the fake for now: native capture is a documented TODO (platform
/// channels) and [NativeAudioCaptureService] throws until implemented
/// (CLAUDE.md §10). We still read [useFakeServicesProvider] so this provider
/// rebuilds in lockstep with the backend client when the toggle changes.
final audioCaptureServiceProvider = Provider<AudioCaptureService>((ref) {
  ref.watch(useFakeServicesProvider);
  final service = FakeAudioCaptureService();
  ref.onDispose(service.dispose);
  return service;
});

/// Session lifecycle + start/pause/stop (idle/running/paused).
final sessionControllerProvider =
    StateNotifierProvider<SessionController, SessionState>((ref) {
  // In fake mode the client drives its own demo audio; against the real
  // backend, the backend captures audio itself, so the client must NOT upload.
  final useFake = ref.watch(useFakeServicesProvider);
  return SessionController(
    backend: ref.watch(backendClientProvider),
    audio: ref.watch(audioCaptureServiceProvider),
    clientSendsAudio: useFake,
  );
});

// ---------------------------------------------------------------------------
// Backend connection status
// ---------------------------------------------------------------------------

final connectionStateProvider = StreamProvider<BackendConnectionState>((ref) {
  return ref.watch(backendClientProvider).connectionState;
});

// ---------------------------------------------------------------------------
// Live transcript (accumulated; partials replace prior partial for the same id)
// ---------------------------------------------------------------------------

final transcriptProvider =
    StateNotifierProvider<TranscriptNotifier, List<TranscriptSegment>>((ref) {
  final notifier = TranscriptNotifier();
  final sub = ref.watch(backendClientProvider).transcript.listen(notifier.add);
  ref.onDispose(sub.cancel);
  // Reset accumulated transcript on a fresh start (idle -> running), but not
  // on resume (paused -> running).
  ref.listen<SessionState>(sessionControllerProvider, (prev, next) {
    final wasIdle = (prev?.status ?? SessionStatus.idle) == SessionStatus.idle;
    if (wasIdle && next.status == SessionStatus.running) {
      notifier.clear();
    }
  });
  return notifier;
});

/// Accumulates transcript segments, coalescing partial/final by segment id.
class TranscriptNotifier extends StateNotifier<List<TranscriptSegment>> {
  TranscriptNotifier() : super(const <TranscriptSegment>[]);

  void add(TranscriptSegment segment) {
    final existing = state.indexWhere((s) => s.id == segment.id);
    if (existing >= 0) {
      final next = List<TranscriptSegment>.of(state);
      next[existing] = segment;
      state = next;
    } else {
      state = <TranscriptSegment>[...state, segment];
    }
  }

  void clear() => state = const <TranscriptSegment>[];
}

// ---------------------------------------------------------------------------
// Detected questions (newest last)
// ---------------------------------------------------------------------------

final detectedQuestionsProvider =
    StateNotifierProvider<DetectedQuestionsNotifier, List<DetectedQuestion>>(
        (ref) {
  final notifier = DetectedQuestionsNotifier();
  final sub = ref.watch(backendClientProvider).questions.listen(notifier.add);
  ref.onDispose(sub.cancel);
  ref.listen<SessionState>(sessionControllerProvider, (prev, next) {
    if (next.status == SessionStatus.idle &&
        prev?.status != SessionStatus.idle) {
      notifier.clear();
    }
  });
  return notifier;
});

class DetectedQuestionsNotifier extends StateNotifier<List<DetectedQuestion>> {
  DetectedQuestionsNotifier() : super(const <DetectedQuestion>[]);

  void add(DetectedQuestion question) {
    if (state.any((q) => q.id == question.id)) return;
    state = <DetectedQuestion>[...state, question];
  }

  void clear() => state = const <DetectedQuestion>[];
}

// ---------------------------------------------------------------------------
// Latest AI response (accumulates streamed tokens for the current question)
// ---------------------------------------------------------------------------

final aiResponseProvider =
    StateNotifierProvider<AiResponseNotifier, AiResponseState>((ref) {
  final notifier = AiResponseNotifier();
  final backend = ref.watch(backendClientProvider);
  final tokenSub = backend.responseTokens.listen(notifier.appendToken);
  final doneSub = backend.responseDone.listen(notifier.complete);
  ref.onDispose(tokenSub.cancel);
  ref.onDispose(doneSub.cancel);
  return notifier;
});

/// The most recent (streaming) AI response.
class AiResponseState {
  const AiResponseState({
    this.questionId,
    this.text = '',
    this.isStreaming = false,
    this.latencyMs,
  });

  final String? questionId;
  final String text;
  final bool isStreaming;
  final int? latencyMs;

  static const AiResponseState empty = AiResponseState();
}

class AiResponseNotifier extends StateNotifier<AiResponseState> {
  AiResponseNotifier() : super(AiResponseState.empty);

  void appendToken(ResponseTokenMessage message) {
    // A new question starts a fresh response buffer.
    if (state.questionId != message.questionId) {
      state = AiResponseState(
        questionId: message.questionId,
        text: message.token,
        isStreaming: true,
      );
    } else {
      state = AiResponseState(
        questionId: state.questionId,
        text: state.text + message.token,
        isStreaming: true,
      );
    }
  }

  void complete(ResponseDoneMessage message) {
    if (state.questionId != message.questionId) return;
    state = AiResponseState(
      questionId: state.questionId,
      text: state.text,
      isStreaming: false,
      latencyMs: message.latencyMs,
    );
  }
}

// ---------------------------------------------------------------------------
// Audio status (mic + system) for the Audio Status Indicator
// ---------------------------------------------------------------------------

final audioStatusProvider = StreamProvider<AudioStatus>((ref) {
  return ref.watch(audioCaptureServiceProvider).status;
});

// ---------------------------------------------------------------------------
// Backend status / error feed (for surfacing health, CLAUDE.md §4.3)
// ---------------------------------------------------------------------------

final backendStatusProvider = StreamProvider<StatusMessage>((ref) {
  return ref.watch(backendClientProvider).statusUpdates;
});

final backendErrorProvider = StreamProvider<ErrorMessage>((ref) {
  return ref.watch(backendClientProvider).errors;
});

// ---------------------------------------------------------------------------
// Per-source audio toggles (mic / system) — CLAUDE.md §4.1 / §4.2
// ---------------------------------------------------------------------------

/// Live capture state of a single source, as reflected in its status chip.
enum SourceCaptureState { off, capturing, error }

/// Enabled flags + capture state for both toggleable sources.
class AudioSourcesState {
  const AudioSourcesState({
    this.micEnabled = false,
    this.systemEnabled = true,
    this.micStatus = SourceCaptureState.off,
    this.systemStatus = SourceCaptureState.off,
  });

  /// Whether the user wants the source on (intent).
  final bool micEnabled;
  final bool systemEnabled;

  /// Actual capture state reported by the backend (reality).
  final SourceCaptureState micStatus;
  final SourceCaptureState systemStatus;

  AudioSourcesState copyWith({
    bool? micEnabled,
    bool? systemEnabled,
    SourceCaptureState? micStatus,
    SourceCaptureState? systemStatus,
  }) {
    return AudioSourcesState(
      micEnabled: micEnabled ?? this.micEnabled,
      systemEnabled: systemEnabled ?? this.systemEnabled,
      micStatus: micStatus ?? this.micStatus,
      systemStatus: systemStatus ?? this.systemStatus,
    );
  }
}

/// Owns the mic/system enable intent, sends `source.toggle` to the backend, and
/// folds backend audio-status updates into per-source capture state.
///
/// Defaults mirror the backend (`SYSTEM_ENABLED_DEFAULT`/`MIC_ENABLED_DEFAULT`):
/// system on, mic off.
class AudioSourcesNotifier extends StateNotifier<AudioSourcesState> {
  AudioSourcesNotifier(this._backend) : super(const AudioSourcesState());

  final BackendClient _backend;

  void toggleMic() => _setEnabled(AudioSourceId.mic, !state.micEnabled);
  void toggleSystem() =>
      _setEnabled(AudioSourceId.system, !state.systemEnabled);

  void _setEnabled(AudioSourceId source, bool enabled) {
    _backend.send(SourceToggleMessage(source: source, enabled: enabled));
    switch (source) {
      case AudioSourceId.mic:
        state = state.copyWith(
          micEnabled: enabled,
          micStatus: enabled ? state.micStatus : SourceCaptureState.off,
        );
      case AudioSourceId.system:
        state = state.copyWith(
          systemEnabled: enabled,
          systemStatus: enabled ? state.systemStatus : SourceCaptureState.off,
        );
    }
  }

  /// Fold a backend audio `status` (with a `source`) into capture state.
  void applyStatus(StatusMessage message) {
    if (message.domain != StatusDomain.audio || message.source == null) return;
    final ok = message.state == StatusState.ok;
    switch (message.source!) {
      case AudioSourceId.mic:
        state = state.copyWith(micStatus: _resolve(ok, state.micEnabled));
      case AudioSourceId.system:
        state = state.copyWith(systemStatus: _resolve(ok, state.systemEnabled));
    }
  }

  SourceCaptureState _resolve(bool ok, bool enabled) {
    if (!enabled) return SourceCaptureState.off;
    return ok ? SourceCaptureState.capturing : SourceCaptureState.error;
  }
}

final audioSourcesProvider =
    StateNotifierProvider<AudioSourcesNotifier, AudioSourcesState>((ref) {
  final notifier = AudioSourcesNotifier(ref.watch(backendClientProvider));
  // Fold backend audio-status updates into per-source capture state.
  final sub =
      ref.watch(backendClientProvider).statusUpdates.listen(notifier.applyStatus);
  ref.onDispose(sub.cancel);
  return notifier;
});

// ---------------------------------------------------------------------------
// Phase 3 — Knowledge Base + response mode (manual/automatic)
// ---------------------------------------------------------------------------

/// Which tab is showing in the main workspace.
enum AppTab { dashboard, knowledgeBase }

/// Currently-selected top-level tab.
final selectedTabProvider =
    StateProvider<AppTab>((ref) => AppTab.dashboard);

/// Owns the Knowledge Base text and pushes it to the backend (`kb.set`) so it
/// grounds every generated answer (Phase 3).
class KnowledgeBaseNotifier extends StateNotifier<String> {
  KnowledgeBaseNotifier(this._backend) : super('');

  final BackendClient _backend;

  /// Update the local KB text and send it to the backend.
  void setContent(String content) {
    state = content;
    _backend.send(KbSetMessage(content: content));
  }
}

final knowledgeBaseProvider =
    StateNotifierProvider<KnowledgeBaseNotifier, String>((ref) {
  return KnowledgeBaseNotifier(ref.watch(backendClientProvider));
});

/// Owns the response mode (auto = answer on detection; manual = wait for ▶).
/// Sends `response.mode` to the backend on change (Phase 3).
class ResponseModeNotifier extends StateNotifier<ResponseMode> {
  ResponseModeNotifier(this._backend) : super(ResponseMode.auto);

  final BackendClient _backend;

  void setMode(ResponseMode mode) {
    state = mode;
    _backend.send(ResponseModeMessage(mode: mode));
  }

  void toggle() =>
      setMode(state == ResponseMode.auto ? ResponseMode.manual : ResponseMode.auto);
}

final responseModeProvider =
    StateNotifierProvider<ResponseModeNotifier, ResponseMode>((ref) {
  return ResponseModeNotifier(ref.watch(backendClientProvider));
});

/// Request an answer for a specific detected question (manual mode ▶ button).
void generateResponse(WidgetRef ref, String questionId) {
  ref
      .read(backendClientProvider)
      .send(ResponseGenerateMessage(questionId: questionId));
}
