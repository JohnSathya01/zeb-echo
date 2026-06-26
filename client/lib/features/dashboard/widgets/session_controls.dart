import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../theme/app_theme.dart';
import '../../../state/providers.dart';
import '../../../state/session_controller.dart';

/// Session Controls — Start, Pause/Resume, Stop the assistance session
/// (CLAUDE.md §4.2). The primary action uses the accent (filled) button; the
/// rest are quiet outlined buttons to keep accent use sparing (§5).
class SessionControls extends ConsumerWidget {
  const SessionControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionControllerProvider);
    final controller = ref.read(sessionControllerProvider.notifier);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        switch (session.status) {
          SessionStatus.idle => FilledButton.icon(
              onPressed: controller.start,
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('Start'),
            ),
          SessionStatus.running => FilledButton.icon(
              onPressed: controller.pause,
              icon: const Icon(Icons.pause, size: 18),
              label: const Text('Pause'),
            ),
          SessionStatus.paused => FilledButton.icon(
              onPressed: controller.resume,
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('Resume'),
            ),
        },
        const SizedBox(width: AppTheme.spaceSm),
        OutlinedButton.icon(
          onPressed: session.isIdle ? null : controller.stop,
          icon: const Icon(Icons.stop, size: 18),
          label: const Text('Stop'),
        ),
      ],
    );
  }
}
