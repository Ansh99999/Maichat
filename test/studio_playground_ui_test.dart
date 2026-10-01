import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/models/studio_revisions.dart';
import 'package:maichat/screens/studio/shell/area_capsule.dart';
import 'package:maichat/screens/studio/studio_draft_view.dart';
import 'package:maichat/screens/studio/studio_playground_view.dart';
import 'package:maichat/screens/studio/studio_screen.dart';
import 'package:maichat/services/studio/studio_controller.dart';
import 'package:maichat/services/studio/studio_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// The Playground area and the Draft's Notes tab, as drawn: the four-area
/// capsule at a phone's width and a wide one, the Playground's chats (the
/// user's and an agent's) and what the dock offers for each, and the notes.
/// Nothing here is sent anywhere; the request a playtest makes is asserted in
/// `studio_workbench_test.dart`.
void main() {
  late Directory dir;
  var serial = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = Directory.systemTemp.createTempSync('studio_playground_ui');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  StudioSession seeded({bool playtests = true}) {
    final session = StudioSession(
      id: 'pg-${serial++}',
      title: 'Keeper',
      workspace: StudioWorkspace(
        character: Character(
          id: 'c',
          name: 'Maren',
          firstMes: 'You came back.',
          alternateGreetings: ['The lamp is out again.'],
        ),
        notes: '## Research\n\nThe Saltmarsh light was built in 1802.',
      ),
    );
    if (playtests) {
      session
        ..addPlaytest(StudioPlaytest(
          id: 'mine',
          by: kUserEditor,
          title: 'Hello?',
          turns: const [
            StudioPlaytestTurn(user: false, text: 'You came back.'),
            StudioPlaytestTurn(user: true, text: 'Hello?'),
            StudioPlaytestTurn(user: false, text: 'Mind the tide.'),
          ],
        ))
        ..addPlaytest(StudioPlaytest(
          id: 'agent',
          by: 'Subagent 2',
          title: 'Voice check',
          persona: 'a wary sailor',
          turns: const [
            StudioPlaytestTurn(user: false, text: 'You came back.'),
            StudioPlaytestTurn(user: true, text: 'Why stay?'),
            StudioPlaytestTurn(user: false, text: 'The light needs me.'),
          ],
        ));
    }
    return session;
  }

  Future<AppState> boot() async {
    final state = AppState();
    await state.init();
    return state;
  }

  Widget host(AppState state, Widget child) =>
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(home: child),
      );

  void phone(WidgetTester tester, {double width = 360}) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 780);
    addTearDown(tester.view.reset);
  }

  Future<void> openPlayground(WidgetTester tester, AppState state, StudioSession s) async {
    await state.updateStudioConfig(state.studioConfig.copyWith(areasCapsule: true));
    await tester.pumpWidget(
      host(state, StudioScreen(store: StudioStore(dir), session: s)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('studio-area-playground')));
    await tester.pumpAndSettle();
  }

  Finder inCapsule(String text) => find.descendant(
        of: find.byKey(const Key('studio-area-capsule')),
        matching: find.text(text),
      );

  // The capsule, in every combination of width and chosen area: the chosen
  // area's label always shows; at a phone's width the others give way to
  // their icons, at a wide one every label shows. A layout overflow would fail
  // the test by itself.
  for (final width in [360.0, 412.0, 800.0]) {
    for (final chosen in StudioArea.values) {
      testWidgets('the capsule at ${width.toInt()} wide with ${chosen.name} chosen',
          (tester) async {
        phone(tester, width: width);
        var area = chosen;
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: StatefulBuilder(
                  builder: (context, setState) => AreaCapsule(
                    area: area,
                    changes: 12,
                    onChanged: (a) => setState(() => area = a),
                  ),
                ),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        String label(StudioArea a) =>
            a == StudioArea.changes ? 'Changes 12' : a.label;
        expect(inCapsule(label(chosen)), findsOneWidget);
        for (final other in StudioArea.values.where((a) => a != chosen)) {
          expect(inCapsule(label(other)), width >= 800 ? findsOneWidget : findsNothing,
              reason: '${other.name} beside ${chosen.name}');
          expect(find.byKey(Key('studio-area-${other.name}')), findsOneWidget);
        }
        // The chosen slot is the widest, and holds its icon and label.
        final slot = tester.getSize(find.byKey(Key('studio-area-${chosen.name}')));
        final text = tester.getSize(inCapsule(label(chosen)));
        expect(slot.width, greaterThanOrEqualTo(text.width + 18 + 6));
        for (final other in StudioArea.values.where((a) => a != chosen)) {
          expect(
            tester.getSize(find.byKey(Key('studio-area-${other.name}'))).width,
            lessThanOrEqualTo(slot.width),
          );
        }
        // Every area can still be reached, and the label follows the choice.
        final next = StudioArea.values[(chosen.index + 1) % StudioArea.values.length];
        await tester.tap(find.byKey(Key('studio-area-${next.name}')));
        await tester.pumpAndSettle();
        expect(inCapsule(label(next)), findsOneWidget);
        if (width < 800) expect(inCapsule(label(chosen)), findsNothing);
      });
    }
  }

  testWidgets('the Playground opens on the newest chat, an agent\'s: read-only, '
      'with the way to the user\'s own', (tester) async {
    phone(tester);
    final state = await boot();
    await openPlayground(tester, state, seeded());

    expect(find.byType(StudioPlaygroundView), findsOneWidget);
    expect(tester.getTopLeft(find.byType(StudioPlaygroundView)).dx, 0);
    // The conversation's composer stays with the conversation.
    expect(find.byKey(const Key('studio-composer-field')), findsNothing);
    // The chats, newest first, in a strip that scrolls sideways.
    expect(find.byKey(const Key('playground-chat-agent')), findsOneWidget);
    await tester.dragUntilVisible(
      find.byKey(const Key('playground-chat-mine')),
      find.byKey(const Key('playground-strip')),
      const Offset(-120, 0),
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('playground-chat-mine'))).dx,
      greaterThan(tester.getTopLeft(find.byKey(const Key('playground-new'))).dx),
    );
    expect(find.text('Playtest by Subagent 2'), findsOneWidget);
    expect(find.text('Playing: a wary sailor'), findsOneWidget);
    expect(find.text('The light needs me.', findRichText: true), findsOneWidget);
    expect(find.byKey(const Key('playground-readonly')), findsOneWidget);
    expect(find.byKey(const Key('playground-input')), findsNothing);
    expect(find.byType(AppBar), findsNothing);

    await tester.tap(find.byKey(const Key('playground-own-chat')));
    await tester.pumpAndSettle();
    expect(find.text('Your chat with the draft'), findsOneWidget);
    expect(find.text('Mind the tide.', findRichText: true), findsOneWidget);
    expect(find.byKey(const Key('playground-input')), findsOneWidget);
    expect(find.byKey(const Key('playground-send')), findsOneWidget);
    // Its last reply can be written again.
    expect(find.byKey(const Key('playground-retry')), findsOneWidget);

    // Back to the agent's by its chip.
    await tester.dragUntilVisible(
      find.byKey(const Key('playground-chat-agent')),
      find.byKey(const Key('playground-strip')),
      const Offset(120, 0),
    );
    await tester.tap(find.byKey(const Key('playground-chat-agent')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('playground-readonly')), findsOneWidget);
    expect(find.byKey(const Key('playground-retry')), findsNothing);
  });

  testWidgets('an empty Playground explains itself; a new chat starts from the '
      'greeting picked', (tester) async {
    phone(tester);
    final state = await boot();
    final session = seeded(playtests: false);
    await openPlayground(tester, state, session);

    expect(find.textContaining('Talk to the draft as it stands'), findsOneWidget);
    expect(find.byKey(const Key('playground-input')), findsOneWidget);

    await tester.tap(find.byKey(const Key('playground-new')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('playground-greeting-1')));
    await tester.pumpAndSettle();
    final chat = session.playtests.single;
    expect(chat.byUser, isTrue);
    expect(chat.greetingIndex, 1);
    expect(find.text('The lamp is out again.', findRichText: true), findsOneWidget);
    expect(find.text('From alternate greeting 1'), findsOneWidget);
    expect(find.byKey(Key('playground-chat-${chat.id}')), findsOneWidget);

    // A long press on a chat removes it.
    await tester.longPress(find.byKey(Key('playground-chat-${chat.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('playground-delete')));
    await tester.pumpAndSettle();
    expect(session.playtests, isEmpty);
    expect(find.textContaining('Talk to the draft as it stands'), findsOneWidget);
  });

  testWidgets('the Draft\'s Notes tab reads the notes and edits them by hand',
      (tester) async {
    phone(tester, width: 412);
    final state = await boot();
    final session = seeded(playtests: false);
    final controller =
        StudioController(state: state, store: StudioStore(dir), session: session);
    await tester.pumpWidget(host(
      state,
      Scaffold(body: StudioDraftView(controller: controller)),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.bySemanticsLabel('Notes'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Notes'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('draft-notes-body')), findsOneWidget);
    // The heading is drawn as a title, not as "## Research".
    expect(find.text('Research'), findsOneWidget);
    expect(find.textContaining('##'), findsNothing);
    expect(find.text('The Saltmarsh light was built in 1802.', findRichText: true),
        findsOneWidget);

    await tester.tap(find.byKey(const Key('draft-notes-edit')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '## Voice\n\nClipped.');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(session.workspace.notes, '## Voice\n\nClipped.');
    expect(session.ops.last.tool, 'manual');
    expect(session.ops.last.summary, 'Edited the notes by hand');
    expect(find.text('Voice'), findsOneWidget);
  });

  testWidgets('an empty Notes tab says what it is for', (tester) async {
    final state = await boot();
    final session = seeded(playtests: false)..workspace.notes = '';
    final controller =
        StudioController(state: state, store: StudioStore(dir), session: session);
    await tester.pumpWidget(host(
      state,
      Scaffold(body: StudioDraftView(controller: controller)),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.bySemanticsLabel('Notes'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Notes'));
    await tester.pumpAndSettle();
    expect(find.textContaining('never part of the character'), findsOneWidget);
    expect(find.text('Write notes'), findsOneWidget);
  });
}
