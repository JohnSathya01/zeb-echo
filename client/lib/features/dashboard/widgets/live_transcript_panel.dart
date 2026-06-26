import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../protocol/messages.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_theme.dart';
import '../../../state/providers.dart';
import 'panel_card.dart';

/// Live Transcript Panel — streams the ongoing transcript (CLAUDE.md §4.2).
///
/// The newest line is pinned at the TOP in a bright, accent-highlighted box so
/// the current speech is always easy to track in a fixed position. Older lines
/// flow beneath it, dimmed and newest-first, so the reader never has to scroll
/// down to follow along.
class LiveTranscriptPanel extends ConsumerWidget {
  const LiveTranscriptPanel({super.key});

  /// Style for the pinned current line — large, bright, bold.
  static const TextStyle _currentStyle = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 19,
    fontWeight: FontWeight.w700,
    height: 1.4,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allSegments = ref.watch(transcriptProvider);
    final sources = ref.watch(audioSourcesProvider);

    // Keep only segments with real text; newest last in source order.
    final segments = allSegments
        .where((s) => s.text.trim().isNotEmpty)
        .toList(growable: false);

    if (segments.isEmpty) {
      return const PanelCard(
        title: 'Live Transcript',
        child: Center(
          child: Text(
            'Transcript will appear here once the session starts.',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    // Only label speakers when both streams are live; otherwise it's noise.
    final showSpeakers = sources.micEnabled && sources.systemEnabled;

    final current = segments.last;
    // Older lines, newest first (everything except the current/last segment).
    final older =
        segments.reversed.skip(1).toList(growable: false);

    return PanelCard(
      title: 'Live Transcript',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ---- Pinned, highlighted current line ----
          // Uniform border + a separate accent bar via a Row (asymmetric
          // Border sides can mis-paint the child on Flutter web).
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppTheme.radius),
              border: Border.all(color: AppColors.border),
            ),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 4,
                    decoration: const BoxDecoration(
                      color: AppColors.accent,
                      borderRadius: BorderRadius.horizontal(
                        left: Radius.circular(AppTheme.radius),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(AppTheme.spaceMd),
                      child: (showSpeakers && current.speaker != null)
                          ? RichText(
                              text: TextSpan(
                                style: _currentStyle,
                                children: [
                                  TextSpan(
                                    text: '${current.speaker}  ',
                                    style: _currentStyle.copyWith(
                                      color: AppColors.accent,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  TextSpan(text: current.text),
                                ],
                              ),
                            )
                          : Text(current.text, style: _currentStyle),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (older.isNotEmpty) ...[
            const SizedBox(height: AppTheme.spaceMd),
            const Text(
              'EARLIER',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AppTheme.spaceSm),
            Expanded(
              child: ListView.separated(
                itemCount: older.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(height: AppTheme.spaceSm),
                itemBuilder: (context, index) => _line(
                  segment: older[index],
                  showSpeaker: showSpeakers,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 15,
                    height: 1.35,
                  ),
                ),
              ),
            ),
          ] else
            const Spacer(),
        ],
      ),
    );
  }

  /// Render one segment with [style]; prefixes a speaker label when requested.
  Widget _line({
    required TranscriptSegment segment,
    required bool showSpeaker,
    required TextStyle style,
  }) {
    final effective =
        segment.isFinal ? style : style.copyWith(fontStyle: FontStyle.italic);
    final speaker = segment.speaker;
    if (!showSpeaker || speaker == null) {
      return Text(segment.text, style: effective);
    }
    return RichText(
      text: TextSpan(
        style: effective,
        children: [
          TextSpan(
            text: '$speaker  ',
            style: effective.copyWith(
              color: AppColors.accent,
              fontWeight: FontWeight.w700,
            ),
          ),
          TextSpan(text: segment.text),
        ],
      ),
    );
  }
}
