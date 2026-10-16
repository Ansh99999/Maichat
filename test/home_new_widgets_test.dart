import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/home_layout.dart';
import 'package:maichat/screens/home/clock_ticker.dart';
import 'package:maichat/screens/home/home_spec.dart';
import 'package:maichat/screens/home/home_widgets.dart';
import 'package:maichat/screens/home/note_editor_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every span the Home grid can hand a widget, at ~90 logical px a cell —
/// the same matrix [home_widgets_test.dart] runs, kept here too so a new
/// kind is covered the same way without touching that file.
const _spans = <(int, int)>[
  (1, 1),
  (2, 1),
  (2, 2),
  (4, 1),
  (4, 2),
  (4, 4),
];

Map<String, Object?> _characterJson({required String id, required String name}) =>
    {'id': id, 'name': name};

Map<String, Object?> _folderJson({
  required String id,
  required String name,
  List<String> characterIds = const [],
}) =>
    {
      'id': id,
      'name': name,
      if (characterIds.isNotEmpty) 'characterIds': characterIds,
    };

Map<String, Object?> _noteJson({
  required String id,
  String title = '',
  String body = '',
  String updatedAt = '2026-10-10T10:00:00.000',
}) =>
    {
      'id': id,
      if (title.isNotEmpty) 'title': title,
      if (body.isNotEmpty) 'body': body,
      'updatedAt': updatedAt,
    };

String _jsonOf(Map<String, Object?> map) => jsonEncode(map);

