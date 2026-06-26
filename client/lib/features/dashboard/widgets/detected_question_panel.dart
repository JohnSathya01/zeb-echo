import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_theme.dart';
import '../../../state/providers.dart';
import 'panel_card.dart';

/// Detected Question Panel — highlights questions identified from participants
/// (CLAUDE.md §4.2). The newest question gets a subtle accent edge; older ones
/// stay muted to keep the panel low-distraction (§5).
class DetectedQuestionPanel extends ConsumerWidget {
  const DetectedQuestionPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final questions = ref.watch(detectedQuestionsProvider);
    final textTheme = Theme.of(context).textTheme;

    return PanelCard(
      title: 'Detected Questions',
      child: questions.isEmpty
          ? Center(
              child: Text(
                'No questions detected yet.',
                style: textTheme.bodySmall,
              ),
            )
          : ListView.separated(
              reverse: true,
              itemCount: questions.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(height: AppTheme.spaceSm),
              itemBuilder: (context, index) {
                // reverse:true => index 0 is the newest (last in list).
                final question = questions[questions.length - 1 - index];
                final isLatest = index == 0;
                return Container(
                  padding: const EdgeInsets.all(AppTheme.spaceMd),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceElevated,
                    borderRadius: BorderRadius.circular(AppTheme.radius),
                    border: Border(
                      left: BorderSide(
                        color: isLatest
                            ? AppColors.accent
                            : AppColors.border,
                        width: 3,
                      ),
                    ),
                  ),
                  child: Text(
                    question.text,
                    style: isLatest
                        ? textTheme.bodyMedium
                        : textTheme.bodyMedium?.copyWith(
                            color: AppColors.textSecondary,
                          ),
                  ),
                );
              },
            ),
    );
  }
}
