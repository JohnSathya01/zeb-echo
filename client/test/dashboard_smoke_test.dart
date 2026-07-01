import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zeb_echo_client/features/dashboard/dashboard_screen.dart';
import 'package:zeb_echo_client/theme/app_theme.dart';

void main() {
  testWidgets('Dashboard builds and renders panels in fake mode',
      (tester) async {
    // zeb Echo is a desktop app; size the test surface to a realistic desktop
    // window so the top-bar layout matches real use (default 800x600 is below
    // the intended minimum width).
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // No backend, no audio hardware — relies on the default fake services
    // (CLAUDE.md §8).
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const DashboardScreen(),
        ),
      ),
    );

    // Let the fake connect() future settle.
    await tester.pump(const Duration(milliseconds: 300));

    // Brand wordmark: "Echo" with a "powered by zeb" tagline beneath.
    expect(find.text('Echo'), findsOneWidget);
    expect(find.text('powered by zeb'), findsOneWidget);
    expect(find.text('LIVE TRANSCRIPT'), findsOneWidget);
    expect(find.text('DETECTED QUESTIONS'), findsOneWidget);
    expect(find.text('AI RESPONSE'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);

    // Phase 3: tab switcher + auto/manual toggle are present.
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Knowledge Base'), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Manual'), findsOneWidget);
  });

  testWidgets('Knowledge Base tab opens and shows the editor', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const DashboardScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // Switch to the Knowledge Base tab.
    await tester.tap(find.text('Knowledge Base'));
    await tester.pump(const Duration(milliseconds: 300));

    // The KB panel header + a Save button should now be visible.
    expect(find.text('KNOWLEDGE BASE'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });
}