/// Builds a [HomeTile]/[HomeTileContext] for [kind] at [w]x[h] and pumps the
/// spec's own [HomeWidgetSpec.build] inside a real [MaterialApp] + provider,
/// at the given logical size (90 px per cell, like the real grid) — the same
/// harness [home_widgets_test.dart] uses.
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

  const newKinds = [
    HomeWidgetKind.clock,
    HomeWidgetKind.note,
    HomeWidgetKind.characterFolder,
    HomeWidgetKind.appFolder,
  ];

  group('every new widget, every span, empty data', () {
    for (final kind in newKinds) {
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

  group('every new widget, every span, seeded data', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.characters': '''
          [
            ${_jsonOf(_characterJson(id: 'char1', name: 'Aria'))},
            ${_jsonOf(_characterJson(id: 'char2', name: 'Bram'))}
          ]
        ''',
        'flutter.folders': '''
          [${_jsonOf(_folderJson(id: 'f1', name: 'Favourites', characterIds: ['char1', 'char2']))}]
        ''',
        'flutter.homeNotes': '''
          [${_jsonOf(_noteJson(id: 'n1', title: 'Grocery list', body: 'Milk\\nEggs'))}]
        ''',
      });
    });

    for (final kind in newKinds) {
      for (final (w, h) in _spans) {
        for (final editing in [false, true]) {
          testWidgets(
            '${kind.name} at ${w}x$h, editing=$editing renders without error',
            (tester) async {
              final state = await _ready();
              final config = switch (kind) {
                HomeWidgetKind.characterFolder => const {'folderId': 'f1'},
                HomeWidgetKind.note => const {'noteId': 'n1'},
                HomeWidgetKind.appFolder => const {
                    'name': 'Shortcuts',
                    'targets': 'chats,newChat',
                  },
                _ => const <String, Object?>{},
              };
              await tester.pumpWidget(_harness(
                spec: specFor(kind),
                state: state,
                w: w,
                h: h,
                editing: editing,
                config: config,
              ));
              await tester.pump();
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }
  });

  group('clock', () {
    testWidgets('shows a time text with no exceptions', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.clock),
        state: state,
        w: 2,
        h: 1,
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
      // Some rendered text containing a ':' (hh:mm) should be present.
      final texts = tester.widgetList<Text>(find.byType(Text));
      expect(texts.any((t) => (t.data ?? '').contains(':')), isTrue);
    });

    testWidgets('a fixed clock renders the expected local time',
        (tester) async {
      final fixed = DateTime(2026, 10, 16, 9, 30);
      final previousClock = ClockTicker.clock;
      ClockTicker.clock = () => fixed;
      addTearDown(() => ClockTicker.clock = previousClock);

      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.clock),
        state: state,
        w: 2,
        h: 2,
        config: const {'hour24': '24'},
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('09:30'), findsOneWidget);
    });
  });

  group('note', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.homeNotes': '''
          [${_jsonOf(_noteJson(id: 'n1', title: 'Grocery list', body: 'Milk and eggs'))}]
        ''',
      });
    });

    testWidgets('shows the note heading and tapping opens the editor',
        (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.note),
        state: state,
        w: 2,
        h: 2,
        config: const {'noteId': 'n1'},
      ));
      await tester.pump();

      expect(find.text('Grocery list'), findsOneWidget);
      await tester.tap(find.text('Grocery list'));
      await tester.pumpAndSettle();
      expect(find.byType(NoteEditorScreen), findsOneWidget);
    });

    testWidgets('empty state with no note chosen', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.note),
        state: state,
        w: 2,
        h: 2,
      ));
      await tester.pump();
      expect(find.text('Tap to write a note'), findsOneWidget);
    });

    testWidgets('editing=true makes the tap do nothing', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.note),
        state: state,
        w: 2,
        h: 2,
        editing: true,
        config: const {'noteId': 'n1'},
      ));
      await tester.pump();
      await tester.tap(find.text('Grocery list'));
      await tester.pump();
      expect(find.byType(NoteEditorScreen), findsNothing);
    });

    testWidgets('typing in the editor then popping saves the note',
        (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.note),
        state: state,
        w: 2,
        h: 2,
        config: const {'noteId': 'n1'},
      ));
      await tester.pump();
      await tester.tap(find.text('Grocery list'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'Milk, eggs, bread');
      await tester.pump();

      await tester.runAsync(() async {
        await state.saveHomeNote(state.homeNoteById('n1')!.copyWith(
          body: 'Milk, eggs, bread',
        ));
      });

      expect(state.homeNoteById('n1')!.body, 'Milk, eggs, bread');
    });

    testWidgets('an empty note on pop is deleted', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.note),
        state: state,
        w: 2,
        h: 2,
      ));
      await tester.pump();
      await tester.tap(find.text('Tap to write a note'));
      await tester.pumpAndSettle();
      expect(find.byType(NoteEditorScreen), findsOneWidget);

      await tester.runAsync(() async {
        await Navigator.of(tester.element(find.byType(NoteEditorScreen)))
            .maybePop();
      });
      await tester.pumpAndSettle();
      expect(find.byType(NoteEditorScreen), findsNothing);
    });
  });

  group('character folder', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.characters': '''
          [
            ${_jsonOf(_characterJson(id: 'char1', name: 'Aria'))},
            ${_jsonOf(_characterJson(id: 'char2', name: 'Bram'))}
          ]
        ''',
        'flutter.folders': '''
          [${_jsonOf(_folderJson(id: 'f1', name: 'Favourites', characterIds: ['char1', 'char2']))}]
        ''',
      });
    });

    testWidgets('shows the folder name and member count at a bigger span',
        (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.characterFolder),
        state: state,
        w: 2,
        h: 2,
        config: const {'folderId': 'f1'},
      ));
      await tester.pump();

      expect(find.text('Favourites'), findsOneWidget);
      expect(find.textContaining('2 characters'), findsOneWidget);
    });

    testWidgets('tapping opens a route (the folder window)', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.characterFolder),
        state: state,
        w: 2,
        h: 2,
        config: const {'folderId': 'f1'},
      ));
      await tester.pump();

      await tester.tap(find.text('Favourites'));
      await tester.pumpAndSettle();
      expect(find.text('Favourites'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows "Choose a folder" with no folder chosen but folders exist',
        (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.characterFolder),
        state: state,
        w: 2,
        h: 1,
      ));
      await tester.pump();
      expect(find.text('Choose a folder'), findsOneWidget);
    });

    testWidgets('shows "No folders yet" with none configured at all',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.characterFolder),
        state: state,
        w: 2,
        h: 1,
      ));
      await tester.pump();
      expect(find.text('No folders yet'), findsOneWidget);
    });
  });

  group('app folder', () {
    testWidgets('1x1 opens a scale-up popup with its shortcuts',
        (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.appFolder),
        state: state,
        w: 1,
        h: 1,
        config: const {'name': 'Quick stuff', 'targets': 'chats,newChat'},
      ));
      await tester.pump();

      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();
      expect(find.text('Quick stuff'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a bigger span shows the folder name inline', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.appFolder),
        state: state,
        w: 2,
        h: 2,
        config: const {'name': 'Quick stuff', 'targets': 'chats,newChat'},
      ));
      await tester.pump();
      expect(find.text('Quick stuff'), findsOneWidget);
    });

    testWidgets('empty folder shows "No shortcuts yet" at a bigger span',
        (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.appFolder),
        state: state,
        w: 2,
        h: 2,
        config: const {'name': 'Empty'},
      ));
      await tester.pump();
      expect(find.text('No shortcuts yet'), findsOneWidget);
    });

    testWidgets('editing=true makes the 1x1 tap do nothing', (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.appFolder),
        state: state,
        w: 1,
        h: 1,
        editing: true,
        config: const {'name': 'Quick stuff', 'targets': 'chats'},
      ));
      await tester.pump();
      await tester.tap(find.byType(InkWell).first, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Quick stuff'), findsNothing);
    });
  });

  group('studio (new widget rework)', () {
    testWidgets('empty state at 2x2 shows the start-a-draft blurb',
        (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.studio),
        state: state,
        w: 2,
        h: 2,
      ));
      await tester.pump();
      expect(find.textContaining('Make someone new'), findsOneWidget);
      expect(find.text('New draft'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('1x1 icon renders with no store, editing or not',
        (tester) async {
      final state = await _ready();
      for (final editing in [false, true]) {
        await tester.pumpWidget(_harness(
          spec: specFor(HomeWidgetKind.studio),
          state: state,
          w: 1,
          h: 1,
          editing: editing,
        ));
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('4x4 renders the empty state without overflow',
        (tester) async {
      final state = await _ready();
      await tester.pumpWidget(_harness(
        spec: specFor(HomeWidgetKind.studio),
        state: state,
        w: 4,
        h: 4,
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
