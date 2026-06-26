import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../protocol/messages.dart';

/// Connection state of a [BackendClient] (surfaced in the UI per CLAUDE.md §4.3).
enum BackendConnectionState { disconnected, connecting, connected, error }

/// Abstraction over the localhost transport to the Node backend (CLAUDE.md
/// §3 client-side contracts).
///
/// The UI binds only to the streams exposed here; it must NOT know about the
/// wire format, Vosk, or the LLM. Implemented by [WebSocketBackendClient]
/// (real) and [FakeBackendClient] (no backend required).
abstract interface class BackendClient {
  /// Current/most-recent connection state changes.
  Stream<BackendConnectionState> get connectionState;

  /// Transcript segments (partial + final) as they arrive.
  Stream<TranscriptSegment> get transcript;

  /// Questions detected by the backend.
  Stream<DetectedQuestion> get questions;

  /// Streamed LLM response tokens (and completion markers).
  Stream<ResponseTokenMessage> get responseTokens;

  /// Signalled when a response stream for a question completes.
  Stream<ResponseDoneMessage> get responseDone;

  /// Pipeline / provider / audio health updates.
  Stream<StatusMessage> get statusUpdates;

  /// Structured errors the client can render.
  Stream<ErrorMessage> get errors;

  /// Open the connection (no-op if already connected).
  Future<void> connect();

  /// Send a control / audio message upstream.
  void send(ClientMessage message);

  /// Tear down the connection and release resources.
  Future<void> dispose();
}

/// Real transport: a [WebSocketChannel] to `ws://127.0.0.1:8787` by default
/// (CLAUDE.md §1 / §3.2). Auto-reconnects with backoff (CLAUDE.md §4.3).
class WebSocketBackendClient implements BackendClient {
  WebSocketBackendClient({Uri? endpoint})
      : endpoint = endpoint ?? Uri.parse('ws://127.0.0.1:8787');

  final Uri endpoint;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSub;
  Timer? _reconnectTimer;
  bool _disposed = false;
  Duration _backoff = const Duration(seconds: 1);
  static const Duration _maxBackoff = Duration(seconds: 15);

  final _connectionCtrl = StreamController<BackendConnectionState>.broadcast();
  final _transcriptCtrl = StreamController<TranscriptSegment>.broadcast();
  final _questionsCtrl = StreamController<DetectedQuestion>.broadcast();
  final _responseTokenCtrl = StreamController<ResponseTokenMessage>.broadcast();
  final _responseDoneCtrl = StreamController<ResponseDoneMessage>.broadcast();
  final _statusCtrl = StreamController<StatusMessage>.broadcast();
  final _errorCtrl = StreamController<ErrorMessage>.broadcast();

  @override
  Stream<BackendConnectionState> get connectionState => _connectionCtrl.stream;

  @override
  Stream<TranscriptSegment> get transcript => _transcriptCtrl.stream;

  @override
  Stream<DetectedQuestion> get questions => _questionsCtrl.stream;

  @override
  Stream<ResponseTokenMessage> get responseTokens => _responseTokenCtrl.stream;

  @override
  Stream<ResponseDoneMessage> get responseDone => _responseDoneCtrl.stream;

  @override
  Stream<StatusMessage> get statusUpdates => _statusCtrl.stream;

  @override
  Stream<ErrorMessage> get errors => _errorCtrl.stream;

  @override
  Future<void> connect() async {
    if (_disposed || _channel != null) return;
    _connectionCtrl.add(BackendConnectionState.connecting);
    try {
      final channel = WebSocketChannel.connect(endpoint);
      _channel = channel;
      // `ready` completes once the socket handshake succeeds.
      await channel.ready;
      _backoff = const Duration(seconds: 1);
      _connectionCtrl.add(BackendConnectionState.connected);
      _channelSub = channel.stream.listen(
        _onData,
        onError: (Object error) => _onDisconnected(error),
        onDone: () => _onDisconnected(null),
        cancelOnError: true,
      );
    } catch (error) {
      _onDisconnected(error);
    }
  }

