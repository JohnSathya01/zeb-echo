import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/providers.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_theme.dart';

/// Top-bar tab switcher: **Dashboard | Knowledge Base** (Phase 3). A compact
/// segmented control; the active tab uses the lime accent (sparingly, per §5).
class TabSwitcher extends ConsumerWidget {
  const TabSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedTabProvider);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.backgroundBlack,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _TabButton(
            label: 'Dashboard',
            icon: Icons.dashboard_outlined,
            active: selected == AppTab.dashboard,
            onTap: () =>
                ref.read(selectedTabProvider.notifier).state = AppTab.dashboard,
          ),
          const SizedBox(width: 2),
          _TabButton(
            label: 'Knowledge Base',
            icon: Icons.menu_book_outlined,
            active: selected == AppTab.knowledgeBase,
            onTap: () => ref.read(selectedTabProvider.notifier).state =
                AppTab.knowledgeBase,
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = active ? AppColors.onAccent : AppColors.textSecondary;
    return Material(
      color: active ? AppColors.accent : Colors.transparent,
      borderRadius: BorderRadius.circular(AppTheme.radius - 3),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radius - 3),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.spaceMd,
            vertical: AppTheme.spaceSm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
