import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/screens/settings/chat_interface_settings_page.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Drives the Chat Interface settings page for the controls added alongside
/// corner-rounding levels, per-role name styling and message spacing.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: ChatInterfaceSettingsPage()),
      );

  // The page's own ListView, told apart from the nested (non-scrolling)
  // reorderable list in the Message actions section.
  final list = find.byType(Scrollable).first;

  Future<void> reveal(WidgetTester tester, Finder target) =>
      tester.scrollUntilVisible(target, 120, scrollable: list);

  Future<void> open(WidgetTester tester, String tile) async {
    await reveal(tester, find.text(tile));
    // `scrollUntilVisible` stops as soon as the row has been *built*, which on a
    // page this long can still leave it below the fold — bring it into view
    // before tapping it.
    await tester.ensureVisible(find.text(tile));
    await tester.pumpAndSettle();
    await tester.tap(find.text(tile));
    await tester.pumpAndSettle();
  }

  testWidgets('the roundness level only appears for a rounded avatar',
      (tester) async {
    final state = AppState();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await open(tester, 'Character avatar settings');

    // A circular avatar has nothing to choose.
    expect(find.text('Roundness'), findsNothing);

    await tester.tap(find.text('Rounded'));
    await tester.pumpAndSettle();
    expect(find.text('Roundness'), findsOneWidget);
    expect(state.chatInterface.botAvatar.shape, AvatarShape.rounded);
    // Defaults to the restrained middle of the scale.
    expect(state.chatInterface.botAvatar.corner, CornerRounding.m);

    // Pick a tighter level from the dropdown.
    await tester.tap(find.text('Roundness'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<CornerRounding>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('XS').last);
    await tester.pumpAndSettle();
    expect(state.chatInterface.botAvatar.corner, CornerRounding.xs);

    // Back to a circle and the level control goes away again.
    await tester.tap(find.text('Circle'));
    await tester.pumpAndSettle();
    expect(find.text('Roundness'), findsNothing);
  });

  testWidgets('message spacing is offered with its current value',
      (tester) async {
    final state = AppState();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    expect(find.text('Message spacing'), findsOneWidget);
    expect(find.text('${kDefaultMessageSpacing.round()} px'), findsOneWidget);
  });

  testWidgets('syncing names adopts the character style and mirrors edits',
      (tester) async {
    final state = AppState();
    state.updateChatInterface(const ChatInterface(
      showNames: true,
      botNameStyle: NameStyle(size: 20, align: NameAlign.end),
    ));
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await reveal(tester, find.text('Sync names'));
    await tester.tap(find.text('Sync names'));
    await tester.pumpAndSettle();

    // Adopting sync brings both labels into step immediately.
    expect(state.chatInterface.syncNames, isTrue);
    expect(state.chatInterface.userNameStyle.size, 20);
    expect(state.chatInterface.userNameStyle.align, NameAlign.end);

    // Editing one role now writes both.
    await open(tester, 'Your name');
    await tester.tap(find.text('Center').last);
    await tester.pumpAndSettle();
    expect(state.chatInterface.userNameStyle.align, NameAlign.center);
    expect(state.chatInterface.botNameStyle.align, NameAlign.center);
  });

  testWidgets('independent names keep each role to itself', (tester) async {
    final state = AppState();
    state.updateChatInterface(const ChatInterface(showNames: true));
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await open(tester, 'Character name');
    await tester.tap(find.text('Below').last);
    await tester.pumpAndSettle();

    expect(state.chatInterface.botNameStyle.position, NamePosition.below);
    expect(state.chatInterface.userNameStyle.position, NamePosition.above);
  });

  testWidgets('each name offers its own font', (tester) async {
    final state = AppState();
    state.updateChatInterface(const ChatInterface(showNames: true));
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await open(tester, 'Character name');
    expect(find.text('Font'), findsOneWidget);
    expect(find.text('Same as app font'), findsOneWidget);
  });

  testWidgets('each name offers a colour, a nudge and screen-wide alignment',
      (tester) async {
    final state = AppState();
    state.updateChatInterface(const ChatInterface(showNames: true));
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await open(tester, 'Character name');

    // Alignment reads as screen positions, not container-relative ones.
    expect(find.text('Left'), findsOneWidget);
    expect(find.text('Center'), findsOneWidget);
    expect(find.text('Right'), findsOneWidget);

    // A colour of its own, defaulting to the theme.
    expect(find.text('Colour'), findsOneWidget);
    expect(find.text('Auto (theme)'), findsOneWidget);

    // The nudge is settable without dragging anything.
    expect(find.text('Nudge across'), findsOneWidget);
    expect(find.text('Nudge down'), findsOneWidget);
    final sliders = tester.widgetList<Slider>(find.byType(Slider));
    expect(sliders.any((s) => s.min == -kMaxNameOffset), isTrue);
    // The size ceiling is a headline, not a caption.
    expect(sliders.any((s) => s.max == kMaxNameSize), isTrue);
  });

  testWidgets('says so when "below" cannot mean below the avatar',
      (tester) async {
    final state = AppState();
    // Text wrapped around an inline avatar: there is no avatar bottom to hang a
    // name from, so the fallback has to be stated rather than silently applied.
    state.updateChatInterface(const ChatInterface(
      showNames: true,
      textPlacement: TextPlacement.around,
      botNameStyle: NameStyle(position: NamePosition.below),
    ));
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await open(tester, 'Character name');
    expect(find.textContaining('sits under the message'), findsOneWidget);

    // With the avatar beside the text there is nothing to warn about.
    state.updateChatInterface(const ChatInterface(
      showNames: true,
      textPlacement: TextPlacement.beside,
      botNameStyle: NameStyle(position: NamePosition.below),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('sits under the message'), findsNothing);
  });

  group('text wrapping', () {
    /// The section sits at the bottom of a long page; a tall viewport puts the
    /// whole of it on screen so the taps don't depend on scroll arithmetic.
    Future<void> pumpTall(WidgetTester tester, AppState state) async {
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host(state));
      await tester.pumpAndSettle();
    }

    testWidgets('a rule can be added through the sheet', (tester) async {
      final state = AppState();
      await pumpTall(tester, state);

      await tester.tap(find.text('Add wrapping rule'));
      await tester.pumpAndSettle();

      // Nothing to save until both symbols are given.
      final save = find.widgetWithText(FilledButton, 'Save');
      expect(tester.widget<FilledButton>(save).onPressed, isNull);

      await tester.enterText(find.widgetWithText(TextField, 'Start symbol'), '<');
      await tester.enterText(find.widgetWithText(TextField, 'End symbol'), '>');
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);

      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(state.chatInterface.textWrapRules, hasLength(1));
      final rule = state.chatInterface.textWrapRules.single;
      expect(rule.start, '<');
      expect(rule.end, '>');
      // Hiding the symbols is the default, matching how asterisks behave.
      expect(rule.hideMarkers, isTrue);
    });

    testWidgets('a rule can be switched off and removed', (tester) async {
      final state = AppState();
      state.updateChatInterface(const ChatInterface(textWrapRules: [
        TextWrapRule(start: '<', end: '>', color: 0xFFFFCC00),
      ]));
      await pumpTall(tester, state);

      // Scope every finder to the rule's own card: the page has other switches,
      // and the message-actions list has its own delete icon.
      final card = find.ancestor(
        of: find.textContaining('symbols hidden'),
        matching: find.byType(Card),
      );
      await tester.tap(find.descendant(of: card, matching: find.byType(Switch)));
      await tester.pumpAndSettle();
      expect(state.chatInterface.textWrapRules.single.enabled, isFalse);
      expect(state.chatInterface.activeTextWrapRules, isEmpty);

      await tester.tap(find.descendant(
          of: card, matching: find.byIcon(Icons.delete_outline)));
      await tester.pumpAndSettle();
      expect(state.chatInterface.textWrapRules, isEmpty);
    });

    testWidgets('says so when markdown is off', (tester) async {
      final state = AppState();
      state.updateChatInterface(const ChatInterface(
        markdown: false,
        textWrapRules: [TextWrapRule(start: '<', end: '>')],
      ));
      await pumpTall(tester, state);
      expect(find.textContaining('Markdown is off'), findsOneWidget);

      state.updateChatInterface(
          state.chatInterface.copyWith(markdown: true));
      await tester.pumpAndSettle();
      expect(find.textContaining('Markdown is off'), findsNothing);
    });
  });
}