  void _onData(dynamic data) {
    // Backend -> client frames are JSON text in Phase 1.
    if (data is! String) return;
    try {
      final decoded = jsonDecode(data);
      if (decoded is! Map<String, dynamic>) return;
      final message = ServerMessage.fromJson(decoded);
      switch (message) {
        case TranscriptPartialMessage(:final segment):
          _transcriptCtrl.add(segment);
        case TranscriptFinalMessage(:final segment):
          _transcriptCtrl.add(segment);
        case QuestionDetectedMessage(:final question):
          _questionsCtrl.add(question);
        case ResponseTokenMessage():
          _responseTokenCtrl.add(message);
        case ResponseDoneMessage():
          _responseDoneCtrl.add(message);
        case StatusMessage():
          _statusCtrl.add(message);
        case ErrorMessage():
          _errorCtrl.add(message);
        case UnknownServerMessage():
          // Ignore unknown types forward-compatibly (CLAUDE.md §3.2).
          break;
      }
    } catch (_) {
      // Malformed frame — drop it rather than crash (CLAUDE.md §4.3 resilience).
    }
  }

  void _onDisconnected(Object? error) {
    _channelSub?.cancel();
    _channelSub = null;
    _channel = null;
    if (_disposed) return;
    _connectionCtrl.add(
      error == null
          ? BackendConnectionState.disconnected
          : BackendConnectionState.error,
    );
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    final delay = _backoff;
    _backoff = Duration(
      milliseconds:
          (_backoff.inMilliseconds * 2).clamp(0, _maxBackoff.inMilliseconds),
    );
    _reconnectTimer = Timer(delay, () {
      if (!_disposed) connect();
    });
  }

  @override
  void send(ClientMessage message) {
    final sink = _channel?.sink;
    if (sink == null) return;
    if (message is AudioChunkMessage) {
      // Audio goes up as a binary frame (CLAUDE.md §3.2: binary PCM frame).
      sink.add(message.pcm);
    } else {
      sink.add(jsonEncode(message.toJson()));
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    await _channelSub?.cancel();
    await _channel?.sink.close();
    _channel = null;
    await _connectionCtrl.close();
    await _transcriptCtrl.close();
    await _questionsCtrl.close();
    await _responseTokenCtrl.close();
    await _responseDoneCtrl.close();
    await _statusCtrl.close();
    await _errorCtrl.close();
  }
}

/// In-memory fake backend so the UI runs with NO Node backend (CLAUDE.md §3 /
/// §8: develop the UI against fakes).
///
/// On `session.start` it emits a scripted stream of transcript segments, then a
/// detected question, then streamed response tokens — all on timers — so the
/// dashboard is fully demoable standalone. `session.pause`/`stop` halt emission.
class FakeBackendClient implements BackendClient {
  FakeBackendClient();

  final _connectionCtrl = StreamController<BackendConnectionState>.broadcast();
  final _transcriptCtrl = StreamController<TranscriptSegment>.broadcast();
  final _questionsCtrl = StreamController<DetectedQuestion>.broadcast();
  final _responseTokenCtrl = StreamController<ResponseTokenMessage>.broadcast();
  final _responseDoneCtrl = StreamController<ResponseDoneMessage>.broadcast();
  final _statusCtrl = StreamController<StatusMessage>.broadcast();
  final _errorCtrl = StreamController<ErrorMessage>.broadcast();

  final List<Timer> _timers = <Timer>[];
  bool _running = false;
  int _seq = 0;

  static const List<String> _scriptedLines = <String>[
    'Thanks everyone for joining the sync today.',
    'Let me walk through the latency numbers from last week.',
    'We brought the end-to-end response time down significantly.',
    'How are we planning to handle system audio capture on Windows?',
    'Good question — we are using WASAPI loopback there.',
  ];

  @override
  Stream<BackendConnectionState> get connectionState => _connectionCtrl.stream;

  @override
  Stream<TranscriptSegment> get transcript => _transcriptCtrl.stream;

  @override
  Stream<DetectedQuestion> get questions => _questionsCtrl.stream;

  @override
  Stream<ResponseTokenMessage> get responseTokens => _responseTokenCtrl.stream;

  @override
  Stream<ResponseDoneMessage> get responseDone => _responseDoneCtrl.stream;

  @override
  Stream<StatusMessage> get statusUpdates => _statusCtrl.stream;

  @override
  Stream<ErrorMessage> get errors => _errorCtrl.stream;

  @override
  Future<void> connect() async {
    _connectionCtrl.add(BackendConnectionState.connecting);
    // Simulate a near-instant local handshake.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    _connectionCtrl.add(BackendConnectionState.connected);
    _statusCtrl.add(
      const StatusMessage(
        domain: StatusDomain.pipeline,
        state: StatusState.ok,
        detail: 'Fake backend ready (no Node process required).',
      ),
    );
  }

