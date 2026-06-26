import 'dart:async';
import 'dart:io';

/// Networking helpers for the backend launcher, split out so they can be
/// unit-tested on the Dart VM without spawning a real backend process.

/// Find a free TCP port by binding to port 0 and reading the assigned port.
///
/// There is an inherent (tiny) race: the port is free at bind time but could be
/// taken before the backend binds it. In practice the backend binds within
/// milliseconds and the launcher would surface a readiness timeout if it lost
/// the race — acceptable for a localhost dev/desktop launcher.
Future<int> findFreePort(String host) async {
  final socket = await ServerSocket.bind(host, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// Poll until something accepts TCP connections on [host]:[port], or [timeout]
/// elapses. Returns true once a connection succeeds, false on timeout.
///
/// [pollInterval] and [connectTimeout] are exposed for tests; the defaults suit
/// a localhost backend that starts within a few hundred milliseconds.
Future<bool> waitForPort(
  String host,
  int port,
  Duration timeout, {
  Duration pollInterval = const Duration(milliseconds: 200),
  Duration connectTimeout = const Duration(milliseconds: 500),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    try {
      final socket = await Socket.connect(host, port, timeout: connectTimeout);
      socket.destroy();
      return true;
    } catch (_) {
      await Future<void>.delayed(pollInterval);
    }
  }
  return false;
}
