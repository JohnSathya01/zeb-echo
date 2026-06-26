import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/dashboard/dashboard_screen.dart';
import 'state/providers.dart';
import 'theme/app_theme.dart';

/// Connect to the real Node backend instead of the in-app fake.
/// Enable with: `flutter run -d chrome --dart-define=REAL_BACKEND=true`.
const bool _useRealBackend =
    bool.fromEnvironment('REAL_BACKEND', defaultValue: false);

/// Optional backend endpoint override, e.g.
/// `--dart-define=BACKEND_URL=ws://127.0.0.1:8787`.
const String _backendUrl =
    String.fromEnvironment('BACKEND_URL', defaultValue: 'ws://127.0.0.1:8787');

void main() {
  // ProviderScope is the Riverpod root (state-management choice, CLAUDE.md §6).
  runApp(
    ProviderScope(
      overrides: [
        // Default is fake/standalone; flip to the real backend via build flag.
        useFakeServicesProvider.overrideWithValue(!_useRealBackend),
        backendEndpointProvider.overrideWithValue(Uri.parse(_backendUrl)),
      ],
      child: const ZebEchoApp(),
    ),
  );
}

class ZebEchoApp extends StatelessWidget {
  const ZebEchoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'zeb Echo',
      debugShowCheckedModeBanner: false,
      // Premium dark theme is the only theme (CLAUDE.md §5).
      theme: AppTheme.dark(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      home: const DashboardScreen(),
    );
  }
}
