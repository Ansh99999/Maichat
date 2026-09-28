import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/character_scenario.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/screens/studio/studio_changes_view.dart';
import 'package:maichat/screens/studio/studio_draft_view.dart';
import 'package:maichat/services/studio/studio_controller.dart';
import 'package:maichat/services/studio/studio_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/avatar_image.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// The Studio's Draft and Changes pages over a real [StudioController]: the
/// browser-style tabs, the avatar placed by the picture's shape, folding and
/// editing a field, editing a lorebook in the library's own editor without the
/// library seeing it, and rewinding from the change list.
void main() {
  late Directory dir;
  var serial = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    clearAvatarImageCache();
    dir = Directory.systemTemp.createTempSync('studio_draft_ui');
  });
  tearDown(() {
    clearAvatarImageCache();
    dir.deleteSync(recursive: true);
  });

  const personality = 'Dry wit, iron patience, and a habit of counting the '
      'waves out loud when she is nervous. She trusts the lamp more than '
      'people and says so, often, to anyone who lingers on the stairs.';

  StudioSession seeded({String avatar = ''}) {
    final session = StudioSession(
      id: 'draft-ui-${serial++}',
      title: 'Keeper',
      workspace: StudioWorkspace(
        character: Character(id: 'c', name: '', avatar: avatar),
      ),
    );
    session.edit('set_fields', 'Set name, personality', (ws) {
      ws.character
        ..name = 'Maren'
        ..title = 'the last keeper'
        ..titleShown = true
        ..tags = ['horror', 'coastal']
        ..personality = personality
        ..firstMes = 'The lamp is lit. You are late.'
        ..alternateGreetings = ['Storm again.'];
    });
    session.edit('create_lorebook', 'Created lorebook "Saltmarsh"', (ws) {
      ws.lorebooks.add(Lorebook(id: 'b', name: 'Saltmarsh', entries: [
        LorebookEntry(uid: 0, name: 'The marsh', keys: ['marsh'], content: 'Grey.'),
      ]));
      ws.character.lorebookIds.add('b');
    });
    return session;
  }

  Future<(AppState, StudioController)> boot(StudioSession session) async {
    final state = AppState();
    await state.init();
    final controller =
        StudioController(state: state, store: StudioStore(dir), session: session);
    return (state, controller);
  }

  Widget host(AppState state, Widget body) =>
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(home: Scaffold(body: body)),
      );

  /// Taps a tab, scrolling the strip to it first — at a phone's width the
  /// later tabs start off the edge, as they do in a browser.
  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.bySemanticsLabel(label));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel(label));
    await tester.pumpAndSettle();
  }

  testWidgets('six browser-style tabs, and the page follows them',
      (tester) async {
    final (state, controller) = await boot(seeded());
    await tester.pumpWidget(host(state, StudioDraftView(controller: controller)));
    await tester.pumpAndSettle();

    for (final label in [
      'Character',
      'Images',
      'Lorebook',
      'Embeddings',
      'Documents',
      'Scenarios',
    ]) {
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
    }
    // Character is open: its rows are there, the lorebook is not.
    expect(find.byKey(const ValueKey('draft-field-Personality')), findsOneWidget);
    expect(find.byKey(const ValueKey('draft-book-b')), findsNothing);

    await openTab(tester, 'Lorebook');
    expect(find.byKey(const ValueKey('draft-book-b')), findsOneWidget);
    expect(find.text('Saltmarsh'), findsOneWidget);

    // A swipe moves on to the next tab, the way a tap does.
    await tester.fling(find.byType(PageView), const Offset(-500, 0), 1500);
    await tester.pumpAndSettle();
    expect(find.text('Embeddings are off'), findsOneWidget);
  });

  group('the avatar goes where its shape says', () {
    // Every shape × the two ends of the layout: beside the name, or across the
    // top with the name below.
    for (final (name, ratio, side) in [
      ('portrait', 0.75, true),
      ('square', 1.0, true),
      ('landscape', 1.78, false),
    ]) {
      testWidgets(name, (tester) async {
        final ref = 'local:$name.png';
        noteAvatarRatio(ref, ratio);
        final (state, controller) = await boot(seeded(avatar: ref));
        await tester
            .pumpWidget(host(state, StudioDraftView(controller: controller)));
        await tester.pumpAndSettle();

        final picture = tester.getRect(
          find.byKey(const ValueKey('draft-header-picture')).first,
        );
        final title = tester.getRect(find.text('Maren').first);
        final width = tester.getSize(find.byType(PageView)).width;
        if (side) {
          expect(find.byKey(const ValueKey('draft-header-side')), findsWidgets);
          // Top right, with the name on its left.
          expect(picture.left, greaterThan(title.right));
          expect(picture.right, closeTo(width - 16, 1));
          expect(picture.width, closeTo(132, 1));
          expect(picture.height, closeTo(132 / ratio, 1.5));
        } else {
          expect(
              find.byKey(const ValueKey('draft-header-landscape')), findsWidgets);
          // The whole width, with the name underneath.
          expect(picture.width, closeTo(width - 32, 1));
          expect(title.top, greaterThan(picture.bottom));
        }
      });
    }

    testWidgets('no picture: a monogram at the top right', (tester) async {
      final (state, controller) = await boot(seeded());
      await tester
          .pumpWidget(host(state, StudioDraftView(controller: controller)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('draft-header-picture')), findsNothing);
      final name = tester.getRect(find.text('Maren').first);
      expect(name.left, lessThan(40));
    });
  });

  testWidgets('a field folds open, and an edit is recorded as the user\'s',
      (tester) async {
    final (state, controller) = await boot(seeded());
    await tester.pumpWidget(host(state, StudioDraftView(controller: controller)));
    await tester.pumpAndSettle();

    Text body() => tester.widget<Text>(find.descendant(
          of: find.byKey(const ValueKey('draft-field-Personality')),
          matching: find.text(personality),
        ));
    expect(body().maxLines, 1);
    await tester.tap(find.byTooltip('Show personality'));
    await tester.pumpAndSettle();
    expect(body().maxLines, isNull);
    expect(find.byTooltip('Fold personality'), findsOneWidget);

    await tester.tap(find.byTooltip('Edit personality'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Warm, for a keeper.');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(controller.session.workspace.character.personality,
        'Warm, for a keeper.');
    expect(controller.session.ops.last.tool, 'manual');
    expect(find.text('Warm, for a keeper.'), findsOneWidget);
  });

  testWidgets('tags are edited as a list and slide as chips', (tester) async {
    final (state, controller) = await boot(seeded());
    await tester.pumpWidget(host(state, StudioDraftView(controller: controller)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit tags'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Horror, gothic, horror');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(controller.session.workspace.character.tags, ['horror', 'gothic']);
    expect(find.widgetWithText(Chip, 'gothic'), findsWidgets);
  });

  testWidgets('a lorebook is edited in the library editor, into the draft only',
      (tester) async {
    final (state, controller) = await boot(seeded());
    await tester.pumpWidget(host(state, StudioDraftView(controller: controller)));
    await tester.pumpAndSettle();
    await openTab(tester, 'Lorebook');

    await tester.tap(find.byTooltip('Edit Saltmarsh'));
    await tester.pumpAndSettle();
    expect(find.text('Edit lorebook'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'Drowned Coast');
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    final ws = controller.session.workspace;
    expect(ws.lorebooks.single.name, 'Drowned Coast');
    expect(ws.lorebooks.single.entries.single.content, 'Grey.');
    expect(controller.session.ops.last.tool, 'manual');
    // Nothing reached the library.
    expect(state.lorebooks, isEmpty);
    expect(find.text('Drowned Coast'), findsOneWidget);
  });

  testWidgets('a new lorebook from the editor is added and attached',
      (tester) async {
    final (state, controller) = await boot(seeded());
    await tester.pumpWidget(host(state, StudioDraftView(controller: controller)));
    await tester.pumpAndSettle();
    await openTab(tester, 'Lorebook');
    await tester.tap(find.text('New lorebook'));
    await tester.pumpAndSettle();
    expect(find.text('New lorebook'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'Tides');
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    final ws = controller.session.workspace;
    expect(ws.lorebooks.map((b) => b.name), ['Saltmarsh', 'Tides']);
    expect(ws.character.lorebookIds, hasLength(2));
    expect(state.lorebooks, isEmpty);
  });

  testWidgets('images: another picture can be made the main one',
      (tester) async {
    final session = seeded(avatar: 'local:one.png');
    session.workspace.character.avatars = ['local:two.png'];
    final (state, controller) = await boot(session);
    await tester.pumpWidget(host(state, StudioDraftView(controller: controller)));
    await tester.pumpAndSettle();
    await openTab(tester, 'Images');

    expect(find.text('Main'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('draft-picture-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use as main picture'));
    await tester.pumpAndSettle();
    final c = controller.session.workspace.character;
    expect(c.avatar, 'local:two.png');
    expect(c.avatars, ['local:one.png']);
  });

  testWidgets('scenarios: greetings are picked as chips', (tester) async {
    final session = seeded();
    session.workspace.character.scenarios
        .add(CharacterScenario(id: 's', name: 'Storm', text: 'The causeway is out.'));
    final (state, controller) = await boot(session);
    await tester.pumpWidget(host(state, StudioDraftView(controller: controller)));
    await tester.pumpAndSettle();
    await openTab(tester, 'Scenarios');

    final chip = find.widgetWithText(FilterChip, 'Greeting 2');
    await tester.scrollUntilVisible(chip, 200,
        scrollable: find.descendant(
          of: find.byKey(const PageStorageKey('draft-scenarios')),
          matching: find.byType(Scrollable),
        ).first);
    expect(find.text('Storm'), findsOneWidget);
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(controller.session.workspace.character.scenarios.single.greetings, [1]);
    expect(find.text('Covers the greetings picked below.'), findsOneWidget);
  });

  testWidgets('changes: newest first, rewound to a point after asking',
      (tester) async {
    final (state, controller) = await boot(seeded());
    await tester
        .pumpWidget(host(state, StudioChangesView(controller: controller)));
    await tester.pumpAndSettle();

    expect(find.text('2 changes in the draft'), findsOneWidget);
    final newest = tester.getRect(find.text('Created lorebook "Saltmarsh"'));
    final oldest = tester.getRect(find.text('Set name, personality'));
    expect(newest.top, lessThan(oldest.top));

    await tester.tap(find.widgetWithText(FilledButton, 'Rewind').first);
    await tester.pumpAndSettle();
    expect(find.text('Rewind the draft?'), findsOneWidget);
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('Rewind'),
    ));
    await tester.pumpAndSettle();

    expect(controller.session.workspace.lorebooks, isEmpty);
    expect(controller.session.workspace.character.name, 'Maren');
    expect(find.text('1 change in the draft'), findsOneWidget);
    expect(find.textContaining('undone'), findsWidgets);
  });
}
