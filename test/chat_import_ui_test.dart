import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/screens/chats_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Drives the real Chats screen. The codec has its own tests; what these check is
/// the wiring — that the import button is beside the heading rather than in the
/// corner, that a pasted log becomes a thread in the list, and that the character
/// chosen on the way in is the one the thread ends up bound to.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<AppState> ready() async {
    final state = AppState();
    await state.init();
    return state;
  }

  Widget host(AppState state, Widget screen) =>
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(home: screen),
      );

  String agnaiLog() => jsonEncode({
        'name': 'Library evening',
        'greeting': '',
        'scenario': '',
        'sampleChat': '',
        'messages': [
          {'msg': 'You came back.', 'characterId': 'imported', 'name': 'Mai'},
          {'msg': 'I did.', 'userId': 'anon', 'handle': 'Ubuntu'},
        ],
      });

  testWidgets('the import button sits beside the heading, not above it',
      (tester) async {
    final state = await ready();
    await tester.pumpWidget(host(state, const ChatsScreen()));
    await tester.pumpAndSettle();

    final button = find.byTooltip('Import chat');
    expect(button, findsOneWidget);
    // The large app bar draws its title twice — once in the toolbar, once as the
    // headline below it — so a single copy of this button is the proof that it is
    // not also sitting in the top-right corner. The copy that exists is level
    // with the big "Chats" and to its right.
    final titles = find.text('Chats');
    expect(titles, findsNWidgets(2));
    final first = tester.getCenter(titles.at(0));
    final second = tester.getCenter(titles.at(1));
    final headline = first.dy > second.dy ? first : second;
    final icon = tester.getCenter(button);
    expect((icon.dy - headline.dy).abs(), lessThan(24));
    expect(icon.dx, greaterThan(headline.dx));
    expect(icon.dy, greaterThan(kToolbarHeight));
  });

  testWidgets('a pasted log becomes a thread bound to the matching character',
      (tester) async {
    final state = await ready();
    await state.addCharacter(Character(
      id: 'mai',
      name: 'Mai',
      description: 'A calm librarian.',
    ));
    await tester.pumpWidget(host(state, const ChatsScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Import chat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste JSON'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), agnaiLog());
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();

    // The summary says what was recognised before anything is written.
    expect(find.text('Import chat'), findsWidgets);
    expect(find.text('Library evening'), findsOneWidget);
    expect(find.textContaining('2 messages'), findsOneWidget);
    expect(find.textContaining('Agnai'), findsOneWidget);
    // The character named in the file is already chosen.
    expect(find.text('Mai'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();

    final imported = state.conversations.single;
    expect(imported.title, 'Library evening');
    expect(imported.messages.map((m) => m.role).toList(),
        ['assistant', 'user']);
    expect(imported.messages.first.content, 'You came back.');
    // Bound, so the thread can be continued: the persona rides along.
    expect(imported.characterId, 'mai');
    expect(imported.systemPrompt, contains('A calm librarian.'));
    // And it is in the list, newest first.
    expect(find.text('Library evening'), findsOneWidget);
  });

  testWidgets('with no characters saved it imports as a plain thread',
      (tester) async {
    final state = await ready();
    await tester.pumpWidget(host(state, const ChatsScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Import chat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste JSON'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), agnaiLog());
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No saved characters'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();

    final imported = state.conversations.single;
    expect(imported.characterId, isNull);
    // The name the file gave is kept even with nothing to bind to.
    expect(imported.characterName, 'Mai');
  });
}
