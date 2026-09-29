import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/screens/studio/settings/studio_agents_page.dart';
import 'package:maichat/screens/studio/settings/studio_memory_page.dart';
import 'package:maichat/screens/studio/settings/studio_web_page.dart';
import 'package:maichat/services/studio/studio_memory.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// The Studio's knowledge settings: sub-agent types, memory, web research.
void main() {
  group('settings pages', () {
    late AppState state;

    Future<void> pump(WidgetTester tester, Widget page) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(home: page),
        ),
      );
      await tester.pumpAndSettle();
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      state = AppState();
      await state.init();
    });

    testWidgets('a new sub-agent type is saved into the settings', (
      tester,
    ) async {
      await pump(tester, const StudioAgentsPage());
      expect(find.text('Writer'), findsOneWidget);
      await tester.tap(find.byKey(const Key('studio-agent-new')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('studio-agent-label')),
        'Canon checker',
      );
      await tester.enterText(
        find.byKey(const Key('studio-agent-description')),
        'Checks the card against the wiki.',
      );
      await tester.pump();
      expect(find.text('Called "canon_checker" by the Studio'), findsOneWidget);
      await tester.dragUntilVisible(
        find.byKey(const Key('studio-agent-tools-web')),
        find.byType(ListView),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('studio-agent-tools-web')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('studio-agent-save')));
      await tester.pumpAndSettle();
      final saved = state.studioConfig.customAgents.single;
      expect(saved.id, 'canon_checker');
      expect(saved.toolGroups, {'read', 'web'});
      expect(find.text('Canon checker'), findsOneWidget);
    });

    testWidgets('a built-in can be read and copied', (tester) async {
      await pump(tester, const StudioAgentsPage());
      await tester.tap(find.text('Critic'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Playtest'), findsOneWidget);
      await tester.tap(find.byKey(const Key('studio-agent-duplicate')));
      await tester.pumpAndSettle();
      expect(find.text('My critic'), findsOneWidget);
    });

    testWidgets('the memory page lists, edits away and switches off', (
      tester,
    ) async {
      final dir = Directory.systemTemp.createTempSync('studio_memory_ui');
      addTearDown(() => dir.deleteSync(recursive: true));
      final memory = StudioMemory(File('${dir.path}/memory.md'), [
        'Short greetings',
        'No purple prose',
      ]);
      await pump(tester, StudioMemoryPage(memory: memory));
      expect(find.text('Short greetings'), findsOneWidget);
      expect(find.text('2 of $kStudioMemoryMaxNotes notes'), findsOneWidget);
      await tester.tap(find.byTooltip('Forget').first);
      await tester.pumpAndSettle();
      expect(memory.notes, ['No purple prose']);
      await tester.tap(find.byKey(const Key('studio-memory-switch')));
      await tester.pumpAndSettle();
      expect(state.studioConfig.memoryEnabled, isFalse);
      expect(find.byKey(const Key('studio-memory-add')), findsNothing);
      // The deletes wrote the file for real; let those writes land before the
      // folder goes (real I/O only moves when the real event loop runs).
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
    });

    testWidgets('web research can be switched off and pointed at Brave', (
      tester,
    ) async {
      await pump(tester, const StudioWebPage());
      await tester.tap(find.byKey(const Key('studio-search-brave')));
      await tester.pumpAndSettle();
      expect(state.studioConfig.searchProvider, StudioSearchProvider.brave);
      await tester.enterText(find.byKey(const Key('studio-search-key')), 'abc');
      await tester.tap(find.byKey(const Key('studio-web-switch')));
      await tester.pumpAndSettle();
      expect(state.studioConfig.webTools, isFalse);
      expect(find.byKey(const Key('studio-search-key')), findsNothing);
      // The key is kept as the page closes.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(state.studioConfig.searchKey, 'abc');
    });
  });
}
