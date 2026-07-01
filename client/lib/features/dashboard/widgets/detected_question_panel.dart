import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../protocol/messages.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_theme.dart';
import '../../../state/providers.dart';
import 'panel_card.dart';

/// Detected Question Panel — highlights questions identified from participants
/// (CLAUDE.md §4.2). The newest question gets a subtle accent edge; older ones
/// stay muted to keep the panel low-distraction (§5).
///
/// In MANUAL response mode (Phase 3) each question shows a ▶ play button; the
/// answer is generated only when the user clicks it.
class DetectedQuestionPanel extends ConsumerWidget {
  const DetectedQuestionPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final questions = ref.watch(detectedQuestionsProvider);
    final manual = ref.watch(responseModeProvider) == ResponseMode.manual;
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
                        color: isLatest ? AppColors.accent : AppColors.border,
                        width: 3,
                      ),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          question.text,
                          style: isLatest
                              ? textTheme.bodyMedium
                              : textTheme.bodyMedium?.copyWith(
                                  color: AppColors.textSecondary,
                                ),
                        ),
                      ),
                      // Manual mode: a ▶ button generates the answer on demand.
                      if (manual) ...[
                        const SizedBox(width: AppTheme.spaceSm),
                        _PlayButton(questionId: question.id),
                      ],
                    ],
                  ),
                );
              },
            ),
    );
  }
}

/// ▶ button that requests an answer for one question (manual mode). Once
/// clicked it shows a check so the user knows the request was sent.
class _PlayButton extends ConsumerStatefulWidget {
  const _PlayButton({required this.questionId});

  final String questionId;

  @override
  ConsumerState<_PlayButton> createState() => _PlayButtonState();
}

class _PlayButtonState extends ConsumerState<_PlayButton> {
  bool _requested = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: _requested ? 'Requested' : 'Generate answer',
      child: Material(
        color: _requested ? AppColors.surface : AppColors.accent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: _requested
              ? null
              : () {
                  generateResponse(ref, widget.questionId);
                  setState(() => _requested = true);
                },
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(
              _requested ? Icons.check : Icons.play_arrow_rounded,
              size: 18,
              color: _requested ? AppColors.textSecondary : AppColors.onAccent,
            ),
          ),
        ),
      ),
    );
  }
}
