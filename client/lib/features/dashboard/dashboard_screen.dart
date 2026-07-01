import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import 'widgets/ai_response_panel.dart';
import 'widgets/audio_status_indicator.dart';
import 'widgets/echo_logo.dart';
import 'widgets/knowledge_base_panel.dart';
import 'widgets/recording_indicator.dart';
import 'widgets/tab_switcher.dart';
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
    final tab = ref.watch(selectedTabProvider);
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _TopBar(),
            const Divider(height: 1),
            Expanded(
              child: switch (tab) {
                AppTab.dashboard => const _DashboardBody(),
                AppTab.knowledgeBase => const KnowledgeBasePanel(),
              },
            ),
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
          // Vector logo mark (echo ripples in the lime accent).
          const EchoLogo(size: 34),
          const SizedBox(width: AppTheme.spaceSm),
          // Brand wordmark: "Echo" in zeb's serif-italic accent, with a small
          // "powered by zeb" (lowercase) beneath it.
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Echo',
                style: textTheme.headlineSmall?.merge(AppTheme.brandEmphasis),
              ),
              Text(
                'powered by zeb',
                style: textTheme.bodySmall?.copyWith(
                  fontSize: 10,
                  letterSpacing: 0.4,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(width: AppTheme.spaceMd),
          // Recording indicator: pulsing red dot while a session is running.
          const RecordingIndicator(),
          const SizedBox(width: AppTheme.spaceLg),
          // Tab switcher: Dashboard | Knowledge Base (Phase 3).
          const TabSwitcher(),
          const Spacer(),
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
