import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../protocol/messages.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_theme.dart';
import '../../../state/providers.dart';
import 'panel_card.dart';

/// AI Response Panel — shows the generated response, streaming tokens in as
/// they arrive (CLAUDE.md §4.2). The question being answered is shown above the
/// answer so it's always clear what the response refers to. When complete it
/// surfaces the measured question -> response latency (CLAUDE.md §4.3 metric).
class AiResponsePanel extends ConsumerWidget {
  const AiResponsePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final response = ref.watch(aiResponseProvider);
    final questions = ref.watch(detectedQuestionsProvider);
    final textTheme = Theme.of(context).textTheme;

    final Widget trailing;
    if (response.isStreaming) {
      trailing = const _StreamingDot();
    } else if (response.latencyMs != null) {
      trailing = Text(
        '${response.latencyMs} ms',
        style: textTheme.bodySmall,
      );
    } else {
      trailing = const SizedBox.shrink();
    }

    // Find the question text this response is answering (by id).
    final DetectedQuestion? answering = response.questionId == null
        ? null
        : questions
            .where((q) => q.id == response.questionId)
            .cast<DetectedQuestion?>()
            .firstWhere((_) => true, orElse: () => null);

    return PanelCard(
      title: 'AI Response',
      trailing: trailing,
      child: response.text.isEmpty
          ? Center(
              child: Text(
                'Responses will stream here as questions are answered.',
                style: textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            )
          : SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (answering != null) ...[
                    _QuestionHeader(text: answering.text),
                    const SizedBox(height: AppTheme.spaceMd),
                  ],
                  Text(
                    response.text,
                    style: textTheme.bodyLarge?.copyWith(height: 1.5),
                  ),
                ],
              ),
            ),
    );
  }
}

/// The question being answered, shown as a labelled chip above the answer.
class _QuestionHeader extends StatelessWidget {
  const _QuestionHeader({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppTheme.spaceSm),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.help_outline,
                size: 13,
                color: AppColors.accent,
              ),
              const SizedBox(width: AppTheme.spaceXs),
              Text(
                'ANSWERING',
                style: textTheme.labelSmall?.copyWith(
                  color: AppColors.accent,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.spaceXs),
          Text(
            text,
            style: textTheme.bodyMedium?.copyWith(
              color: AppColors.textSecondary,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}

/// A small pulsing accent dot indicating an active token stream.
class _StreamingDot extends StatefulWidget {
  const _StreamingDot();

  @override
  State<_StreamingDot> createState() => _StreamingDotState();
}

class _StreamingDotState extends State<_StreamingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller.drive(Tween<double>(begin: 0.3, end: 1)),
      child: Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          color: AppColors.accent,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
