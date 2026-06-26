import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/backend_client.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_theme.dart';
import '../../../state/providers.dart';

/// Audio Status Indicator — live status of mic + system audio plus the backend
/// connection (CLAUDE.md §4.2 / §4.3). Compact, sits in the top bar.
///
/// The Mic and System chips are interactive toggles: tapping one enables or
/// disables that capture source (sends `source.toggle`). A disabled source's
/// audio is never transcribed. The dot colour reflects the backend-reported
/// capture state (off / capturing / error).
class AudioStatusIndicator extends ConsumerWidget {
  const AudioStatusIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionAsync = ref.watch(connectionStateProvider);
    final sources = ref.watch(audioSourcesProvider);
    final sourcesNotifier = ref.read(audioSourcesProvider.notifier);

    final connection =
        connectionAsync.valueOrNull ?? BackendConnectionState.disconnected;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _StatusChip(
          icon: sources.micEnabled ? Icons.mic : Icons.mic_off,
          label: 'Mic',
          color: _captureColor(sources.micStatus),
          enabled: sources.micEnabled,
          onTap: sourcesNotifier.toggleMic,
        ),
        const SizedBox(width: AppTheme.spaceSm),
        _StatusChip(
          icon: sources.systemEnabled
              ? Icons.volume_up_outlined
              : Icons.volume_off_outlined,
          label: 'System',
          color: _captureColor(sources.systemStatus),
          enabled: sources.systemEnabled,
          onTap: sourcesNotifier.toggleSystem,
        ),
        const SizedBox(width: AppTheme.spaceSm),
        _StatusChip(
          icon: Icons.cloud_outlined,
          label: 'Backend',
          color: _connectionColor(connection),
        ),
      ],
    );
  }

  Color _captureColor(SourceCaptureState status) {
    switch (status) {
      case SourceCaptureState.capturing:
        return AppColors.statusOk;
      case SourceCaptureState.error:
        return AppColors.statusError;
      case SourceCaptureState.off:
        return AppColors.textSecondary;
    }
  }

  Color _connectionColor(BackendConnectionState state) {
    switch (state) {
      case BackendConnectionState.connected:
        return AppColors.statusOk;
      case BackendConnectionState.connecting:
        return AppColors.statusWarning;
      case BackendConnectionState.error:
        return AppColors.statusError;
      case BackendConnectionState.disconnected:
        return AppColors.textSecondary;
    }
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final Color color;

  /// When non-null the chip is an interactive toggle.
  final VoidCallback? onTap;

  /// When false (and tappable) the chip renders dimmed to read as "off".
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // Toggle chips that are off read dimmer; the accent border marks "on".
    final isToggle = onTap != null;
    final borderColor =
        isToggle && enabled ? AppColors.accent : AppColors.border;
    final labelStyle = isToggle && !enabled
        ? textTheme.bodySmall?.copyWith(color: AppColors.textSecondary)
        : textTheme.bodySmall;

    final chip = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spaceSm,
        vertical: AppTheme.spaceXs,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: AppTheme.spaceXs),
          Text(label, style: labelStyle),
          const SizedBox(width: AppTheme.spaceXs),
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ],
      ),
    );

    if (!isToggle) return chip;
    return Tooltip(
      message: enabled ? 'Tap to mute $label' : 'Tap to enable $label',
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radius),
        onTap: onTap,
        child: chip,
      ),
    );
  }
}
