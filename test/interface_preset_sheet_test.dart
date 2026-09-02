import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/interface_preset.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/screens/settings/chat_interface_settings_page.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/interface_preset_sheet.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Drives the looks sheet from both places it opens — the square over a chat and
/// the icon in the Chat Interface app bar — and the scope question a chat asks.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Widget host(AppState state, Widget page) =>
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(home: page),
      );

  /// A chat to open the sheet over.
  Future<AppState> chat() async {
    final state = AppState();
    await state.init();
    final character = Character.empty()
      ..name = 'Aria'
      ..firstMes = 'Evening.';
    await state.addCharacter(character);
    state.startChatWithCharacter(character);
    return state;
  }

  /// Opens the sheet directly, which is what both entry points do.
  ///
  /// A tall viewport, because the sheet is capped at 75% of the screen and the
  /// shipped looks alone fill a default 600-pixel test window — a saved look's ⋮
  /// would sit under the footer and no tap would land on it.
  Future<void> openSheet(
    WidgetTester tester,
    AppState state, {
    String? conversationId,
  }) async {
    tester.view.physicalSize = const Size(1000, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(
      state,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showInterfacePresetSheet(
                context,
                conversationId: conversationId,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }
  group('the sheet', () {
    testWidgets('offers the shipped looks and marks the one in force',
        (tester) async {
      final state = AppState();
      await state.init();
      await openSheet(tester, state);

      for (final preset in kBuiltInInterfacePresets) {
        expect(find.text(preset.name), findsOneWidget,
            reason: '${preset.name} is missing');
      }
      // A swatch each, so a saved look is recognisable without reading it.
      expect(find.byType(LookSwatch),
          findsNWidgets(kBuiltInInterfacePresets.length));
      // Defaults are the Bubbles look, so exactly one row reads as active.
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('saves the current look under a name', (tester) async {
      final state = AppState();
      await state.init();
      await state.updateChatInterface(const ChatInterface(fontSize: 22));
      await openSheet(tester, state);

      await tester.tap(find.text('Save this look'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Night reading');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(state.savedInterfacePresets.single.name, 'Night reading');
      expect(state.savedInterfacePresets.single.ui.fontSize, 22);
      expect(find.text('Night reading'), findsOneWidget);
    });

    testWidgets('a saved look can be renamed and dropped', (tester) async {
      final state = AppState();
      await state.init();
      await state.saveInterfacePreset('First');
      await openSheet(tester, state);

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Second');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(state.savedInterfacePresets.single.name, 'Second');

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(state.savedInterfacePresets, isEmpty);
    });

    testWidgets('no shipped look offers a menu', (tester) async {
      final state = AppState();
      await state.init();
      await openSheet(tester, state);
      // Nothing to rename, export or delete: they are code, not data.
      expect(find.byType(PopupMenuButton<String>), findsNothing);
    });
  });
  group('applying from inside a chat', () {
    testWidgets('asks who it is for, and "every chat" writes app-wide',
        (tester) async {
      final state = await chat();
      final id = state.active.id;
      await openSheet(tester, state, conversationId: id);

      await tester.tap(find.text('Document'));
      await tester.pumpAndSettle();

      // The question, with the app-wide answer preselected.
      expect(find.text('Apply “Document”'), findsOneWidget);
      expect(find.text('Every chat'), findsOneWidget);
      expect(find.text('This chat only'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();

      expect(state.chatInterface.bubbles, isFalse);
      expect(state.hasInterfaceOverride(state.conversationById(id)!), isFalse,
          reason: 'the app-wide answer must not pin the thread');
    });

    testWidgets('"this chat only" gives the thread its own copy',
        (tester) async {
      final state = await chat();
      final id = state.active.id;
      await openSheet(tester, state, conversationId: id);

      await tester.tap(find.text('Document'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('This chat only'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();

      expect(state.hasInterfaceOverride(state.conversationById(id)!), isTrue);
      expect(state.interfaceFor(state.conversationById(id)).bubbles, isFalse);
      // The app-wide look is untouched.
      expect(state.chatInterface.bubbles, isTrue);
    });

    testWidgets('cancelling changes nothing', (tester) async {
      final state = await chat();
      final id = state.active.id;
      final before = state.chatInterface;
      await openSheet(tester, state, conversationId: id);

      await tester.tap(find.text('Document'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(state.chatInterface, before);
      expect(state.hasInterfaceOverride(state.conversationById(id)!), isFalse);
    });

    testWidgets('from Settings there is no thread, so nothing is asked',
        (tester) async {
      final state = AppState();
      await state.init();
      await openSheet(tester, state);

      await tester.tap(find.text('Document'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Apply “'), findsNothing);
      expect(state.chatInterface.bubbles, isFalse);
    });
  });
  group('the two ways in', () {
    testWidgets('a square at the top-right of a chat raises it',
        (tester) async {
      final state = await chat();
      await tester.pumpWidget(host(state, const ChatScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      // Its own key, so it is not the menu square; its own opacity setting.
      expect(find.byKey(chatLooksButtonKey), findsOneWidget);
      final painted = tester.widget<Material>(find.byKey(chatLooksButtonKey));
      expect(painted.color?.a,
          closeTo(state.chatInterface.looksButtonOpacity, 0.001));

      await tester.tap(find.byKey(chatLooksButtonKey));
      await tester.pumpAndSettle();
      expect(find.text('Looks'), findsWidgets);
      expect(find.text('Document'), findsOneWidget);
    });

    testWidgets('turning it down leaves the menu square alone', (tester) async {
      final state = await chat();
      await state.updateChatInterface(
          state.chatInterface.copyWith(looksButtonOpacity: kMinChromeOpacity));
      await tester.pumpWidget(host(state, const ChatScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(tester.widget<Material>(find.byKey(chatLooksButtonKey)).color?.a,
          closeTo(kMinChromeOpacity, 0.001));
      expect(tester.widget<Material>(find.byKey(chatMenuButtonKey)).color?.a,
          closeTo(kDefaultChromeOpacity, 0.001));
    });

    testWidgets('the Chat Interface app bar offers it, per-chat does not',
        (tester) async {
      final state = AppState();
      await state.init();
      await tester.pumpWidget(host(state, const ChatInterfaceSettingsPage()));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Looks'));
      await tester.pumpAndSettle();
      expect(find.text('Document'), findsOneWidget);
    });
  });
}



