import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'backend_launcher.dart';
import 'port_utils.dart';

/// Desktop implementation: spawns + supervises the bundled backend executable
/// (PHASE2_PLAN.md §1). Uses `dart:io` (Process/Socket), so it is only compiled
/// into native desktop builds — web gets the stub via conditional import.
class IoBackendLauncher implements BackendLauncher {
  IoBackendLauncher(this._config);

  final BackendLauncherConfig _config;

  final StreamController<BackendLaunchState> _stateCtrl =
      StreamController<BackendLaunchState>.broadcast();

  Process? _process;
  Uri? _endpoint;
  int _restarts = 0;
  bool _stopped = false;
  StreamSubscription<dynamic>? _exitSub;

  @override
  Stream<BackendLaunchState> get state => _stateCtrl.stream;

  @override
  Uri? get endpoint => _endpoint;

  @override
  bool get isSupported => true;

  @override
  Future<Uri> start() async {
    _stopped = false;
    _restarts = 0;
    return _spawnAndWait();
  }

  /// Spawn the process on a fresh free port and wait until its WS is ready.
  Future<Uri> _spawnAndWait() async {
    _emit(BackendLaunchState.starting);

    final executable = _config.executablePath ?? _defaultExecutablePath();
    if (!File(executable).existsSync()) {
      _emit(BackendLaunchState.failed);
      throw BackendLaunchException('Backend executable not found: $executable');
    }

    final port = await findFreePort(_config.host);
    final ffmpegPath = _config.ffmpegPath ?? _defaultFfmpegPath();
    final sckHelperPath = _defaultSckHelperPath();
    final wasapiHelperPath = _defaultWasapiHelperPath();

    final env = <String, String>{
      'PORT': '$port',
      'HOST': _config.host,
      // Watchdog: the backend exits when THIS app process is gone, so quitting
      // the app never leaves an orphaned backend (which would keep the macOS
      // screen-recording session alive). `pid` is the Flutter process id.
      'PARENT_PID': '$pid',
      // Point the backend at the bundled ffmpeg (it isn't on a teammate's PATH).
      if (ffmpegPath != null) 'FFMPEG_PATH': ffmpegPath,
      // macOS ScreenCaptureKit helper (system audio without BlackHole).
      if (sckHelperPath != null) 'SCK_HELPER_PATH': sckHelperPath,
      // Windows WASAPI loopback helper (system audio without a virtual device).
      if (wasapiHelperPath != null) 'WASAPI_HELPER_PATH': wasapiHelperPath,
      ..._config.extraEnv,
    };

    final Process process;
    try {
      process = await Process.start(
        executable,
        const <String>[],
        environment: env,
        // Inherit the parent env too so PATH etc. remain available.
        includeParentEnvironment: true,
      );
    } catch (e) {
      _emit(BackendLaunchState.failed);
      throw BackendLaunchException('Failed to spawn backend: $e');
    }
    _process = process;

    // Forward backend stdout/stderr to the Flutter console for diagnostics.
    process.stdout.listen((d) => stdout.add(d));
    process.stderr.listen((d) => stderr.add(d));

    // Supervise: an unexpected exit triggers a bounded auto-restart.
    _exitSub?.cancel();
    _exitSub = process.exitCode.asStream().listen(_onProcessExit);

    final endpoint = Uri.parse('ws://${_config.host}:$port');
    final ready = await waitForPort(_config.host, port, _config.readyTimeout);
    if (!ready) {
      await _killProcess();
      _emit(BackendLaunchState.failed);
      throw BackendLaunchException(
        'Backend did not become ready on $endpoint within '
        '${_config.readyTimeout.inSeconds}s.',
      );
    }

    _endpoint = endpoint;
    _emit(BackendLaunchState.ready);
    return endpoint;
  }

