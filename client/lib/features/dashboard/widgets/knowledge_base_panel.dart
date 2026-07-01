import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/providers.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_theme.dart';
import 'panel_card.dart';

/// Knowledge Base tab (Phase 3). The user pastes domain knowledge here; on save
/// it is sent to the backend (`kb.set`) and injected into the LLM prompt as
/// authoritative context, so answers can cite facts absent from the transcript.
class KnowledgeBasePanel extends ConsumerStatefulWidget {
  const KnowledgeBasePanel({super.key});

  @override
  ConsumerState<KnowledgeBasePanel> createState() => _KnowledgeBasePanelState();
}

class _KnowledgeBasePanelState extends ConsumerState<KnowledgeBasePanel> {
  late final TextEditingController _controller;
  bool _dirty = false;
  bool _savedRecently = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: ref.read(knowledgeBaseProvider));
    _controller.addListener(() {
      final changed = _controller.text != ref.read(knowledgeBaseProvider);
      if (changed != _dirty) {
        setState(() => _dirty = changed);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    ref.read(knowledgeBaseProvider.notifier).setContent(_controller.text);
    setState(() {
      _dirty = false;
      _savedRecently = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(AppTheme.spaceMd),
      child: PanelCard(
        title: 'Knowledge Base',
        trailing: _SaveButton(
          dirty: _dirty,
          saved: _savedRecently,
          onSave: _save,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Add domain knowledge — product facts, talking points, project '
              'context. Echo uses this as authoritative context when answering, '
              'so responses can cite details not spoken in the meeting.',
              style: textTheme.bodySmall,
            ),
            const SizedBox(height: AppTheme.spaceMd),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.backgroundBlack,
                  borderRadius: BorderRadius.circular(AppTheme.radius),
                  border: Border.all(color: AppColors.border),
                ),
                padding: const EdgeInsets.all(AppTheme.spaceMd),
                child: TextField(
                  controller: _controller,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: textTheme.bodyMedium,
                  cursorColor: AppColors.accent,
                  decoration: const InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                    hintText:
                        'e.g.\n- Our product "Echo" is a live meeting copilot.\n'
                        '- Pricing: \$20/user/month.\n'
                        '- Project Mantle ships in Q3.',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SaveButton extends StatelessWidget {
  const _SaveButton({
    required this.dirty,
    required this.saved,
    required this.onSave,
  });

  final bool dirty;
  final bool saved;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final label = dirty ? 'Save' : (saved ? 'Saved ✓' : 'Save');
    return FilledButton(
      onPressed: dirty ? onSave : null,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spaceMd,
          vertical: AppTheme.spaceSm,
        ),
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }
}
