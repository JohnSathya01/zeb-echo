import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/dashboard/dashboard_screen.dart';
import 'services/backend_launcher.dart';
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

/// When set, the app spawns the bundled backend itself (the packaged-app path,
/// PHASE2_PLAN.md §1) rather than connecting to a separately-run one. Defaults
/// on for real-backend desktop builds; disable to point at an external backend
/// via `BACKEND_URL` (e.g. `--dart-define=SPAWN_BACKEND=false`).
const bool _spawnBackend =
    bool.fromEnvironment('SPAWN_BACKEND', defaultValue: true);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Default endpoint: the explicit override (or the dev default). When we spawn
  // the backend ourselves below, this is replaced with the chosen dynamic port.
  Uri endpoint = Uri.parse(_backendUrl);
  BackendLauncher? launcher;

  if (_useRealBackend && _spawnBackend) {
    final candidate = createBackendLauncher(const BackendLauncherConfig());
    if (candidate.isSupported) {
      try {
        // Spawn the bundled backend and wait until its WebSocket is ready, then
        // connect the client to the port it chose.
        endpoint = await candidate.start();
        launcher = candidate;
      } on BackendLaunchException catch (e) {
        // Fall back to the configured URL; the BackendClient will keep retrying
        // and the UI surfaces the disconnected state (CLAUDE.md §4.3).
        debugPrint('Backend launch failed, using $endpoint instead: $e');
      }
    }
  }

  runApp(
    ProviderScope(
      overrides: [
        // Default is fake/standalone; flip to the real backend via build flag.
        useFakeServicesProvider.overrideWithValue(!_useRealBackend),
        backendEndpointProvider.overrideWithValue(endpoint),
        backendLauncherProvider.overrideWithValue(launcher),
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
      // The guard kills the spawned backend on app exit (PHASE2_PLAN.md §1).
      home: const _LifecycleGuard(child: DashboardScreen()),
    );
  }
}

/// Kills the spawned backend on app exit (detached lifecycle), so closing the
/// window never leaves an orphaned backend process behind.
class _LifecycleGuard extends ConsumerStatefulWidget {
  const _LifecycleGuard({required this.child});

  final Widget child;

  @override
  ConsumerState<_LifecycleGuard> createState() => _LifecycleGuardState();
}

class _LifecycleGuardState extends ConsumerState<_LifecycleGuard>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      // Best-effort shutdown of the spawned backend on app close.
      ref.read(backendLauncherProvider)?.stop();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
