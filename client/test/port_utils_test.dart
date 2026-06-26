@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeb_echo_client/services/port_utils.dart';

void main() {
  const host = '127.0.0.1';

  test('findFreePort returns a usable, bindable port', () async {
    final port = await findFreePort(host);
    expect(port, greaterThan(0));
    expect(port, lessThanOrEqualTo(65535));

    // The returned port should be immediately bindable (nothing holds it).
    final server = await ServerSocket.bind(host, port);
    expect(server.port, port);
    await server.close();
  });

  test('findFreePort returns different ports across calls', () async {
    final a = await findFreePort(host);
    final b = await findFreePort(host);
    // Not strictly guaranteed, but the OS hands out distinct ephemeral ports
    // in practice; this guards against a hardcoded/constant regression.
    expect(a == b, isFalse);
  });

  test('waitForPort returns true once a server is listening', () async {
    final server = await ServerSocket.bind(host, 0);
    addTearDown(server.close);

    final ready = await waitForPort(
      host,
      server.port,
      const Duration(seconds: 2),
    );
    expect(ready, isTrue);
  });

  test('waitForPort times out when nothing is listening', () async {
    // Reserve then release a port so we know nothing is listening on it.
    final port = await findFreePort(host);

    final ready = await waitForPort(
      host,
      port,
      const Duration(milliseconds: 600),
      pollInterval: const Duration(milliseconds: 100),
      connectTimeout: const Duration(milliseconds: 100),
    );
    expect(ready, isFalse);
  });

  test('waitForPort succeeds for a server that starts after a delay', () async {
    final port = await findFreePort(host);

    // Start listening shortly after the wait begins, to exercise the polling.
    ServerSocket? server;
    Future<void>.delayed(const Duration(milliseconds: 300), () async {
      server = await ServerSocket.bind(host, port);
    });
    addTearDown(() async => server?.close());

    final ready = await waitForPort(
      host,
      port,
      const Duration(seconds: 3),
      pollInterval: const Duration(milliseconds: 100),
    );
    expect(ready, isTrue);
  });
}
