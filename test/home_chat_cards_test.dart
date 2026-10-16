import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:maichat/models/home_layout.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/screens/home/home_spec.dart';
import 'package:maichat/screens/home/home_widgets.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every value the shared `avatar` option can take, for the full-matrix pass.
const _avatarValues = <String>[
  'topLeft',
  'left',
  'topRight',
  'right',
  'background',
  'none',
];

/// Spans the matrix runs at, in cells — the Home grid's own cell size (~90px)
/// scaled by the per-test logical cell size below.
const _spans = <(int, int)>[
  (2, 1),
  (2, 2),
  (4, 1),
  (4, 2),
  (4, 3),
  (4, 4),
];

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

String _jsonOf(Map<String, Object?> map) => jsonEncode(map);

/// Builds a [HomeTile]/[HomeTileContext] for [kind] at a size of
/// [cellWidth]x[cellHeight] logical px per cell, and pumps the spec's own
/// [HomeWidgetSpec.build] inside a real [MaterialApp] + provider — the same
/// harness shape as `test/home_widgets_test.dart`, with a configurable cell
/// size so the dense 49x76 case doesn't need its own path.
Widget _harness({
  required HomeWidgetSpec spec,
  required AppState state,
  required int w,
  required int h,
  bool editing = false,
  Map<String, Object?> config = const {},
  double cellWidth = 95,
  double cellHeight = 120,
  double textScale = 1.0,
  Brightness brightness = Brightness.light,
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
  );
  final size = Size(w * cellWidth, h * cellHeight);
  final ctx = HomeTileContext(
    tile: tile,
    size: size,
    layout: layout,
    editing: editing,
  );
  return ChangeNotifierProvider<AppState>.value(
    value: state,
    child: MaterialApp(
      theme: ThemeData(brightness: Brightness.light, useMaterial3: true),
      darkTheme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: Builder(builder: (context) => spec.build(context, ctx)),
              ),
            ),
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

  group('avatar placement x span x text scale x theme matrix', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.conversations': '''
          [${_jsonOf(_chatJson(
          id: 'c1',
          title: 'Latest chat',
          updatedAt: '2026-10-10T10:00:00.000',
          characterId: 'char1',
          lastMessage: 'A fairly long last message that should wrap onto more than one line of preview text.',
        ))}]
        ''',
        'flutter.characters': '''
          [${_jsonOf(_characterJson(id: 'char1', name: 'Aria'))}]
        ''',
      });
    });

    for (final kind in [HomeWidgetKind.recentChat, HomeWidgetKind.pinnedChat]) {
      for (final avatar in _avatarValues) {
        for (final (w, h) in _spans) {
          for (final textScale in [1.0, 1.5]) {
            for (final brightness in [Brightness.light, Brightness.dark]) {
              testWidgets(
                '${kind.name} avatar=$avatar ${w}x$h scale=$textScale ${brightness.name} renders without error',
                (tester) async {
                  final state = await _ready();
                  final config = kind == HomeWidgetKind.pinnedChat
                      ? {'chatId': 'c1', 'avatar': avatar}
                      : {'avatar': avatar};
                  await tester.pumpWidget(_harness(
                    spec: specFor(kind),
                    state: state,
                    w: w,
                    h: h,
                    config: config,
                    textScale: textScale,
                    brightness: brightness,
                  ));
                  await tester.pump();
                  expect(tester.takeException(), isNull);
                },
              );
            }
          }
        }
      }
    }

    // The dense 49x76 case: smaller than the grid's own minimum span (2x1 at
    // ~90px/cell), close to what a widget squeezed below its minimum span by
    // a grid change could still be handed.
    for (final kind in [HomeWidgetKind.recentChat, HomeWidgetKind.pinnedChat]) {
      for (final avatar in _avatarValues) {
        testWidgets(
          'dense 49x76: ${kind.name} avatar=$avatar renders without error',
          (tester) async {
            final state = await _ready();
            final config = kind == HomeWidgetKind.pinnedChat
                ? {'chatId': 'c1', 'avatar': avatar}
                : {'avatar': avatar};
            await tester.pumpWidget(_harness(
              spec: specFor(kind),
              state: state,
              w: 1,
              h: 1,
              config: config,
              cellWidth: 49,
              cellHeight: 76,
            ));
            await tester.pump();
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  });

  group('showName / showTime toggles', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.conversations': '''
          [${_jsonOf(_chatJson(id: 'c1', title: 'Latest chat', updatedAt: '2026-10-10T10:00:00.000'))}]
        ''',
      });
    });

    testWidgets('showName=false hides the title', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.recentChat),
        state: state,
        w: 2,
        h: 2,
        config: const {'showName': false},
      ));
      await tester.pump();
      expect(find.text('Latest chat'), findsNothing);
    });

    testWidgets('showName=true (default) shows the title', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.recentChat),
        state: state,
        w: 2,
        h: 2,
      ));
      await tester.pump();
      expect(find.text('Latest chat'), findsOneWidget);
    });

    testWidgets('showTime=false hides the relative time', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.recentChat),
        state: state,
        w: 2,
        h: 2,
        config: const {'showTime': false},
      ));
      await tester.pump();
      // relativeTime of a long-past timestamp always contains "ago".
      expect(find.textContaining('ago'), findsNothing);
    });

    testWidgets('showTime=true (default) shows the relative time', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.recentChat),
        state: state,
        w: 2,
        h: 2,
      ));
      await tester.pump();
      expect(find.textContaining('ago'), findsOneWidget);
    });
  });

  group('lines option', () {
    const multiLine = 'First line of the reply.\nSecond line.\nLast line of the reply.';

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.conversations': '''
          [${_jsonOf(_chatJson(
          id: 'c1',
          title: 'Latest chat',
          updatedAt: '2026-10-10T10:00:00.000',
          lastMessage: multiLine,
        ))}]
        ''',
      });
    });

    testWidgets('lines=firstLine shows the first line, not the last', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.recentChat),
        state: state,
        w: 4,
        h: 4,
        config: const {'lines': 'firstLine'},
      ));
      await tester.pump();
      expect(find.textContaining('First line of the reply.'), findsOneWidget);
      expect(find.textContaining('Last line of the reply.'), findsNothing);
    });

    testWidgets('lines=lastLine shows the last line, not the first', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.recentChat),
        state: state,
        w: 4,
        h: 4,
        config: const {'lines': 'lastLine'},
      ));
      await tester.pump();
      expect(find.textContaining('Last line of the reply.'), findsOneWidget);
      expect(find.textContaining('First line of the reply.'), findsNothing);
    });

    testWidgets('lines=lastTwo shows both the last two turns', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.recentChat),
        state: state,
        w: 4,
        h: 4,
        config: const {'lines': 'lastTwo'},
      ));
      await tester.pump();
      expect(find.textContaining('You: Hi'), findsOneWidget);
      expect(find.textContaining('First line of the reply.'), findsOneWidget);
    });

    testWidgets('lines=none shows no preview text', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.recentChat),
        state: state,
        w: 4,
        h: 4,
        config: const {'lines': 'none'},
      ));
      await tester.pump();
      expect(find.textContaining('First line of the reply.'), findsNothing);
      expect(find.textContaining('Last line of the reply.'), findsNothing);
    });
  });

  group('background style', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.conversations': '''
          [${_jsonOf(_chatJson(
          id: 'c1',
          title: 'Latest chat',
          updatedAt: '2026-10-10T10:00:00.000',
          characterId: 'char1',
        ))}]
        ''',
        'flutter.characters': '''
          [${_jsonOf({..._characterJson(id: 'char1', name: 'Aria'), 'avatar': 'https://example.com/aria.png'})}]
        ''',
      });
    });

    testWidgets('background + blur builds an ImageFiltered', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.recentChat),
        state: state,
        w: 4,
        h: 4,
        config: const {'avatar': 'background', 'bgStyle': 'blur'},
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(ImageFiltered), findsOneWidget);
    });

    testWidgets('background + opaque renders without a blur filter', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.recentChat),
        state: state,
        w: 4,
        h: 4,
        config: const {'avatar': 'background', 'bgStyle': 'opaque'},
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(ImageFiltered), findsNothing);
    });

    testWidgets('background + fade renders a ShaderMask', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.recentChat),
        state: state,
        w: 4,
        h: 4,
        config: const {'avatar': 'background', 'bgStyle': 'fade'},
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(ShaderMask), findsOneWidget);
    });
  });

  group('nameFont', () {
    setUpAll(() {
      // Never let a widget test try a real network fetch for a font.
      GoogleFonts.config.allowRuntimeFetching = false;
    });

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.conversations': '''
          [${_jsonOf(_chatJson(id: 'c1', title: 'Latest chat', updatedAt: '2026-10-10T10:00:00.000'))}]
        ''',
      });
    });

    testWidgets('a chosen font family does not crash, and the title still renders',
        (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.recentChat),
        state: state,
        w: 4,
        h: 2,
        config: const {'nameFont': 'Roboto Slab'},
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Latest chat'), findsOneWidget);
    });

    testWidgets('an unknown font family falls back gracefully, no crash',
        (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.recentChat),
        state: state,
        w: 4,
        h: 2,
        config: const {'nameFont': 'Not A Real Font Family Xyz'},
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Latest chat'), findsOneWidget);
    });
  });

  group('tap behaviour', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.conversations': '''
          [${_jsonOf(_chatJson(id: 'c1', title: 'Latest chat', updatedAt: '2026-10-10T10:00:00.000'))}]
        ''',
      });
    });

    testWidgets('tapping the card opens ChatScreen', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.recentChat),
        state: state,
        w: 2,
        h: 1,
      ));
      await tester.pump();

      await tester.tap(find.text('Latest chat'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(state.active.id, 'c1');
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
  });
}
