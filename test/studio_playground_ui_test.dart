import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/models/studio_revisions.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/screens/presets/chat_preset_panel.dart';
import 'package:maichat/screens/studio/shell/area_capsule.dart';
import 'package:maichat/screens/studio/studio_draft_view.dart';
import 'package:maichat/screens/studio/studio_screen.dart';
import 'package:maichat/services/studio/studio_controller.dart';
import 'package:maichat/services/studio/studio_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/message_bubble.dart';
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

  Finder chatScreen() => find.byKey(const Key('studio-playground-chat'));

  testWidgets('the Playground is the app\'s own chat screen, on the newest '
      'chat, with the draft as the character', (tester) async {
    phone(tester);
    final state = await boot();
    final session = seeded();
    await openPlayground(tester, state, session);

    expect(chatScreen(), findsOneWidget);
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(state.hostedChatId, session.playtest('agent')!.chat.id);
    // Its own chrome, not the Studio's: the chat's menu square and composer.
    expect(find.byKey(chatMenuButtonKey), findsOneWidget);
    expect(find.byKey(const Key('studio-menu')), findsNothing);
    expect(find.byKey(const Key('composer-field')), findsOneWidget);
    expect(find.byKey(const Key('studio-composer-field')), findsNothing);
    expect(find.byType(AppBar), findsNothing);
    // The real bubbles, with their action bars, and the draft's name on them.
    expect(find.byType(MessageBubble), findsNWidgets(3));
    expect(find.text('The light needs me.', findRichText: true), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(MessageBubble).first,
        matching: find.byType(IconButton),
      ),
      findsWidgets,
    );
    final bubbles = tester.widgetList<MessageBubble>(find.byType(MessageBubble));
    expect(bubbles.where((b) => !b.message.isUser).map((b) => b.character?.name),
        everyElement('Maren'));
    // A copy of the draft as it stands, never the draft itself, so nothing the
    // chat does writes into the draft behind the Studio's back.
    expect(bubbles.first.character, isNot(same(session.workspace.character)));
    // An edit to the draft reaches the chat on screen.
    StudioHub.instance.find(session.id)!.editByHand(
      'Renamed by hand',
      (ws) => ws.character.name = 'Marenna',
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<MessageBubble>(find.byType(MessageBubble))
          .where((b) => !b.message.isUser)
          .map((b) => b.character?.name),
      everyElement('Marenna'),
    );
    // None of it is in the app's own chats.
    expect(state.conversations, isEmpty);
  });

  testWidgets('the Playground\'s sidebar: symbols, a line with +, the chats; '
      'a long press pours out export, import and delete', (tester) async {
    phone(tester);
    final state = await boot();
    await state.addCharacter(Character(id: 'me', name: 'Ash'));
    await state.setDefaultPersona('me');
    final session = seeded();
    await openPlayground(tester, state, session);

    await tester.tap(find.byKey(chatMenuButtonKey));
    await tester.pumpAndSettle();
    final symbols = find.byKey(const Key('playground-symbols'));
    expect(symbols, findsOneWidget);
    for (final key in ['preset', 'provider', 'group', 'interface']) {
      expect(find.byKey(Key('playground-$key')), findsOneWidget, reason: key);
    }
    // Symbols only, side by side.
    expect(find.descendant(of: symbols, matching: find.byType(Text)), findsNothing);
    final preset = tester.getCenter(find.byKey(const Key('playground-preset')));
    final ui = tester.getCenter(find.byKey(const Key('playground-interface')));
    expect(preset.dy, closeTo(ui.dy, 0.5));
    expect(preset.dx, lessThan(ui.dx));
    // Under them the line with its +, then the chats, newest first; the
    // agent's is marked as the agent's.
    final plus = tester.getCenter(find.byKey(const Key('playground-new')));
    expect(plus.dy, greaterThan(preset.dy));
    final agentRow = find.byKey(const Key('playground-chat-agent'));
    final mineRow = find.byKey(const Key('playground-chat-mine'));
    expect(tester.getTopLeft(agentRow).dy, greaterThan(plus.dy));
    expect(tester.getTopLeft(mineRow).dy, greaterThan(tester.getTopLeft(agentRow).dy));
    expect(find.descendant(of: agentRow, matching: find.byKey(const Key('playground-agent-mark'))),
        findsOneWidget);
    expect(find.descendant(of: mineRow, matching: find.byKey(const Key('playground-agent-mark'))),
        findsNothing);
    // The preset symbol opens the chat's own preset panel, in the drawer.
    await tester.tap(find.byKey(const Key('playground-preset')));
    await tester.pumpAndSettle();
    expect(find.byType(ChatPresetPanel), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(symbols, findsOneWidget);

    // A chat opens in the chat screen.
    await tester.tap(mineRow);
    await tester.pumpAndSettle();
    expect(state.hostedChatId, session.playtest('mine')!.chat.id);
    expect(find.text('Mind the tide.', findRichText: true), findsOneWidget);

    // + starts a chat with the draft, as any new chat starts: its greeting,
    // and the default persona as the user's.
    await tester.tap(find.byKey(chatMenuButtonKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('playground-new')));
    await tester.pumpAndSettle();
    expect(session.playtests, hasLength(3));
    final fresh = session.playtests.last;
    expect(state.hostedChatId, fresh.chat.id);
    expect(fresh.chat.impersonateId, 'me');
    expect(find.text('You came back.', findRichText: true), findsOneWidget);
    expect(find.text('Ash'), findsWidgets);
    expect(state.conversations, isEmpty);

    // A long press pours out the options; Delete asks first.
    await tester.tap(find.byKey(chatMenuButtonKey));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('playground-delete')), findsNothing);
    await tester.longPress(find.byKey(Key('playground-chat-${fresh.id}')));
    await tester.pumpAndSettle();
    for (final key in ['export', 'import', 'delete']) {
      expect(find.byKey(Key('playground-$key')), findsOneWidget, reason: key);
    }
    await tester.tap(find.byKey(const Key('playground-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('playground-delete-confirm')));
    await tester.pumpAndSettle();
    expect(session.playtest(fresh.id), isNull);
    expect(find.byKey(Key('playground-chat-${fresh.id}')), findsNothing);
    // The screen moved on to another of the Playground's chats.
    expect(session.playtests.map((p) => p.chat.id), contains(state.hostedChatId));

    // Export offers the app's own export shapes.
    await tester.longPress(mineRow);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('playground-export')));
    await tester.pumpAndSettle();
    expect(find.text('EXPORT AS'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    // Import reads a chat the app's importers read, as a chat with the draft.
    await tester.longPress(mineRow);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('playground-import')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste JSON'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      jsonEncode([
        {'role': 'user', 'content': 'An old hello'},
        {'role': 'assistant', 'content': 'An old reply'},
      ]),
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();
    final imported = session.playtests.last;
    expect(imported.byUser, isTrue);
    expect(imported.chat.messages.map((m) => m.content),
        ['An old hello', 'An old reply']);
    expect(imported.chat.id, startsWith(kHostedChatPrefix));
    expect(state.conversations, isEmpty);
  });

  // Whichever composer the Chat Interface has, and whether the capsule is up:
  // the Playground is the chat screen with the Studio's chrome put away, and
  // its composer can always bring the capsule back.
  for (final style in ComposerStyle.values) {
    for (final capsule in [true, false]) {
      testWidgets('the Playground with the ${style.name} composer, capsule '
          '${capsule ? 'up' : 'away'}', (tester) async {
        phone(tester);
        final state = await boot();
        await state.updateChatInterface(
            state.chatInterface.copyWith(composerStyle: style));
        await openPlayground(tester, state, seeded());
        if (!capsule) {
          // Put away from the Playground itself, it stays on the Playground.
          await tester.tap(find.byKey(const Key('composer-ops-button')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('playground-areas-button')));
          await tester.pumpAndSettle();
          expect(state.studioConfig.areasCapsule, isFalse);
        }
        expect(chatScreen(), findsOneWidget);
        expect(find.byKey(const Key('composer-field')), findsOneWidget);
        expect(find.byKey(const Key('studio-menu')), findsNothing);
        expect(find.byKey(const Key('studio-composer-field')), findsNothing);
        final areas = find.byKey(const Key('playground-areas'));
        expect(areas, capsule ? findsOneWidget : findsNothing);
        if (capsule) {
          // Over the composer, inside the chat screen.
          expect(tester.getBottomLeft(areas).dy,
              lessThanOrEqualTo(tester.getTopLeft(find.byKey(const Key('composer-field'))).dy));
        }
        // The composer's strip has the way back to the capsule.
        if (find.byKey(const Key('playground-areas-button')).evaluate().isEmpty) {
          await tester.tap(find.byKey(const Key('composer-ops-button')));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(const Key('playground-areas-button')));
        await tester.pumpAndSettle();
        expect(state.studioConfig.areasCapsule, !capsule);
        if (capsule) return;
        // Brought back, it leads out to the other areas, where the Studio's
        // own chrome is again.
        expect(areas, findsOneWidget);
        await tester.tap(find.descendant(
          of: areas,
          matching: find.byKey(const Key('studio-area-draft')),
        ));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('studio-menu')), findsOneWidget);
        expect(find.byType(StudioDraftView), findsOneWidget);
      });
    }
  }

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
