import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/screens/chat_export.dart';
import 'package:maichat/screens/library/lorebooks_screen.dart';
import 'package:maichat/screens/presets/presets_screen.dart';
import 'package:maichat/screens/settings/about_settings_page.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/app_drawer.dart';
import 'package:maichat/widgets/brand_mark.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Drives the real screens that name the app, and asserts the mark actually
/// reaches the pixels there.
///
/// The point of these, over the widget-level tests in `brand_mark_test.dart`, is
/// the wiring: a picker that builds its rows from an enum, a sheet whose
/// subtitle is a format label passed down from a caller, and a drawer header
/// that shows a different word inside Discover are each a place the mark can
/// silently fail to appear. They also pin down that the *other* options — the
/// SillyTavern and Agnai rows — do not get one.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// Gives the test a phone-shaped surface, so the sheets are laid out the way
  /// they are on a device rather than in a squat 800×600 desktop window.
  Future<void> phone(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

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

  /// The MaiChatMark inside the row that holds [label], if there is one.
  Finder markIn(String label) => find.descendant(
        of: find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
        matching: find.byType(MaiChatMark),
      );

  group('format pickers', () {
    testWidgets('the chat export sheet marks MaiChat and nothing else',
        (tester) async {
      await phone(tester);
      final state = await ready();
      state.newConversation();

      await tester.pumpWidget(host(
        state,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => exportChat(
                  context, context.read<AppState>().conversations.first),
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      // All four shapes are offered; only ours wears the logo.
      expect(find.text('MaiChat'), findsOneWidget);
      expect(find.text('SillyTavern / Agnai'), findsOneWidget);
      expect(markIn('MaiChat'), findsOneWidget);
      expect(markIn('SillyTavern / Agnai'), findsNothing);
      expect(markIn('Agnai'), findsNothing);
      expect(markIn('Plain text'), findsNothing);
      expect(find.byType(MaiChatMark), findsOneWidget);
    });

    testWidgets('picking it carries the mark into the save sheet',
        (tester) async {
      // offerExport's subtitle is the chosen format's label, so the second
      // sheet names MaiChat too — via BrandedText, not a leading slot.
      await phone(tester);
      final state = await ready();
      state.newConversation();

      await tester.pumpWidget(host(
        state,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => exportChat(
                  context, context.read<AppState>().conversations.first),
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MaiChat'));
      await tester.pumpAndSettle();

      expect(find.text('Save as .json file'), findsOneWidget);
      expect(find.byType(MaiChatMark), findsOneWidget);
    });

    testWidgets('the lorebook export sheet marks only the native shape',
        (tester) async {
      final state = await ready();
      await state.addLorebook(Lorebook(id: 'k', name: 'Kingdom', entries: const []));
      await tester.pumpWidget(host(state, const LorebooksScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();

      expect(markIn('MaiChat'), findsOneWidget);
      expect(markIn('SillyTavern / Agnai'), findsNothing);
      expect(find.byType(MaiChatMark), findsOneWidget);
    });

    testWidgets('the lorebook import sheet marks the name inside a sentence',
        (tester) async {
      final state = await ready();
      await tester.pumpWidget(host(state, const LorebooksScreen()));
      await tester.pumpAndSettle();

      // The Import action, not the "+" beside it — that one opens the editor.
      await tester.tap(find.byTooltip('Import'));
      await tester.pumpAndSettle();

      // The subtitle lists four ecosystems in prose; the mark rides the one
      // word, so it appears exactly once even though three apps are named.
      expect(find.textContaining('MaiChat export'), findsOneWidget);
      expect(find.byType(MaiChatMark), findsOneWidget);
    });

    testWidgets('the preset export sheet marks the native shape',
        (tester) async {
      final state = await ready();
      await tester.pumpWidget(host(state, const PresetsScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();

      expect(markIn('MaiChat (native)'), findsOneWidget);
      expect(markIn('SillyTavern preset'), findsNothing);
      expect(markIn('Agnai preset'), findsNothing);
      expect(find.byType(MaiChatMark), findsOneWidget);
    });
  });

  group('the places the app names itself', () {
    testWidgets('the drawer header wears the mark, Discover does not',
        (tester) async {
      final state = await ready();
      await tester.pumpWidget(host(state, const AppDrawer()));
      await tester.pumpAndSettle();
      expect(find.byType(MaiChatMark), findsOneWidget);

      // Inside Discover the same header names the catalogue browser, so there is
      // nothing to brand — and branding it anyway would be wrong.
      await tester.pumpWidget(host(state, const AppDrawer(catalogues: [])));
      await tester.pumpAndSettle();
      expect(find.text('Discover'), findsOneWidget);
      expect(find.byType(MaiChatMark), findsNothing);
    });

    testWidgets('About leads with the mark instead of an info glyph',
        (tester) async {
      final state = await ready();
      await tester.pumpWidget(host(state, const AboutSettingsPage()));
      await tester.pumpAndSettle();
      expect(markIn('MaiChat'), findsOneWidget);
      expect(find.byIcon(Icons.info_outline), findsNothing);
    });
  });
}
