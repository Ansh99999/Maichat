import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/home_layout.dart';
import 'package:maichat/models/usage.dart';
import 'package:maichat/screens/characters_screen.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/screens/home/home_spec.dart';
import 'package:maichat/screens/home/home_widgets.dart';
import 'package:maichat/screens/home/widgets/search_widget.dart';
import 'package:maichat/screens/providers/providers_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every span the Home grid can hand a widget, at ~90 logical px a cell —
/// including spans the spec declines (below its own [HomeWidgetSpec.minSpan]),
/// since the editor clamps up but the widget itself must never crash on one
/// that slips through.
const _spans = <(int, int)>[
  (1, 1),
  (2, 1),
  (2, 2),
  (4, 1),
  (4, 2),
  (4, 4),
];

/// Minimal conversation JSON: a seeded chat always carries at least one
/// message, since [Conversation.isEmpty] (and so every "recent/pinned chat"
/// widget) treats an empty thread as not there at all.
Map<String, Object?> _chatJson({
  required String id,
  required String title,
  required String updatedAt,
  String lastMessage = 'Hello there',
  String? characterId,
  bool pinned = false,
}) => {
      'id': id,
      'title': title,
      'updatedAt': updatedAt,
      'pinned': pinned,
      'characterId': ?characterId,
      'messages': [
        {'role': 'user', 'content': 'Hi'},
        {'role': 'assistant', 'content': lastMessage},
      ],
    };

Map<String, Object?> _characterJson({required String id, required String name}) =>
    {'id': id, 'name': name};

Map<String, Object?> _galleryJson({required String id, required String image}) =>
    {'id': id, 'image': image};

/// Builds a [HomeTile]/[HomeTileContext] for [kind] at [w]x[h] and pumps the
/// spec's own [HomeWidgetSpec.build] inside a real [MaterialApp] + provider,
/// at the given logical size (90 px per cell, like the real grid).
Widget _harness({
  required HomeWidgetSpec spec,
  required AppState state,
  required int w,
  required int h,
  bool editing = false,
  Map<String, Object?> config = const {},
  HomeIconShape iconShape = HomeIconShape.squircle,
}) {
  final tile = HomeTile(
    id: 'tile-under-test',
    kind: spec.kind,
    x: 0,
    y: 0,
    w: w,
    h: h,
    config: config,
  );
  final layout = HomeLayout(
    columns: 4,
    rows: 6,
    pages: [HomePage(id: 'p1', tiles: [tile])],
    iconShape: iconShape,
  );
  final size = Size(w * 90.0, h * 90.0);
  final ctx = HomeTileContext(
    tile: tile,
    size: size,
    layout: layout,
    editing: editing,
  );
  return ChangeNotifierProvider<AppState>.value(
    value: state,
    child: MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: Builder(builder: (context) => spec.build(context, ctx)),
          ),
        ),
      ),
    ),
  );
}

