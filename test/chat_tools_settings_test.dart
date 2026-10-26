import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/chat_tool.dart';
import 'package:maichat/screens/settings/chat_tools_page.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final width in [320.0, 600.0]) {
    for (final scale in [1.0, 1.5]) {
      testWidgets(
        'run-limit labels remain readable at width $width and scale $scale',
        (tester) async {
          tester.view
            ..physicalSize = Size(width, 1000)
            ..devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          SharedPreferences.setMockInitialValues({});
          final state = AppState();
          await tester.runAsync(state.init);
          await tester.pumpWidget(
            ChangeNotifierProvider.value(
              value: state,
              child: MaterialApp(
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: const ChatToolsPage(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.getSize(find.text('Follow-up rounds')).width,
            greaterThan(100),
          );
          expect(
            tester.getSize(find.text('Follow-up rounds')).height,
            lessThan(80),
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          state.dispose();
        },
      );
    }
  }
  testWidgets('global tool switch saves and survives reopening settings', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState();
    await tester.runAsync(state.init);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: ChatToolsPage()),
      ),
    );
    expect(find.text('Tool calls'), findsOneWidget);
    expect(state.chatToolConfigFor(null).enabled, isFalse);
    await tester.tap(find.text('Enable tool calls'));
    await tester.pumpAndSettle();
    expect(state.chatToolConfigFor(null).enabled, isTrue);
    final restored = AppState();
    await tester.runAsync(restored.init);
    expect(restored.chatToolConfigFor(null).enabled, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    restored.dispose();
  });

  testWidgets('chat settings overrides preserve global defaults', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState();
    await tester.runAsync(state.init);
    await tester.runAsync(
      () => state.saveChatToolConfig(const ChatToolConfig(enabled: true)),
    );
    final chat = state.active;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(home: ChatToolsPage(conversationId: chat.id)),
      ),
    );
    await tester.tap(find.text('Enable tool calls'));
    await tester.pumpAndSettle();
    expect(state.chatToolConfigFor(chat).enabled, isFalse);
    expect(state.chatToolConfigFor(null).enabled, isTrue);
    await tester.tap(find.byTooltip('Follow app defaults'));
    await tester.pumpAndSettle();
    expect(chat.chatToolConfig, isNull);
    expect(state.chatToolConfigFor(chat).enabled, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
}
