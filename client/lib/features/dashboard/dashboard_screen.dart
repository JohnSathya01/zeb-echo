import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import 'widgets/ai_response_panel.dart';
import 'widgets/audio_status_indicator.dart';
import 'widgets/detected_question_panel.dart';
import 'widgets/live_transcript_panel.dart';
import 'widgets/session_controls.dart';

/// Meeting Dashboard — the central workspace hosting all panels (CLAUDE.md §4.2).
///
/// Layout: a top bar (title + audio status + session controls) over a
/// two-column body. Left: live transcript. Right: detected questions stacked
/// over the AI response. Minimal, dark, low-distraction (§5).
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TopBar(),
            Divider(height: 1),
            Expanded(child: _DashboardBody()),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      color: AppColors.backgroundBlack,
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spaceLg,
        vertical: AppTheme.spaceMd,
      ),
      child: Row(
        children: [
          // Sparing accent use: a single small mark next to the product name.
          Container(
            width: 10,
            height: 10,
            decoration: const BoxDecoration(
              color: AppColors.accent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: AppTheme.spaceSm),
          // Brand wordmark: "zeb" plain + "Echo" in zeb's serif-italic accent.
          Text.rich(
            TextSpan(
              style: textTheme.headlineSmall,
              children: [
                const TextSpan(text: 'zeb '),
                TextSpan(
                  text: 'Echo',
                  style: textTheme.headlineSmall?.merge(AppTheme.brandEmphasis),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppTheme.spaceMd),
          // Subtitle yields space first on narrow windows (truncates) so the
          // status indicator + controls never overflow.
          Flexible(
            child: Text(
              'Meeting Assistant',
              style: textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
            ),
          ),
          const SizedBox(width: AppTheme.spaceMd),
          const AudioStatusIndicator(),
          const SizedBox(width: AppTheme.spaceLg),
          const SessionControls(),
        ],
      ),
    );
  }
}

class _DashboardBody extends StatelessWidget {
  const _DashboardBody();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(AppTheme.spaceMd),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 3,
            child: LiveTranscriptPanel(),
          ),
          SizedBox(width: AppTheme.spaceMd),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: DetectedQuestionPanel()),
                SizedBox(height: AppTheme.spaceMd),
                Expanded(child: AiResponsePanel()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