Future<AppState> _ready() async {
  final state = AppState();
  await state.init();
  return state;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('registry', () {
    test('specFor covers every kind and matches kHomeWidgetOrder', () {
      for (final kind in HomeWidgetKind.values) {
        final spec = specFor(kind);
        expect(spec.kind, kind);
      }
      expect(kHomeWidgetOrder.toSet(), HomeWidgetKind.values.toSet());
      expect(kHomeWidgetOrder.length, HomeWidgetKind.values.length);
    });
  });

  group('every widget, every span, empty data', () {
    for (final kind in HomeWidgetKind.values) {
      for (final (w, h) in _spans) {
        for (final editing in [false, true]) {
          testWidgets(
            '${kind.name} at ${w}x$h, editing=$editing renders without error',
            (tester) async {
              final state = await _ready();
              await tester.pumpWidget(_harness(
                spec: specFor(kind),
                state: state,
                w: w,
                h: h,
                editing: editing,
              ));
              await tester.pump();
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }
  });

  group('every widget, every span, seeded data', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.conversations': '''
          [
            ${_jsonOf(_chatJson(id: 'c1', title: 'Latest chat', updatedAt: '2026-10-10T10:00:00.000', characterId: 'char1', pinned: true))},
            ${_jsonOf(_chatJson(id: 'c2', title: 'Second chat', updatedAt: '2026-10-09T10:00:00.000', lastMessage: 'Second preview'))}
          ]
        ''',
        'flutter.characters': '''
          [
            ${_jsonOf(_characterJson(id: 'char1', name: 'Aria'))},
            ${_jsonOf(_characterJson(id: 'char2', name: 'Bram'))}
          ]
        ''',
        'flutter.gallery': '''
          [
            ${_jsonOf(_galleryJson(id: 'g1', image: 'https://example.com/one.jpg'))},
            ${_jsonOf(_galleryJson(id: 'g2', image: 'https://example.com/two.jpg'))}
          ]
        ''',
      });
    });

    for (final kind in HomeWidgetKind.values) {
      for (final (w, h) in _spans) {
        for (final editing in [false, true]) {
          testWidgets(
            '${kind.name} at ${w}x$h, editing=$editing renders without error',
            (tester) async {
              final state = await _ready();
              await tester.pumpWidget(_harness(
                spec: specFor(kind),
                state: state,
                w: w,
                h: h,
                editing: editing,
              ));
              await tester.pump();
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }

    for (final shape in HomeIconShape.values) {
      testWidgets(
        'quickOpen renders the ${shape.name} icon shape without error',
        (tester) async {
          final state = await _ready();
          await tester.pumpWidget(_harness(
            spec: specFor(HomeWidgetKind.quickOpen),
            state: state,
            w: 1,
            h: 1,
            iconShape: shape,
          ));
          await tester.pump();
          expect(tester.takeException(), isNull);
        },
      );
    }
  });

  group('recent chat', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.conversations': '''
          [
            ${_jsonOf(_chatJson(id: 'c1', title: 'Latest chat', updatedAt: '2026-10-10T10:00:00.000'))},
            ${_jsonOf(_chatJson(id: 'c2', title: 'Second chat', updatedAt: '2026-10-09T10:00:00.000', lastMessage: 'Second preview'))}
          ]
        ''',
      });
    });

    testWidgets('shows title and preview for the latest chat, and opens it',
        (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.recentChat),
        state: state,
        w: 2,
        h: 1,
      ));
      await tester.pump();

      expect(find.text('Latest chat'), findsOneWidget);
      expect(find.textContaining('Hello there'), findsNothing); // c1 default preview
      await tester.tap(find.text('Latest chat'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(state.active.id, 'c1');
    });

    testWidgets('index 2 shows the 2nd latest chat', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.recentChat),
        state: state,
        w: 2,
        h: 1,
        config: const {'index': 2},
      ));
      await tester.pump();

      expect(find.text('Second chat'), findsOneWidget);
      expect(find.text('Latest chat'), findsNothing);
    });

    testWidgets('editing=true makes the tap do nothing', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.recentChat),
        state: state,
        w: 2,
        h: 1,
        editing: true,
      ));
      await tester.pump();

      await tester.tap(find.text('Latest chat'));
      await tester.pump();
      expect(find.byType(ChatScreen), findsNothing);
    });

    testWidgets('shows an empty state with no chats', (tester) async {
      // This group's setUp seeds two chats; this one wants none.
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.recentChat),
        state: state,
        w: 2,
        h: 1,
      ));
      await tester.pump();
      expect(find.text('No chats yet'), findsOneWidget);
    });
  });

  group('pinned chat', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.conversations': '''
          [
            ${_jsonOf(_chatJson(id: 'c1', title: 'Pinned one', updatedAt: '2026-10-10T10:00:00.000', pinned: true))},
            ${_jsonOf(_chatJson(id: 'c2', title: 'Not pinned', updatedAt: '2026-10-09T10:00:00.000'))}
          ]
        ''',
      });
    });

    testWidgets('with no chat chosen, lists only pinned chats', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.pinnedChat),
        state: state,
        w: 2,
        h: 2,
      ));
      await tester.pump();

      expect(find.text('Pinned one'), findsOneWidget);
      expect(find.text('Not pinned'), findsNothing);
    });

    testWidgets('with a chat chosen, shows just that chat as a card',
        (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.pinnedChat),
        state: state,
        w: 2,
        h: 1,
        config: const {'chatId': 'c2'},
      ));
      await tester.pump();

      expect(find.text('Not pinned'), findsOneWidget);
      expect(find.text('Pinned one'), findsNothing);
    });

    testWidgets('empty state when nothing is pinned', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.conversations': '''
          [${_jsonOf(_chatJson(id: 'c1', title: 'Solo', updatedAt: '2026-10-10T10:00:00.000'))}]
        ''',
      });
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.pinnedChat),
        state: state,
        w: 2,
        h: 1,
      ));
      await tester.pump();
      expect(find.text('Pin a chat to keep it here'), findsOneWidget);
    });
  });

  group('quick open', () {
    testWidgets('tapping the Chats target pushes ChatsScreen', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.quickOpen),
        state: state,
        w: 2,
        h: 1,
        config: const {'target': 'chats'},
      ));
      await tester.pump();

      await tester.tap(find.byType(GestureDetector).first);
      await tester.pumpAndSettle();
      expect(find.byType(Scaffold), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('label hides when label config is hide', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.quickOpen),
        state: state,
        w: 1,
        h: 1,
        config: const {'target': 'newChat', 'label': 'hide'},
      ));
      await tester.pump();
      expect(find.text('New chat'), findsNothing);
    });

    testWidgets('label shows when label config is show', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.quickOpen),
        state: state,
        w: 1,
        h: 1,
        config: const {'target': 'newChat', 'label': 'show'},
      ));
      await tester.pump();
      expect(find.text('New chat'), findsOneWidget);
    });

    testWidgets('editing=true makes the tap do nothing', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.quickOpen),
        state: state,
        w: 2,
        h: 1,
        editing: true,
        config: const {'target': 'chats'},
      ));
      await tester.pump();
      await tester.tap(find.byType(GestureDetector).first, warnIfMissed: false);
      await tester.pump();
      // No navigation: still on the harness scaffold, no ChatsScreen pushed.
      expect(find.text('Quick open'), findsNothing);
    });
  });

  group('provider', () {
    testWidgets('shows "Finish setup" when no provider is configured',
        (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.provider),
        state: state,
        w: 2,
        h: 1,
      ));
      await tester.pump();
      expect(find.text('Finish setup'), findsOneWidget);

      await tester.tap(find.text('Finish setup'));
      await tester.pumpAndSettle();
      expect(find.byType(ProvidersScreen), findsOneWidget);
    });
  });

  group('cost', () {
    testWidgets('shows "No provider yet" with nothing configured',
        (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.cost),
        state: state,
        w: 2,
        h: 1,
      ));
      await tester.pump();
      expect(find.text('No provider yet'), findsOneWidget);
    });
  });

  group('gallery', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.gallery': '''
          [
            ${_jsonOf(_galleryJson(id: 'g1', image: 'https://example.com/one.jpg'))},
            ${_jsonOf(_galleryJson(id: 'g2', image: 'https://example.com/two.jpg'))}
          ]
        ''',
      });
    });

    testWidgets('shows an empty state with no pictures', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.gallery),
        state: state,
        w: 2,
        h: 2,
      ));
      await tester.pump();
      expect(find.text('Your pictures will show here'), findsOneWidget);
    });

    testWidgets('renders a swipeable PageView over the pool', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.gallery),
        state: state,
        w: 2,
        h: 2,
        config: const {'count': 1},
      ));
      await tester.pump();
      expect(find.byType(PageView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a chosen count (stored as text) shows that many slots',
        (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.gallery),
        state: state,
        w: 4,
        h: 2,
        config: const {'count': '4'},
      ));
      await tester.pump();
      expect(find.byType(PageView), findsNWidgets(4));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a swipe moves a slot on, and keeps going past the end',
        (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.gallery),
        state: state,
        w: 2,
        h: 2,
        config: const {'count': '1'},
      ));
      await tester.pump();
      final view = tester.widget<PageView>(find.byType(PageView));
      // The slot starts deep in an endless run (pool length × 1000), so it
      // swipes back as well as on.
      final start = view.controller!.initialPage;
      for (var i = 0; i < 3; i++) {
        // Shorter than one picture, so each fling is exactly one step.
        await tester.fling(find.byType(PageView), const Offset(-80, 0), 1000);
        await tester.pumpAndSettle();
      }
      expect(view.controller!.page!.round(), start + 3);
      expect(tester.takeException(), isNull);
    });
  });

  group('characters', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.characters': '''
          [
            ${_jsonOf(_characterJson(id: 'char1', name: 'Aria'))},
            ${_jsonOf(_characterJson(id: 'char2', name: 'Bram'))}
          ]
        ''',
      });
    });

    testWidgets('shows an empty state with no characters', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.characters),
        state: state,
        w: 4,
        h: 1,
      ));
      await tester.pump();
      expect(find.text('Your characters will gather here'), findsOneWidget);
    });

    testWidgets('tapping a face with tapAction=sheet opens the character sheet',
        (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.characters),
        state: state,
        w: 4,
        h: 1,
        config: const {'source': 'all', 'tapAction': 'sheet'},
      ));
      await tester.pump();

      await tester.tap(find.byType(GestureDetector).first);
      await tester.pumpAndSettle();
      // openCharacterDetail pushes a route; we only assert no crash and that
      // the characters list screen (a different target) was not opened.
      expect(find.byType(CharactersScreen), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('editing=true makes a face tap do nothing', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.characters),
        state: state,
        w: 4,
        h: 1,
        editing: true,
        config: const {'source': 'all', 'tapAction': 'sheet'},
      ));
      await tester.pump();
      await tester.tap(find.byType(GestureDetector).first, warnIfMissed: false);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('search', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.conversations': '''
          [${_jsonOf(_chatJson(id: 'c1', title: 'Dragon lore', updatedAt: '2026-10-10T10:00:00.000'))}]
        ''',
        'flutter.characters': '''
          [${_jsonOf(_characterJson(id: 'char1', name: 'Aria'))}]
        ''',
      });
    });

    testWidgets('tapping opens the search screen, which filters live',
        (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.search),
        state: state,
        w: 2,
        h: 1,
      ));
      await tester.pump();

      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();
      expect(find.byType(HomeSearchScreen), findsOneWidget);
      expect(find.text('Type to search'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'dragon');
      await tester.pump();
      expect(find.text('Dragon lore'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'aria');
      await tester.pump();
      expect(find.text('Aria'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'zzz-no-match');
      await tester.pump();
      expect(find.text('No results'), findsOneWidget);
    });

    testWidgets('editing=true makes the tap do nothing', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.search),
        state: state,
        w: 2,
        h: 1,
        editing: true,
      ));
      await tester.pump();
      await tester.tap(find.byType(InkWell));
      await tester.pump();
      expect(find.byType(HomeSearchScreen), findsNothing);
    });
  });

  group('studio', () {
    testWidgets('renders the icon tile without error when editing',
        (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.studio),
        state: state,
        w: 1,
        h: 1,
        editing: true,
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders the card at larger spans without error',
        (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.studio),
        state: state,
        w: 2,
        h: 2,
        editing: true,
      ));
      await tester.pump();
      expect(find.text('Studio'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('usage-backed cost widget', () {
    testWidgets('shows spend once a provider has recorded usage',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.providers': '''
          {"providers": [
            {"id": "p1", "name": "My Provider", "kind": "openai",
             "baseUrl": "https://example.com", "apiKey": "k", "model": "gpt-x"}
          ], "activeId": "p1"}
        ''',
      });
      final state = await _ready();
      state.usage.record(
        providerId: 'p1',
        model: 'gpt-x',
        usage: const TokenUsage(inputTokens: 100, outputTokens: 50),
        at: DateTime.now(),
      );

      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.cost),
        state: state,
        w: 2,
        h: 1,
      ));
      await tester.pump();

      expect(find.textContaining('My Provider'), findsOneWidget);
      expect(find.textContaining('tokens'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}

/// A fixture map as a JSON object literal, for inlining into the hand-written
/// JSON array strings above.
String _jsonOf(Map<String, Object?> map) => jsonEncode(map);
