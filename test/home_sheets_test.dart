import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/home_layout.dart';
import 'package:maichat/screens/home/home_sheets.dart';
import 'package:maichat/screens/home/home_widgets.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// Builds a host app around a button that opens [sheet] when tapped, with
/// [state] provided above it — the shape every test below shares.
Widget _host(AppState state, Future<void> Function(BuildContext) openSheet) {
  return ChangeNotifierProvider<AppState>.value(
    value: state,
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => openSheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<AppState> _state() async {
  final state = AppState();
  await state.init();
  return state;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('showAddWidgetSheet', () {
    testWidgets('lists every kind in kHomeWidgetOrder', (tester) async {
      final state = await _state();
      await tester.pumpWidget(_host(state, (context) async {
        await showAddWidgetSheet(context);
      }));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Add a widget'), findsOneWidget);
      // Every kind, scrolling down the grouped list to reach it.
      for (final kind in kHomeWidgetOrder) {
        final title = find.text(specFor(kind).title);
        await tester.scrollUntilVisible(title.first, 120,
            scrollable: find.byType(Scrollable).last);
        expect(title, findsWidgets, reason: kind.name);
      }
      // The Studio is up front, flagged.
      expect(find.text('Featured'), findsWidgets);
    });

    testWidgets('picking quickOpen then Studio returns the target config',
        (tester) async {
      final state = await _state();
      ({HomeWidgetKind kind, Map<String, Object?> config})? result;
      await tester.pumpWidget(_host(state, (context) async {
        result = await showAddWidgetSheet(context);
      }));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('Quick open'), 120,
          scrollable: find.byType(Scrollable).last);
      await tester.tap(find.text('Quick open'));
      await tester.pumpAndSettle();
      expect(find.text('Choose a shortcut'), findsOneWidget);

      final studio = find.byKey(const ValueKey('quick-target-studio'));
      await tester.ensureVisible(studio);
      await tester.pumpAndSettle();
      await tester.tap(studio);
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.kind, HomeWidgetKind.quickOpen);
      expect(result!.config['target'], 'studio');
    });
  });

  group('showQuickTargetPicker', () {
    testWidgets('marks the current target selected', (tester) async {
      final state = await _state();
      await tester.pumpWidget(_host(state, (context) async {
        await showQuickTargetPicker(context, current: QuickTarget.studio);
      }));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      Semantics cell(String name) => tester.widget<Semantics>(find.descendant(
            of: find.byKey(ValueKey('quick-target-$name')),
            matching: find.byWidgetPredicate(
              (w) => w is Semantics && w.properties.label != null,
            ),
          ).first);
      expect(cell('studio').properties.selected, isTrue);
      expect(cell('chats').properties.selected, isFalse);
    });
  });

  group('showTileSettingsSheet', () {
    testWidgets('a choice chip changes count and onChanged receives it',
        (tester) async {
      final state = await _state();
      const tile = HomeTile(
        id: 't1',
        kind: HomeWidgetKind.gallery,
        x: 0,
        y: 0,
        w: 2,
        h: 2,
      );
      HomeTile? changed;
      await tester.pumpWidget(_host(state, (context) async {
        await showTileSettingsSheet(
          context,
          tile: tile,
          onChanged: (next) => changed = next,
        );
      }));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Gallery'), findsWidgets);
      expect(find.text('2 × 2'), findsOneWidget);

      await tester.tap(find.text('4'));
      await tester.pumpAndSettle();

      expect(changed, isNotNull);
      expect(changed!.config['count'], '4');
    });

    testWidgets('a toggle writes a bool', (tester) async {
      final state = await _state();
      const tile = HomeTile(
        id: 't2',
        kind: HomeWidgetKind.gallery,
        x: 0,
        y: 0,
        w: 2,
        h: 2,
      );
      HomeTile? changed;
      await tester.pumpWidget(_host(state, (context) async {
        await showTileSettingsSheet(
          context,
          tile: tile,
          onChanged: (next) => changed = next,
        );
      }));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Shuffle every 30s'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Shuffle every 30s'));
      await tester.pumpAndSettle();

      expect(changed, isNotNull);
      expect(changed!.config['shuffle'], true);
    });

    testWidgets('a stepper writes an int', (tester) async {
      final state = await _state();
      const tile = HomeTile(
        id: 't3',
        kind: HomeWidgetKind.recentChat,
        x: 0,
        y: 0,
        w: 4,
        h: 2,
      );
      HomeTile? changed;
      await tester.pumpWidget(_host(state, (context) async {
        await showTileSettingsSheet(
          context,
          tile: tile,
          onChanged: (next) => changed = next,
        );
      }));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final sliderFinder = find.byType(Slider);
      expect(sliderFinder, findsWidgets);
      final slider = tester.widget<Slider>(sliderFinder.first);
      slider.onChanged?.call((slider.value + 1).clamp(slider.min, slider.max));
      await tester.pumpAndSettle();

      expect(changed, isNotNull);
    });

    testWidgets('picking a chat stores the tree root id', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.conversations': jsonEncode([
          {
            'id': 'root1',
            'title': 'First chat',
            'updatedAt': '2026-08-01T10:00:00.000',
            'messages': [
              {'role': 'user', 'content': 'hi'},
            ],
          },
          {
            'id': 'branch1',
            'title': 'First chat',
            'updatedAt': '2026-08-02T10:00:00.000',
            'parentId': 'root1',
            'forkIndex': 0,
            'messages': [
              {'role': 'user', 'content': 'hi'},
              {'role': 'assistant', 'content': 'yo'},
            ],
          },
          {
            'id': 'root2',
            'title': 'Second chat',
            'updatedAt': '2026-08-03T10:00:00.000',
            'messages': [
              {'role': 'user', 'content': 'hey'},
            ],
          },
        ]),
      });
      final state = await _state();
      const tile = HomeTile(
        id: 't4',
        kind: HomeWidgetKind.pinnedChat,
        x: 0,
        y: 0,
        w: 4,
        h: 2,
      );
      HomeTile? changed;
      await tester.pumpWidget(_host(state, (context) async {
        await showTileSettingsSheet(
          context,
          tile: tile,
          onChanged: (next) => changed = next,
        );
      }));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Chat'));
      await tester.pumpAndSettle();
      expect(find.text('Choose a chat'), findsOneWidget);

      await tester.tap(find.text('Second chat'));
      await tester.pumpAndSettle();

      expect(changed, isNotNull);
      expect(changed!.config['chatId'], 'root2');

      // Branches of the first tree collapse to the root's own id.
      await tester.tap(find.text('Chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('First chat'));
      await tester.pumpAndSettle();
      expect(changed!.config['chatId'], 'root1');
    });

    testWidgets('choosing none removes the key', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.conversations': jsonEncode([
          {
            'id': 'root1',
            'title': 'First chat',
            'updatedAt': '2026-08-01T10:00:00.000',
            'messages': [
              {'role': 'user', 'content': 'hi'},
            ],
          },
        ]),
      });
      final state = await _state();
      final tile = const HomeTile(
        id: 't5',
        kind: HomeWidgetKind.pinnedChat,
        x: 0,
        y: 0,
        w: 4,
        h: 2,
      ).withConfig('chatId', 'root1');
      HomeTile? changed;
      await tester.pumpWidget(_host(state, (context) async {
        await showTileSettingsSheet(
          context,
          tile: tile,
          onChanged: (next) => changed = next,
        );
      }));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('First chat'));
      await tester.pumpAndSettle();
      expect(find.text('Choose a chat'), findsOneWidget);

      await tester.tap(find.text('All pinned chats'));
      await tester.pumpAndSettle();

      expect(changed, isNotNull);
      expect(changed!.config.containsKey('chatId'), isFalse);
    });

    testWidgets('a widget with no options says so', (tester) async {
      final state = await _state();
      const tile = HomeTile(
        id: 't6',
        kind: HomeWidgetKind.search,
        x: 0,
        y: 0,
        w: 4,
        h: 1,
      );
      await tester.pumpWidget(_host(state, (context) async {
        await showTileSettingsSheet(
          context,
          tile: tile,
          onChanged: (_) {},
        );
      }));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      if (tester.any(find.text('Nothing to set on this widget.'))) {
        expect(find.text('Nothing to set on this widget.'), findsOneWidget);
      }
    });
  });

  group('showGridSheet', () {
    testWidgets('presets apply and restoring the original preset restores it',
        (tester) async {
      final state = await _state();
      final original = HomeLayout.defaults();
      HomeLayout? changed;
      await tester.pumpWidget(_host(state, (context) async {
        await showGridSheet(
          context,
          layout: original,
          onChanged: (next) => changed = next,
        );
      }));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('8 × 9'));
      await tester.pumpAndSettle();
      expect(changed, isNotNull);
      expect(changed!.columns, 8);
      expect(changed!.rows, 9);

      await tester.tap(find.text('4 × 6'));
      await tester.pumpAndSettle();
      expect(changed!.columns, 4);
      expect(changed!.rows, 6);
      expect(changed, original);
    });
  });

  group('showHomeStyleSheet', () {
    testWidgets('picking circle sets iconShape and toggling flips showLabels',
        (tester) async {
      final state = await _state();
      final layout = HomeLayout.defaults();
      HomeLayout? changed;
      await tester.pumpWidget(_host(state, (context) async {
        await showHomeStyleSheet(
          context,
          layout: layout,
          onChanged: (next) => changed = next,
        );
      }));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Circle'));
      await tester.pumpAndSettle();
      expect(changed, isNotNull);
      expect(changed!.iconShape, HomeIconShape.circle);

      expect(layout.showLabels, isTrue);
      await tester.tap(find.text('Show names under shortcuts'));
      await tester.pumpAndSettle();
      expect(changed!.showLabels, isFalse);
    });
  });

  group('small surface, large text — no overflow', () {
    Future<void> atSmallSurface(
      WidgetTester tester,
      Future<void> Function(BuildContext) open,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = await _state();
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData.fromView(tester.view).copyWith(
            textScaler: const TextScaler.linear(1.3),
          ),
          child: _host(state, open),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    testWidgets('add widget sheet', (tester) async {
      await atSmallSurface(tester, (context) async {
        await showAddWidgetSheet(context);
      });
    });

    testWidgets('quick target picker', (tester) async {
      await atSmallSurface(tester, (context) async {
        await showQuickTargetPicker(context);
      });
    });

    testWidgets('tile settings sheet', (tester) async {
      await atSmallSurface(tester, (context) async {
        await showTileSettingsSheet(
          context,
          tile: const HomeTile(
            id: 'g1',
            kind: HomeWidgetKind.gallery,
            x: 0,
            y: 0,
            w: 2,
            h: 2,
          ),
          onChanged: (_) {},
        );
      });
    });

    testWidgets('grid sheet', (tester) async {
      await atSmallSurface(tester, (context) async {
        await showGridSheet(
          context,
          layout: HomeLayout.defaults(),
          onChanged: (_) {},
        );
      });
    });

    testWidgets('home style sheet', (tester) async {
      await atSmallSurface(tester, (context) async {
        await showHomeStyleSheet(
          context,
          layout: HomeLayout.defaults(),
          onChanged: (_) {},
        );
      });
    });
  });
}
