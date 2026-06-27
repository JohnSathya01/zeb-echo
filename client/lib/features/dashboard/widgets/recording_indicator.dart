import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/providers.dart';
import '../../../state/session_controller.dart';
import '../../../theme/app_colors.dart';

/// Status dot beside the wordmark that doubles as a recording indicator.
///
///  - **idle**    → a calm, static lime dot.
///  - **running** → a pulsing RED dot (with a soft halo) so the user clearly
///                  sees that capture/recording is live (CLAUDE.md §4.3 — make
///                  capture state obvious).
///  - **paused**  → a static amber dot.
class RecordingIndicator extends ConsumerStatefulWidget {
  const RecordingIndicator({super.key, this.size = 11});

  /// Diameter of the core dot in logical pixels.
  final double size;

  @override
  ConsumerState<RecordingIndicator> createState() => _RecordingIndicatorState();
}

class _RecordingIndicatorState extends ConsumerState<RecordingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(
      sessionControllerProvider.select((s) => s.status),
    );
    final recording = status == SessionStatus.running;

    // Pulse only while recording; otherwise hold a steady dot.
    if (recording) {
      if (!_controller.isAnimating) {
        _controller.repeat(reverse: true);
      }
    } else if (_controller.isAnimating) {
      _controller
        ..stop()
        ..reset();
    }

    final Color color = switch (status) {
      SessionStatus.running => AppColors.statusError, // recording red
      SessionStatus.paused => AppColors.statusWarning,
      SessionStatus.idle => AppColors.accent,
    };

    if (!recording) {
      return _Dot(size: widget.size, color: color);
    }

    // Recording: pulse opacity + a soft expanding halo.
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value; // 0..1
        return SizedBox(
          width: widget.size * 2.2,
          height: widget.size * 2.2,
          child: Center(
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Expanding, fading halo.
                Container(
                  width: widget.size * (1.2 + t),
                  height: widget.size * (1.2 + t),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color.withValues(alpha: 0.30 * (1 - t)),
                  ),
                ),
                // Core dot, brightening with the pulse.
                _Dot(size: widget.size, color: color.withValues(alpha: 0.7 + 0.3 * t)),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