  /// Handle an unexpected process exit: restart up to [maxRestarts], else fail.
  void _onProcessExit(int code) {
    if (_stopped) return; // expected exit from stop()
    _process = null;
    _endpoint = null;
    if (_restarts >= _config.maxRestarts) {
      _emit(BackendLaunchState.failed);
      return;
    }
    _restarts++;
    _emit(BackendLaunchState.crashed);
    // Re-spawn; swallow errors here since state already reflects failure and
    // the BackendClient will keep retrying its connection regardless.
    unawaited(_spawnAndWait().catchError((_) => Uri()));
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    await _exitSub?.cancel();
    _exitSub = null;
    await _killProcess();
    _endpoint = null;
    _emit(BackendLaunchState.idle);
  }

  Future<void> _killProcess() async {
    final process = _process;
    _process = null;
    if (process == null) return;
    process.kill(ProcessSignal.sigterm);
    // Give it a moment to exit cleanly, then force-kill.
    final exited = await process.exitCode
        .timeout(const Duration(seconds: 3), onTimeout: () => -1)
        .catchError((_) => -1);
    if (exited == -1) {
      process.kill(ProcessSignal.sigkill);
    }
  }

  void _emit(BackendLaunchState s) {
    if (!_stateCtrl.isClosed) _stateCtrl.add(s);
  }

  /// Dispose resources (the app calls [stop]; this also closes the stream).
  Future<void> dispose() async {
    await stop();
    await _stateCtrl.close();
  }

  // --- helpers ---------------------------------------------------------------

  /// Per-OS default location of the bundled backend executable, relative to the
  /// running app bundle. Overridable via [BackendLauncherConfig.executablePath].
  static String _defaultExecutablePath() {
    final appDir = File(Platform.resolvedExecutable).parent;
    if (Platform.isMacOS) {
      // Foo.app/Contents/MacOS/foo → resources in Contents/Resources/backend/.
      // The backend is shipped per-arch (NOT lipo'd: pkg appends its payload at
      // a byte offset that a fat binary corrupts → "Invalid or unexpected token"
      // in pkg/prelude/bootstrap.js). Pick the slice matching this Mac's CPU.
      final contents = appDir.parent; // Contents/
      final arch = Abi.current() == Abi.macosArm64 ? 'arm64' : 'x64';
      return '${contents.path}/Resources/backend/zeb-echo-backend-$arch';
    }
    if (Platform.isWindows) {
      // The Flutter exe sits in the install dir; ship the backend alongside.
      return '${appDir.path}\\backend\\zeb-echo-backend.exe';
    }
    // Linux / other: alongside the executable.
    return '${appDir.path}/backend/zeb-echo-backend';
  }

  /// Per-OS default location of the bundled ffmpeg binary.
  static String? _defaultFfmpegPath() {
    final appDir = File(Platform.resolvedExecutable).parent;
    if (Platform.isMacOS) {
      final contents = appDir.parent;
      return '${contents.path}/Resources/backend/ffmpeg';
    }
    if (Platform.isWindows) {
      return '${appDir.path}\\backend\\ffmpeg.exe';
    }
    return '${appDir.path}/backend/ffmpeg';
  }

  /// Location of the bundled macOS ScreenCaptureKit helper (null off macOS).
  static String? _defaultSckHelperPath() {
    if (!Platform.isMacOS) {
      return null;
    }
    final contents = File(Platform.resolvedExecutable).parent.parent;
    return '${contents.path}/Resources/backend/zeb-audio-capture';
  }

  /// Location of the bundled Windows WASAPI helper (null off Windows).
  static String? _defaultWasapiHelperPath() {
    if (!Platform.isWindows) {
      return null;
    }
    final appDir = File(Platform.resolvedExecutable).parent;
    return '${appDir.path}\\backend\\zeb-audio-capture.exe';
  }
}

/// Factory used by `backend_launcher.dart` via conditional import on desktop.
BackendLauncher createBackendLauncherImpl(BackendLauncherConfig config) =>
    IoBackendLauncher(config);
