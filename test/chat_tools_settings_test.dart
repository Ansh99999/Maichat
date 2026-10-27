import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/chat_tool.dart';
import 'package:maichat/screens/settings/chat_tools_page.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // The readability loop: the run-limit sliders live one screen deeper now
  // (the Tools settings sub-screen), so what this page itself must keep
  // readable is the search bar, the tag row and the tool rows.
  for (final width in [320.0, 600.0]) {
    for (final scale in [1.0, 1.5]) {
      testWidgets(
        'tools list remains readable at width $width and scale $scale',
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
          expect(find.byKey(const Key('chat-tools-search')), findsOneWidget);
          await _scrollToTool(tester, 'roll_dice');
          expect(
            find.byKey(const Key('chat-tool-toggle-roll_dice')),
            findsOneWidget,
          );
          expect(tester.getSize(find.text('Roll Dice')).height, lessThan(80));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          state.dispose();
        },
      );
    }
  }

  group('the app-wide page', () {
    testWidgets('has the Tools title, info and settings buttons', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      await tester.runAsync(state.init);
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      expect(find.text('Tools'), findsOneWidget);
      expect(find.byTooltip('About tools'), findsOneWidget);
      expect(find.byTooltip('Tools settings'), findsOneWidget);
      expect(find.byTooltip('Import'), findsNothing);
      expect(find.byTooltip('Export'), findsNothing);
      state.dispose();
    });

    testWidgets('every built-in tool is listed once with a toggle', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      await tester.runAsync(state.init);
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      // Ten shipped built-ins, all visible with the default search/tags. The
      // list builds lazily and the helper only scrolls downward, so the
      // position resets to the top before each lookup.
      final expected = [
        'roll_dice',
        'random_integer',
        'read_trackers',
        'define_tracker',
        'update_tracker',
        'set_prompt_injection',
        'generate_image',
        'list_tools',
        'save_tool',
        'delete_tool',
      ];
      final scroll = tester
          .state<ScrollableState>(
            find.byWidgetPredicate(
              (w) => w is Scrollable && w.axis == Axis.vertical,
            ),
          )
          .position;
      for (final name in expected) {
        scroll.jumpTo(0);
        await tester.pumpAndSettle();
        await _scrollToTool(tester, name);
        expect(
          find.byKey(Key('chat-tool-toggle-$name')),
          findsOneWidget,
          reason: '$name should be listed',
        );
      }
      state.dispose();
    });

    testWidgets('row toggle writes the disabled list and survives restart', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      await tester.runAsync(state.init);
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      expect(state.chatToolConfigFor(null).disabledTools, isEmpty);
      await _scrollToTool(tester, 'roll_dice');
      await tester.tap(find.byKey(const Key('chat-tool-toggle-roll_dice')));
      await tester.pumpAndSettle();
      expect(
        state.chatToolConfigFor(null).disabledTools,
        contains('roll_dice'),
      );

      final restored = AppState();
      await tester.runAsync(restored.init);
      expect(
        restored.chatToolConfigFor(null).disabledTools,
        contains('roll_dice'),
      );
      state.dispose();
      restored.dispose();
    });

    testWidgets('search filters by name and description', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      await tester.runAsync(state.init);
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('chat-tools-search')),
        'dice',
      );
      await tester.pumpAndSettle();
      // A single match is on screen by itself.
      expect(
        find.byKey(const Key('chat-tool-toggle-roll_dice')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('chat-tool-toggle-read_trackers')),
        findsNothing,
      );

      await tester.enterText(find.byKey(const Key('chat-tools-search')), 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('No tools match "zzz"'), findsOneWidget);
      state.dispose();
    });

    testWidgets('tag filters narrow the list', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      await tester.runAsync(state.init);
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      // The tag chips sit in a horizontal scroller; make sure the one under
      // test is on screen before tapping it (the tag row is the first
      // horizontal scrollable on the page).
      final chip = find.byKey(const Key('chat-tools-tag-Trackers'));
      await tester.scrollUntilVisible(
        chip,
        50,
        scrollable: find
            .byWidgetPredicate(
              (w) => w is Scrollable && w.axis == Axis.horizontal,
            )
            .first,
      );
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('chat-tool-toggle-read_trackers')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('chat-tool-toggle-roll_dice')), findsNothing);

      await tester.scrollUntilVisible(
        chip,
        50,
        scrollable: find
            .byWidgetPredicate(
              (w) => w is Scrollable && w.axis == Axis.horizontal,
            )
            .first,
      );
      await tester.tap(chip);
      await tester.pumpAndSettle();
      await _scrollToTool(tester, 'roll_dice');
      expect(
        find.byKey(const Key('chat-tool-toggle-roll_dice')),
        findsOneWidget,
      );
      state.dispose();
    });

    testWidgets('sort by Kind groups built-ins by category', (tester) async {
      tester.view
        ..physicalSize = const Size(800, 2400)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      await tester.runAsync(state.init);
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      // Under Kind sort the tags order rules, so the three Trackers tools
      // come before the Random ones. Compare by on-screen y position of the
      // rows once they are built (scrolling resets between lookups).
      await tester.tap(find.byKey(const Key('chat-tools-sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kind').last);
      await tester.pumpAndSettle();

      Future<double> topOf(String name) async {
        final scroll = tester
            .state<ScrollableState>(
              find.byWidgetPredicate(
                (w) => w is Scrollable && w.axis == Axis.vertical,
              ),
            )
            .position;
        scroll.jumpTo(0);
        await tester.pumpAndSettle();
        await _scrollToTool(tester, name);
        return scroll.pixels +
            tester.getTopLeft(find.byKey(Key('chat-tool-toggle-$name'))).dy;
      }

      final readTrackers = await topOf('read_trackers');
      final updateTrackers = await topOf('update_tracker');
      final randomInteger = await topOf('random_integer');
      expect(updateTrackers, greaterThan(readTrackers));
      expect(randomInteger, lessThan(readTrackers));
      state.dispose();
    });
  });

  group('the settings sub-screen', () {
    testWidgets('holds the master switch, hide switch and run limits', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      await tester.runAsync(state.init);
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Tools settings'));
      await tester.pumpAndSettle();

      // Everything above the fold.
      expect(find.text('Tools settings'), findsOneWidget);
      expect(find.text('Enable tool calls'), findsOneWidget);
      expect(find.text('Hide tool calls in chat'), findsOneWidget);
      expect(find.text('Follow-up rounds'), findsOneWidget);
      expect(find.text('Total tool calls'), findsOneWidget);
      // Everything below it: scroll the options list to the bottom.
      final options = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byKey(const Key('chat-tools-options-list')),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      options.jumpTo(options.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('Below the reply'), findsOneWidget);
      expect(find.text('Create a custom tool'), findsOneWidget);
      expect(find.text('Import tools'), findsOneWidget);
      expect(find.text('Export tools'), findsOneWidget);
      state.dispose();
    });

    testWidgets('the master switch saves and survives reopening', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      await tester.runAsync(state.init);
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Tools settings'));
      await tester.pumpAndSettle();
      expect(state.chatToolConfigFor(null).enabled, isFalse);
      await tester.tap(find.text('Enable tool calls'));
      await tester.pumpAndSettle();
      expect(state.chatToolConfigFor(null).enabled, isTrue);

      final restored = AppState();
      await tester.runAsync(restored.init);
      expect(restored.chatToolConfigFor(null).enabled, isTrue);
      state.dispose();
      restored.dispose();
    });

    testWidgets('the hide switch writes hideToolCallsInChat', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      await tester.runAsync(state.init);
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Tools settings'));
      await tester.pumpAndSettle();
      expect(state.chatToolConfigFor(null).hideToolCallsInChat, isFalse);
      await tester.tap(find.text('Hide tool calls in chat'));
      await tester.pumpAndSettle();
      expect(state.chatToolConfigFor(null).hideToolCallsInChat, isTrue);
      state.dispose();
    });
  });

  group('the per-chat page', () {
    testWidgets('chat settings override globals and can follow app defaults', (
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
      await tester.pumpAndSettle();

      // The chat page defaults to the inherited global switch.
      expect(state.chatToolConfigFor(chat).enabled, isTrue);

      await tester.tap(find.byTooltip('Tools settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enable tool calls'));
      await tester.pumpAndSettle();
      expect(state.chatToolConfigFor(chat).enabled, isFalse);
      expect(
        state.chatToolConfigFor(null).enabled,
        isTrue,
        reason: 'the global library is untouched',
      );

      // "Follow app defaults" sits below the fold on the options screen.
      final options = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byKey(const Key('chat-tools-options-list')),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      options.jumpTo(options.maxScrollExtent);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Follow app defaults'));
      await tester.pumpAndSettle();
      expect(chat.chatToolConfig, isNull);
      expect(state.chatToolConfigFor(chat).enabled, isTrue);
      state.dispose();
    });

    testWidgets('a row toggle writes the chat copy, not the global one', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      await tester.runAsync(state.init);
      final chat = state.active;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(home: ChatToolsPage(conversationId: chat.id)),
        ),
      );
      await tester.pumpAndSettle();

      await _scrollToTool(tester, 'roll_dice');
      await tester.tap(find.byKey(const Key('chat-tool-toggle-roll_dice')));
      await tester.pumpAndSettle();
      expect(
        state.chatToolConfigFor(chat).disabledTools,
        contains('roll_dice'),
      );
      expect(
        state.chatToolConfigFor(null).disabledTools,
        isEmpty,
        reason: 'global library untouched',
      );
      state.dispose();
    });
  });

  group('the action strip', () {
    testWidgets('narrow screens need a slide to reach Follow up', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(320, 1000)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      await tester.runAsync(state.init);
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _scrollToTool(tester, 'delete_tool');
      // The strip holds all four, but at 320 logical px the fourth chip
      // (Follow up) sits beyond the strip's viewport: not tappable until
      // the strip is slid left.
      final followUp = find.descendant(
        of: find.byKey(const Key('chat-tool-row-delete_tool')),
        matching: find.byKey(const Key('chat-tool-action-followup')),
      );
      final viewport = tester.getRect(
        find.byKey(const Key('chat-tool-strip-delete_tool')),
      );
      expect(followUp.hitTestable(), findsNothing);

      // Slide the delete_tool row's strip to its end, as a finger drag does.
      final strip = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byKey(const Key('chat-tool-strip-delete_tool')),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      expect(strip.maxScrollExtent, greaterThan(0));
      await tester.drag(
        find.byKey(const Key('chat-tool-strip-delete_tool')),
        const Offset(-500, 0),
      );
      await tester.pumpAndSettle();
      expect(viewport.contains(tester.getCenter(followUp)), isTrue);
      state.dispose();
    });

    testWidgets('wide screens show all four actions directly', (tester) async {
      tester.view
        ..physicalSize = const Size(800, 1000)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      await tester.runAsync(state.init);
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _scrollToTool(tester, 'roll_dice');
      final followUp = find.descendant(
        of: find.byKey(const Key('chat-tool-row-roll_dice')),
        matching: find.byKey(const Key('chat-tool-action-followup')),
      );
      expect(
        tester
            .getRect(find.byKey(const Key('chat-tool-strip-roll_dice')))
            .contains(tester.getCenter(followUp)),
        isTrue,
      );
      expect(find.text('Inspect'), findsWidgets);
      expect(find.text('Test'), findsWidgets);
      expect(find.text('Duplicate'), findsWidgets);
      state.dispose();
    });
    testWidgets(
      'built-in follow up changes behavior without creating a custom tool',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final state = AppState();
        await tester.runAsync(state.init);
        await tester.pumpWidget(_host(state));
        await tester.pumpAndSettle();
        await _scrollToTool(tester, 'roll_dice');
        final strip = tester
            .state<ScrollableState>(
              find
                  .descendant(
                    of: find.byKey(const Key('chat-tool-strip-roll_dice')),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            )
            .position;
        strip.jumpTo(strip.maxScrollExtent);
        await tester.pumpAndSettle();
        final row = find.byKey(const Key('chat-tool-row-roll_dice'));
        final followUp = find.descendant(
          of: row,
          matching: find.byKey(const Key('chat-tool-action-followup')),
        );
        await tester.tap(followUp);
        await tester.pumpAndSettle();
        expect(state.chatToolConfigFor(null).customTools, isEmpty);
        expect(
          state
              .chatToolDefinitionsFor(null)
              .singleWhere((t) => t.name == 'roll_dice')
              .followUp,
          isFalse,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        final restored = AppState();
        await tester.runAsync(restored.init);
        expect(
          restored
              .chatToolDefinitionsFor(null)
              .singleWhere((t) => t.name == 'roll_dice')
              .followUp,
          isFalse,
        );
        state.dispose();
        restored.dispose();
      },
    );

    testWidgets('follow up toggles a custom tool definition', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      await tester.runAsync(state.init);
      await tester.runAsync(
        () => state.saveChatToolConfig(
          const ChatToolConfig(
            customTools: [
              ChatToolDefinition(
                name: 'my_encounter',
                description: 'Rolls a custom encounter.',
                action: {
                  'call': 'roll_dice',
                  'arguments': {
                    'formula': {'template': '1d20'},
                  },
                },
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      // Scroll to the custom tool's row and slide its strip fully left so
      // its Follow up chip is reachable.
      await _scrollToTool(tester, 'my_encounter');
      final row = find.byKey(const Key('chat-tool-toggle-my_encounter'));
      final rowCenter = tester.getCenter(row);
      final strip = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byKey(const Key('chat-tool-strip-my_encounter')),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      strip.jumpTo(strip.maxScrollExtent);
      await tester.pumpAndSettle();

      final before = state
          .chatToolConfigFor(null)
          .customTools
          .firstWhere((t) => t.name == 'my_encounter')
          .followUp;
      // The chip belonging to this row: the hittable Follow up chip nearest
      // the row's centre.
      final chips = find
          .byKey(const Key('chat-tool-action-followup'))
          .hitTestable(at: Alignment.center);
      final chipCenters = [
        for (final c in chips.evaluate())
          (c.findRenderObject()! as RenderBox).localToGlobal(Offset.zero) +
              Offset(
                (c.findRenderObject()! as RenderBox).size.width / 2,
                (c.findRenderObject()! as RenderBox).size.height / 2,
              ),
      ];
      var best = 0;
      var bestDistance = double.infinity;
      for (var i = 0; i < chipCenters.length; i++) {
        final d = (chipCenters[i] - rowCenter).distance;
        if (d < bestDistance) {
          bestDistance = d;
          best = i;
        }
      }
      await tester.tap(chips.at(best));
      await tester.pumpAndSettle();

      final after = state
          .chatToolConfigFor(null)
          .customTools
          .firstWhere((t) => t.name == 'my_encounter')
          .followUp;
      expect(after, isNot(before));
      state.dispose();
    });
  });

  group('the full-screen editor', () {
    testWidgets('tapping a built-in opens a read-only view with Duplicate', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      await tester.runAsync(state.init);
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _scrollToTool(tester, 'roll_dice');
      await tester.tap(find.text('Roll Dice'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('chat-tool-editor-duplicate')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('chat-tool-editor-name')), findsNothing);
      expect(find.text('Parameters'), findsOneWidget);
      state.dispose();
    });

    testWidgets(
      'creating a custom tool seeds the defaults and saves through the page',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final state = AppState();
        await tester.runAsync(state.init);
        await tester.pumpWidget(_host(state));
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Tools settings'));
        await tester.pumpAndSettle();
        // The create button sits below the fold on the options screen.
        final options = tester
            .state<ScrollableState>(
              find
                  .descendant(
                    of: find.byKey(const Key('chat-tools-options-list')),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            )
            .position;
        options.jumpTo(options.maxScrollExtent);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Create a custom tool'));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('chat-tool-editor-name')), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('chat-tool-editor-name')))
              .controller!
              .text,
          isEmpty,
        );
        await tester.enterText(
          find.byKey(const Key('chat-tool-editor-name')),
          'my_luck',
        );
        await tester.enterText(
          find.byKey(const Key('chat-tool-editor-description')),
          'Lucky rolls.',
        );
        final editorList = tester
            .state<ScrollableState>(
              find
                  .descendant(
                    of: find.byKey(const Key('chat-tool-editor-list')),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            )
            .position;
        editorList.jumpTo(editorList.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(
                find.byKey(const Key('chat-tool-editor-action')),
              )
              .controller!
              .text,
          contains('roll_dice'),
        );
        await tester.tap(find.byKey(const Key('chat-tool-editor-save')));
        await tester.pumpAndSettle();

        final saved = state
            .chatToolConfigFor(null)
            .customTools
            .where((t) => t.name == 'my_luck')
            .toList();
        expect(saved, hasLength(1));
        expect(saved.single.description, 'Lucky rolls.');
        expect(saved.single.followUp, isTrue);
        state.dispose();
      },
    );

    testWidgets('editing a custom tool keeps its name out of the clash set', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      await tester.runAsync(state.init);
      await tester.runAsync(
        () => state.saveChatToolConfig(
          const ChatToolConfig(
            customTools: [
              ChatToolDefinition(
                name: 'my_encounter',
                description: 'Rolls a custom encounter.',
                action: {
                  'call': 'roll_dice',
                  'arguments': {
                    'formula': {'template': '1d20'},
                  },
                },
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _scrollToTool(tester, 'my_encounter');
      await tester.tap(find.text('My Encounter'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-tool-editor-name')), findsOneWidget);
      // Rename to something fresh and save.
      await tester.enterText(
        find.byKey(const Key('chat-tool-editor-name')),
        'my_battle',
      );
      await tester.tap(find.byKey(const Key('chat-tool-editor-save')));
      await tester.pumpAndSettle();

      final names = state
          .chatToolConfigFor(null)
          .customTools
          .map((t) => t.name)
          .toSet();
      expect(names, contains('my_battle'));
      expect(names, isNot(contains('my_encounter')));
      state.dispose();
    });

    testWidgets('delete asks first and removes the definition', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      await tester.runAsync(state.init);
      await tester.runAsync(
        () => state.saveChatToolConfig(
          const ChatToolConfig(
            customTools: [
              ChatToolDefinition(
                name: 'my_encounter',
                description: 'Rolls a custom encounter.',
                action: {
                  'call': 'roll_dice',
                  'arguments': {
                    'formula': {'template': '1d20'},
                  },
                },
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _scrollToTool(tester, 'my_encounter');
      await tester.tap(find.text('My Encounter'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byKey(const Key('chat-tool-editor-delete')),
        250,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('chat-tool-editor-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(
        find.byKey(const Key('chat-tool-editor-delete')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat-tool-editor-delete')));
      await tester.pumpAndSettle();
      expect(find.text('Delete My Encounter?'), findsOneWidget);
      // Cancel keeps the tool.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        state.chatToolConfigFor(null).customTools.map((t) => t.name),
        contains('my_encounter'),
      );

      await tester.scrollUntilVisible(
        find.byKey(const Key('chat-tool-editor-delete')),
        250,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('chat-tool-editor-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(
        find.byKey(const Key('chat-tool-editor-delete')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat-tool-editor-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();
      expect(
        state.chatToolConfigFor(null).customTools.map((t) => t.name),
        isNot(contains('my_encounter')),
      );
      state.dispose();
    });
  });
}

Widget _host(AppState state) => ChangeNotifierProvider.value(
  value: state,
  child: const MaterialApp(home: ChatToolsPage()),
);

/// Scrolls the tool list until [name]'s row is built and visible. The list
/// is the page's only vertical scrollable — the tag row and the strip inside
/// a row are horizontal ones.
Future<void> _scrollToTool(WidgetTester tester, String name) async {
  final list = find.byWidgetPredicate(
    (w) => w is Scrollable && w.axis == Axis.vertical,
  );
  final row = find.byKey(Key('chat-tool-row-$name'));
  await tester.scrollUntilVisible(row, 100, scrollable: list);
  await tester.pumpAndSettle();
  await Scrollable.ensureVisible(tester.element(row), alignment: .5);
  await tester.pumpAndSettle();
}
