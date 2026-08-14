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
}
