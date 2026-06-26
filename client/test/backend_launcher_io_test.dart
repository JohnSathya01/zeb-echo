@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeb_echo_client/services/backend_launcher.dart';

/// Integration test for the real process-spawning launcher. It needs the built
/// backend executable, so it only runs when ZEB_BACKEND_EXE points at one
/// (CI has no exe and skips this). Run locally with:
///   ZEB_BACKEND_EXE="$PWD/../backend/build/zeb-echo-backend" \
///     flutter test test/backend_launcher_io_test.dart
void main() {
  final exe = Platform.environment['ZEB_BACKEND_EXE'];

  test(
    'spawns the real backend on a dynamic port, becomes ready, then stops',
    () async {
      final launcher = createBackendLauncher(
        BackendLauncherConfig(
          executablePath: exe,
          // The exe spawns ffmpeg lazily on a session; not needed just to boot.
          extraEnv: const {
            'TRANSCRIPTION_ENGINE': 'fake',
            'LLM_PROVIDER': 'fake',
            'AUDIO_SOURCE': 'none',
          },
          readyTimeout: const Duration(seconds: 15),
        ),
      );
      expect(launcher.isSupported, isTrue);

      final endpoint = await launcher.start();
      // Dynamic port, not the hardcoded dev 8787.
      expect(endpoint.scheme, 'ws');
      expect(endpoint.host, '127.0.0.1');
      expect(endpoint.port, greaterThan(0));

      // The port is actually accepting connections now.
      final socket = await Socket.connect(endpoint.host, endpoint.port);
      socket.destroy();

      await launcher.stop();

      // After stop, the port should no longer accept connections (process gone).
      await expectLater(
        Socket.connect(
          endpoint.host,
          endpoint.port,
          timeout: const Duration(seconds: 1),
        ),
        throwsA(isA<SocketException>()),
      );
    },
    skip: exe == null
        ? 'Set ZEB_BACKEND_EXE to the built backend executable to run this.'
        : false,
  );
}
