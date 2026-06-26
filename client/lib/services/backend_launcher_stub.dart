import 'dart:async';

import 'backend_launcher.dart';

/// Web (and any non-`dart:io`) stub: a browser cannot spawn processes, so the
/// launcher is unsupported. On web the backend is run separately and reached
/// via `--dart-define=BACKEND_URL=...` (see `main.dart`).
class _UnsupportedBackendLauncher implements BackendLauncher {
  @override
  Stream<BackendLaunchState> get state =>
      Stream<BackendLaunchState>.value(BackendLaunchState.idle);

  @override
  Uri? get endpoint => null;

  @override
  bool get isSupported => false;

  @override
  Future<Uri> start() => throw const BackendLaunchException(
        'Spawning the backend is not supported on this platform; run the '
        'backend separately and pass its URL via BACKEND_URL.',
      );

  @override
  Future<void> stop() async {}
}

/// Factory used by `backend_launcher.dart` via conditional import on web.
BackendLauncher createBackendLauncherImpl(BackendLauncherConfig config) =>
    _UnsupportedBackendLauncher();
