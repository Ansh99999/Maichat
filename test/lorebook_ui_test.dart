import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/screens/chat_memory_panel.dart';
import 'package:maichat/screens/library/library_screen.dart';
import 'package:maichat/screens/library/lorebook_edit_screen.dart';
import 'package:maichat/screens/library/lorebooks_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Drives the real lorebook screens. The data layer has its own tests; what
/// these check is that the screens are wired to it — that a book written in the
/// editor is the book the library lists and the chat can switch on, which is
/// exactly the seam a unit test cannot see.
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

  Lorebook kingdom() => Lorebook(
        id: 'k',
        name: 'Kingdom',
        description: 'Places and people.',
        tags: const ['fantasy'],
        entries: [
          LorebookEntry(
            uid: 0,
            name: 'Valeport',
            content: 'Valeport is the capital.',
            keys: const ['valeport'],
          ),
        ],
      );

  testWidgets('the library lists what it holds and opens the shelf',
      (tester) async {
    final state = await ready();
    await state.addLorebook(kingdom());
    await tester.pumpWidget(host(state, const LibraryScreen()));
    await tester.pumpAndSettle();

    // The resting state: one card per shelf, with the lorebook count on it.
    expect(find.text('Lorebooks'), findsWidgets);
    expect(find.text('Scenarios'), findsOneWidget);
    expect(find.text('Embeddings'), findsOneWidget);
    expect(find.textContaining('1 book'), findsOneWidget);

    await tester.tap(find.text('Lorebooks').first);
    await tester.pumpAndSettle();
    expect(find.byType(LorebooksScreen), findsOneWidget);
    expect(find.text('Kingdom'), findsWidgets);
  });

  testWidgets('library search finds a fact inside a book, not just the book',
      (tester) async {
    final state = await ready();
    await state.addLorebook(kingdom());
    await tester.pumpWidget(host(state, const LibraryScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(SearchBar), 'capital');
    await tester.pumpAndSettle();

    // The book's own name does not contain "capital" — the entry's text does.
    expect(find.text('Entries'), findsOneWidget);
    expect(find.text('Valeport'), findsOneWidget);
  });

  testWidgets('a book written in the editor is saved and listed',
      (tester) async {
    final state = await ready();
    await tester.pumpWidget(host(state, const LorebookEditScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'Islands');
    // A new book starts with no entries, so add one and fill it in.
    await tester.tap(find.text('Entry').first);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Name of entry'), 'Storms');
    // The entry's own fields are plain TextFields — only the book-level ones are
    // validated, so only those are TextFormFields.
    await tester.enterText(
        find.widgetWithText(TextField, 'Keywords'), 'storm, weather');
    await tester.enterText(
        find.widgetWithText(TextField, 'Entry'), 'Storms arrive in autumn.');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    final saved = state.lorebooks.single;
    expect(saved.name, 'Islands');
    final entry = saved.entries.single;
    expect(entry.name, 'Storms');
    expect(entry.keys, ['storm', 'weather']);
    expect(entry.content, 'Storms arrive in autumn.');
  });

  testWidgets('the chat panel switches a book on and off for this chat',
      (tester) async {
    final state = await ready();
    await state.addLorebook(kingdom());
    await tester.pumpWidget(host(
      state,
      Scaffold(body: ChatMemoryPanel(onBack: () {})),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('No lorebooks active'), findsOneWidget);

    await tester.tap(find.text('Add lorebook'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kingdom').last);
    await tester.pumpAndSettle();

    expect(state.active.lorebookIds, ['k']);
    expect(find.text('Kingdom'), findsOneWidget);
    expect(find.textContaining('1 entry'), findsOneWidget);

    // And off again, from the row itself.
    await tester.tap(find.byTooltip('Remove from this chat'));
    await tester.pumpAndSettle();
    expect(state.active.lorebookIds, isEmpty);
  });
}


