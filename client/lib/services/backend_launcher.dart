import 'backend_launcher_stub.dart'
    if (dart.library.io) 'backend_launcher_io.dart';

/// Lifecycle state of the spawned backend process (surfaced for diagnostics).
enum BackendLaunchState {
  /// Not started yet, or fully stopped.
  idle,

  /// Process spawned; waiting for the WebSocket to accept connections.
  starting,

  /// WebSocket reachable — the client may connect.
  ready,

  /// Process exited unexpectedly; a restart is scheduled.
  crashed,

  /// Failed to start (binary missing, port unavailable, never became ready).
  failed,
}

/// Owns the lifecycle of the bundled Node backend executable (PHASE2_PLAN.md §1,
/// CLAUDE.md §9 "startup model").
///
/// On a packaged desktop app the Flutter process spawns the backend itself:
/// picks a free localhost port, launches the bundled executable (pointing it at
/// the bundled ffmpeg via `FFMPEG_PATH`), waits for the WebSocket to be ready,
/// hands the `ws://` URI to the [BackendClient], restarts the process if it
/// crashes, and kills it on app exit.
///
/// This is an interface so the UI/tests depend on the contract, not `dart:io`.
/// The concrete implementation lives in `backend_launcher_io.dart` (desktop);
/// web builds get a no-op stub (`backend_launcher_stub.dart`) since a browser
/// cannot spawn processes — there the user runs the backend separately.
abstract interface class BackendLauncher {
  /// Current lifecycle state, for diagnostics / status surfacing.
  Stream<BackendLaunchState> get state;

  /// The `ws://127.0.0.1:<port>` URI once [start] has the backend ready.
  /// Null until ready.
  Uri? get endpoint;

  /// Whether this platform can spawn a backend at all (false on web).
  bool get isSupported;

  /// Spawn the backend and resolve once its WebSocket is accepting
  /// connections. Throws [BackendLaunchException] if it cannot be started.
  Future<Uri> start();

  /// Terminate the backend process and stop supervising it.
  Future<void> stop();
}

/// Raised when the backend cannot be spawned or never becomes ready.
class BackendLaunchException implements Exception {
  const BackendLaunchException(this.message);

  final String message;

  @override
  String toString() => 'BackendLaunchException: $message';
}

/// Configuration for spawning the backend. Defaults suit a packaged app; tests
/// and dev can override the binary path and the env passed to the process.
class BackendLauncherConfig {
  const BackendLauncherConfig({
    this.executablePath,
    this.ffmpegPath,
    this.extraEnv = const <String, String>{},
    this.host = '127.0.0.1',
    this.readyTimeout = const Duration(seconds: 20),
    this.maxRestarts = 3,
  });

  /// Absolute path to the backend executable. When null, the implementation
  /// resolves it relative to the app bundle (per-OS default location).
  final String? executablePath;

  /// Absolute path to the bundled ffmpeg binary, passed as `FFMPEG_PATH`. When
  /// null, the implementation resolves the per-OS bundled default.
  final String? ffmpegPath;

  /// Extra environment variables for the backend process (e.g. `CF_GATEWAY_URL`,
  /// `LLM_PROVIDER`, `TRANSCRIPTION_ENGINE`). Merged over the inherited env.
  final Map<String, String> extraEnv;

  /// Host to bind — localhost only in Phase 1 (privacy, CLAUDE.md §4.3).
  final String host;

  /// How long to wait for the WebSocket port to start accepting connections
  /// before treating the launch as failed.
  final Duration readyTimeout;

  /// How many times to auto-restart the process after an unexpected exit
  /// before giving up (CLAUDE.md §4.3 resilience).
  final int maxRestarts;
}

/// Construct the platform-appropriate launcher (real on desktop, stub on web).
BackendLauncher createBackendLauncher(BackendLauncherConfig config) =>
    createBackendLauncherImpl(config);