  @override
  void send(ClientMessage message) {
    switch (message) {
      case SessionStartMessage():
        _startScript();
      case SessionPauseMessage():
        _running = false;
        _statusCtrl.add(
          const StatusMessage(
            domain: StatusDomain.pipeline,
            state: StatusState.degraded,
            detail: 'Session paused.',
          ),
        );
      case SessionStopMessage():
        _running = false;
        _clearTimers();
        _statusCtrl.add(
          const StatusMessage(
            domain: StatusDomain.pipeline,
            state: StatusState.ok,
            detail: 'Session stopped.',
          ),
        );
      case SourceToggleMessage():
        // Echo the toggle back as an audio status so the chip reflects it,
        // mirroring the real backend's per-source status messages.
        _statusCtrl.add(
          StatusMessage(
            domain: StatusDomain.audio,
            state: message.enabled ? StatusState.ok : StatusState.degraded,
            source: message.source,
            detail: message.enabled ? 'Source enabled' : 'Source disabled',
          ),
        );
      case AudioChunkMessage():
        // The fake ignores uploaded audio; it plays a canned script instead.
        break;
    }
  }

  void _startScript() {
    if (_running) return;
    _running = true;
    _clearTimers();

    var elapsedMs = 0;
    for (var i = 0; i < _scriptedLines.length; i++) {
      final line = _scriptedLines[i];
      final fireAt = Duration(milliseconds: 1500 * (i + 1));
      final startMs = elapsedMs;
      final endMs = elapsedMs + 1400;
      elapsedMs = endMs + 100;

      // Emit a partial first, then the final segment shortly after.
      _timers.add(Timer(fireAt, () {
        if (!_running) return;
        _transcriptCtrl.add(
          TranscriptSegment(
            id: 'seg-$i',
            text: line,
            startMs: startMs,
            endMs: endMs,
            isFinal: false,
          ),
        );
      }));
      _timers.add(Timer(fireAt + const Duration(milliseconds: 400), () {
        if (!_running) return;
        _transcriptCtrl.add(
          TranscriptSegment(
            id: 'seg-$i',
            text: line,
            startMs: startMs,
            endMs: endMs,
            isFinal: true,
          ),
        );
      }));

      // The 4th scripted line is a question — emit detection + response.
      if (line.endsWith('?')) {
        _scheduleQuestionAndResponse(
          questionText: line,
          sourceSegmentId: 'seg-$i',
          fireAt: fireAt + const Duration(milliseconds: 600),
        );
      }
    }
  }

  void _scheduleQuestionAndResponse({
    required String questionText,
    required String sourceSegmentId,
    required Duration fireAt,
  }) {
    final questionId = 'q-${_seq++}';
    _timers.add(Timer(fireAt, () {
      if (!_running) return;
      _questionsCtrl.add(
        DetectedQuestion(
          id: questionId,
          text: questionText,
          sourceSegmentId: sourceSegmentId,
        ),
      );
    }));

    const responseTokens = <String>[
      'On ',
      'Windows ',
      'we ',
      'use ',
      'WASAPI ',
      'loopback ',
      'to ',
      'capture ',
      'system ',
      'audio.',
    ];
    for (var j = 0; j < responseTokens.length; j++) {
      _timers.add(Timer(
        fireAt + Duration(milliseconds: 300 + (j * 120)),
        () {
          if (!_running) return;
          _responseTokenCtrl.add(
            ResponseTokenMessage(
              questionId: questionId,
              token: responseTokens[j],
            ),
          );
        },
      ));
    }
    _timers.add(Timer(
      fireAt + Duration(milliseconds: 300 + (responseTokens.length * 120)),
      () {
        if (!_running) return;
        _responseDoneCtrl.add(
          ResponseDoneMessage(questionId: questionId, latencyMs: 1500),
        );
      },
    ));
  }

  void _clearTimers() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
  }

  @override
  Future<void> dispose() async {
    _running = false;
    _clearTimers();
    await _connectionCtrl.close();
    await _transcriptCtrl.close();
    await _questionsCtrl.close();
    await _responseTokenCtrl.close();
    await _responseDoneCtrl.close();
    await _statusCtrl.close();
    await _errorCtrl.close();
  }
}
