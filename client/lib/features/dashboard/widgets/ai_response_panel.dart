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

    final Widget statusTrailing;
    if (response.isStreaming) {
      statusTrailing = const _StreamingDot();
    } else if (response.latencyMs != null) {
      statusTrailing = Text(
        '${response.latencyMs} ms',
        style: textTheme.bodySmall,
      );
    } else {
      statusTrailing = const SizedBox.shrink();
    }

    // Auto/Manual mode toggle (Phase 3) sits alongside the status indicator.
    final trailing = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _ModeToggle(),
        const SizedBox(width: AppTheme.spaceSm),
        statusTrailing,
      ],
    );

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

/// Compact Auto/Manual toggle for response generation (Phase 3). Auto answers
/// as soon as a question is detected; Manual waits for the ▶ on each question.
class _ModeToggle extends ConsumerWidget {
  const _ModeToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(responseModeProvider);
    final auto = mode == ResponseMode.auto;
    return Tooltip(
      message: auto
          ? 'Automatic: answers generate on detection'
          : 'Manual: click ▶ on a question to answer',
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: AppColors.backgroundBlack,
          borderRadius: BorderRadius.circular(AppTheme.radius - 2),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ModeChip(
              label: 'Auto',
              active: auto,
              onTap: () =>
                  ref.read(responseModeProvider.notifier).setMode(ResponseMode.auto),
            ),
            _ModeChip(
              label: 'Manual',
              active: !auto,
              onTap: () => ref
                  .read(responseModeProvider.notifier)
                  .setMode(ResponseMode.manual),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = active ? AppColors.onAccent : AppColors.textSecondary;
    return Material(
      color: active ? AppColors.accent : Colors.transparent,
      borderRadius: BorderRadius.circular(AppTheme.radius - 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radius - 4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
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
