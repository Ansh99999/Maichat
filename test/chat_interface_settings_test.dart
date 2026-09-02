import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/screens/settings/chat_interface/actions_page.dart';
import 'package:maichat/screens/settings/chat_interface/avatars_page.dart';
import 'package:maichat/screens/settings/chat_interface/colours_page.dart';
import 'package:maichat/screens/settings/chat_interface/controls.dart';
import 'package:maichat/screens/settings/chat_interface/layout_page.dart';
import 'package:maichat/screens/settings/chat_interface/names_page.dart';
import 'package:maichat/screens/settings/chat_interface/text_page.dart';
import 'package:maichat/screens/settings/chat_interface_settings_page.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Drives the Chat Interface hub and its spokes: the avatar/name fold, the
/// per-spoke resets, the hub's summaries, and the wrapping-rule editor.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Widget host(AppState state, Widget page) =>
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(home: page),
      );

  /// A tall viewport, so a spoke's rows are all on screen and no test depends on
  /// scroll arithmetic. The spokes are short by design; this makes that pay off.
  Future<void> pump(WidgetTester tester, AppState state, Widget page) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(state, page));
    await tester.pumpAndSettle();
  }

  group('the hub', () {
    testWidgets('leads to six spokes and says where each stands',
        (tester) async {
      final state = AppState();
      await pump(tester, state, const ChatInterfaceSettingsPage());

      for (final row in const [
        'Layout & spacing',
        'Avatars',
        'Names',
        'Colours',
        'Text',
        'Message actions',
      ]) {
        expect(find.text(row), findsOneWidget, reason: '$row row is missing');
      }

      // Defaults: nothing has been changed, so no pill anywhere.
      expect(find.textContaining('changed'), findsNothing);
      expect(find.text('Hidden'), findsOneWidget); // names are off by default
    });
    testWidgets('counts what has been changed away from the defaults',
        (tester) async {
      final state = AppState();
      // Three of Layout's seven fields, and one colour.
      await state.updateChatInterface(const ChatInterface(
        bubbles: false,
        contentWidth: ContentWidth.full,
        messageSpacing: 30,
        botTextColor: 0xFF112233,
      ));
      await pump(tester, state, const ChatInterfaceSettingsPage());

      expect(find.text('3 changed'), findsOneWidget);
      expect(find.text('1 changed'), findsOneWidget);
      expect(find.text('Theme, with 1 overridden'), findsOneWidget);
      expect(find.text('Document · Beside · Full · 30 px gap'), findsOneWidget);
    });

    testWidgets('the group-chat bar appears only once group chats are on',
        (tester) async {
      final state = AppState();
      await pump(tester, state, const ChatInterfaceSettingsPage());
      expect(find.text('Group chat bar'), findsNothing);

      await state.updateChatInterface(
          state.chatInterface.copyWith(groupChatsEnabled: true));
      await tester.pumpAndSettle();
      expect(find.text('Group chat bar'), findsOneWidget);
    });

    testWidgets('a row opens its spoke', (tester) async {
      final state = AppState();
      await pump(tester, state, const ChatInterfaceSettingsPage());

      await tester.tap(find.text('Avatars'));
      await tester.pumpAndSettle();

      // The spoke, not the hub: its own app bar and its own controls.
      expect(find.text('Whose avatar'), findsOneWidget);
      expect(find.text('Reset avatars to defaults'), findsOneWidget);
    });

    testWidgets('every spoke offers the live preview', (tester) async {
      final state = AppState();
      await pump(tester, state, const LayoutSpokePage());
      // The screenshot generator reaches the preview by this tooltip, so it has
      // to be on the spokes too — not just on the hub it used to sit on.
      expect(find.byTooltip('Preview'), findsOneWidget);
    });
  });
  group('avatars, one editor for both roles', () {
    testWidgets('the roundness level only appears for a rounded avatar',
        (tester) async {
      final state = AppState();
      await pump(tester, state, const AvatarsSpokePage());

      // A circular avatar has nothing to choose.
      expect(find.text('Roundness'), findsNothing);

      await tester.tap(find.text('Rounded'));
      await tester.pumpAndSettle();
      expect(find.text('Roundness'), findsOneWidget);
      expect(state.chatInterface.botAvatar.shape, AvatarShape.rounded);
      // Defaults to the restrained middle of the scale.
      expect(state.chatInterface.botAvatar.corner, CornerRounding.m);

      // Pick a tighter level from the dropdown.
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

    testWidgets('the selector switches which role is written', (tester) async {
      final state = AppState();
      await pump(tester, state, const AvatarsSpokePage());

      // Character is the default side of the selector.
      await tester.tap(find.text('Square'));
      await tester.pumpAndSettle();
      expect(state.chatInterface.botAvatar.shape, AvatarShape.square);
      expect(state.chatInterface.userAvatar.shape, AvatarShape.circle);

      await tester.tap(find.text('You'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rounded'));
      await tester.pumpAndSettle();
      expect(state.chatInterface.userAvatar.shape, AvatarShape.rounded);
      // The character's own choice is untouched.
      expect(state.chatInterface.botAvatar.shape, AvatarShape.square);
    });
    // The matrix that matters for the fold: {Character, You} × {synced,
    // unsynced}. A synced write mirrors the look and leaves each role its own
    // side, which is what `AvatarStyle.matchLook` promises.
    for (final isUser in [false, true]) {
      final who = isUser ? 'You' : 'Character';
      testWidgets('synced, editing "$who" writes both looks but one side',
          (tester) async {
        final state = AppState();
        // Both start on the left, so "kept its own side" and "mirrored the
        // other's" are different outcomes and the assertion can tell them apart.
        await state.updateChatInterface(const ChatInterface(
          syncAvatars: true,
          botAvatar: AvatarStyle(side: ChatSide.left),
          userAvatar: AvatarStyle(side: ChatSide.left),
        ));
        await pump(tester, state, const AvatarsSpokePage());
        if (isUser) {
          await tester.tap(find.text('You'));
          await tester.pumpAndSettle();
        }

        await tester.tap(find.text('Square'));
        await tester.pumpAndSettle();
        // The look reached both.
        expect(state.chatInterface.botAvatar.shape, AvatarShape.square);
        expect(state.chatInterface.userAvatar.shape, AvatarShape.square);

        // The side reached only the role on screen; the other kept its own.
        await tester.tap(find.text('Right'));
        await tester.pumpAndSettle();
        expect(state.chatInterface.avatarFor(isUser).side, ChatSide.right);
        expect(state.chatInterface.avatarFor(!isUser).side, ChatSide.left);
      });

      testWidgets('unsynced, editing "$who" leaves the other alone',
          (tester) async {
        final state = AppState();
        await pump(tester, state, const AvatarsSpokePage());
        if (isUser) {
          await tester.tap(find.text('You'));
          await tester.pumpAndSettle();
        }

        await tester.tap(find.text('Square'));
        await tester.pumpAndSettle();
        expect(state.chatInterface.avatarFor(isUser).shape, AvatarShape.square);
        expect(state.chatInterface.avatarFor(!isUser).shape, AvatarShape.circle);
      });
    }
    testWidgets('the nudge pad moves the avatar and offers a reset',
        (tester) async {
      final state = AppState();
      await pump(tester, state, const AvatarsSpokePage());

      expect(find.text('Reset'), findsNothing);
      await tester.drag(find.byKey(kNudgePadKey), const Offset(8, 5));
      await tester.pumpAndSettle();

      final avatar = state.chatInterface.botAvatar;
      expect(avatar.offsetX, greaterThan(0));
      expect(avatar.offsetY, greaterThan(0));
      expect(avatar.offsetX, lessThanOrEqualTo(kMaxAvatarNudge));
      expect(avatar.offsetY, lessThanOrEqualTo(kMaxAvatarNudge));

      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();
      expect(state.chatInterface.botAvatar.offsetX, 0);
      expect(state.chatInterface.botAvatar.offsetY, 0);
    });

    testWidgets('reset puts both avatars back and leaves the rest alone',
        (tester) async {
      final state = AppState();
      await state.updateChatInterface(const ChatInterface(
        syncAvatars: true,
        botAvatar: AvatarStyle(size: 90, shape: AvatarShape.square),
        userAvatar: AvatarStyle(size: 90, shape: AvatarShape.square),
        messageSpacing: 30,
        showNames: true,
      ));
      await pump(tester, state, const AvatarsSpokePage());

      await tester.tap(find.text('Reset avatars to defaults'));
      await tester.pumpAndSettle();

      const d = ChatInterface();
      expect(state.chatInterface.botAvatar, d.botAvatar);
      expect(state.chatInterface.userAvatar, d.userAvatar);
      expect(state.chatInterface.syncAvatars, d.syncAvatars);
      // Another spoke's settings are none of its business.
      expect(state.chatInterface.messageSpacing, 30);
      expect(state.chatInterface.showNames, isTrue);
    });
  });
  group('names', () {
    testWidgets('syncing adopts the character style and mirrors edits',
        (tester) async {
      final state = AppState();
      await state.updateChatInterface(const ChatInterface(
        showNames: true,
        botNameStyle: NameStyle(size: 20, align: NameAlign.end),
      ));
      await pump(tester, state, const NamesSpokePage());

      await tester.tap(find.text('Sync the two'));
      await tester.pumpAndSettle();

      // Adopting sync brings both labels into step immediately.
      expect(state.chatInterface.syncNames, isTrue);
      expect(state.chatInterface.userNameStyle.size, 20);
      expect(state.chatInterface.userNameStyle.align, NameAlign.end);

      // Synced, there is no role to choose — the selector would do nothing.
      expect(find.text('Whose name'), findsNothing);

      // And an edit now writes both.
      await tester.tap(find.text('Center'));
      await tester.pumpAndSettle();
      expect(state.chatInterface.userNameStyle.align, NameAlign.center);
      expect(state.chatInterface.botNameStyle.align, NameAlign.center);
    });

    testWidgets('independent names keep each role to itself', (tester) async {
      final state = AppState();
      await state.updateChatInterface(const ChatInterface(showNames: true));
      await pump(tester, state, const NamesSpokePage());

      expect(find.text('Whose name'), findsOneWidget);
      await tester.tap(find.text('Below'));
      await tester.pumpAndSettle();

      expect(state.chatInterface.botNameStyle.position, NamePosition.below);
      expect(state.chatInterface.userNameStyle.position, NamePosition.above);
    });

    testWidgets('each name offers its own font', (tester) async {
      final state = AppState();
      await state.updateChatInterface(const ChatInterface(showNames: true));
      await pump(tester, state, const NamesSpokePage());

      expect(find.text('Font'), findsOneWidget);
      expect(find.text('Same as app font'), findsOneWidget);
    });
    testWidgets('a name offers a colour, a nudge and screen-wide alignment',
        (tester) async {
      final state = AppState();
      await state.updateChatInterface(const ChatInterface(showNames: true));
      await pump(tester, state, const NamesSpokePage());

      // Alignment reads as screen positions, not container-relative ones.
      expect(find.text('Left'), findsOneWidget);
      expect(find.text('Center'), findsOneWidget);
      expect(find.text('Right'), findsOneWidget);

      // A colour of its own, defaulting to the theme.
      expect(find.text('Colour'), findsOneWidget);
      expect(find.text('Auto (theme)'), findsOneWidget);

      // The size ceiling is a headline, not a caption.
      final sliders = tester.widgetList<Slider>(find.byType(Slider));
      expect(sliders.any((s) => s.max == kMaxNameSize), isTrue);

      // One pad in place of what used to be two sliders and a reset row.
      expect(find.byType(NudgePad), findsOneWidget);
      await tester.drag(find.byKey(kNudgePadKey), const Offset(-6, 4));
      await tester.pumpAndSettle();
      expect(state.chatInterface.botNameStyle.offsetX, lessThan(0));
      expect(state.chatInterface.botNameStyle.offsetY, greaterThan(0));
      expect(state.chatInterface.botNameStyle.offsetX.abs(),
          lessThanOrEqualTo(kMaxNameOffset));
    });

    testWidgets('says so when "below" cannot mean below the avatar',
        (tester) async {
      final state = AppState();
      // Text wrapped around an inline avatar: there is no avatar bottom to hang
      // a name from, so the fallback has to be stated rather than silently
      // applied.
      await state.updateChatInterface(const ChatInterface(
        showNames: true,
        textPlacement: TextPlacement.around,
        botNameStyle: NameStyle(position: NamePosition.below),
      ));
      await pump(tester, state, const NamesSpokePage());
      expect(find.textContaining('sits under the message'), findsOneWidget);

      // With the avatar beside the text there is nothing to warn about.
      await state.updateChatInterface(const ChatInterface(
        showNames: true,
        textPlacement: TextPlacement.beside,
        botNameStyle: NameStyle(position: NamePosition.below),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('sits under the message'), findsNothing);
    });

    testWidgets('nothing below the switch matters while names are off',
        (tester) async {
      final state = AppState();
      await pump(tester, state, const NamesSpokePage());
      expect(find.textContaining('Names are off'), findsOneWidget);
      expect(find.byType(NudgePad), findsNothing);
    });
  });
  group('layout, colours and actions', () {
    testWidgets('message spacing is offered with its current value',
        (tester) async {
      final state = AppState();
      await pump(tester, state, const LayoutSpokePage());

      expect(find.text('Message spacing'), findsOneWidget);
      expect(find.text('${kDefaultMessageSpacing.round()} px'), findsOneWidget);
    });

    testWidgets('the floating buttons come home to layout', (tester) async {
      final state = AppState();
      await pump(tester, state, const LayoutSpokePage());

      expect(find.text('Menu button opacity'), findsOneWidget);
      expect(find.text('Jump-to-latest opacity'), findsOneWidget);
    });

    testWidgets('resetting layout leaves the other spokes alone',
        (tester) async {
      final state = AppState();
      await state.updateChatInterface(const ChatInterface(
        bubbles: false,
        messageSpacing: 40,
        menuButtonOpacity: 1,
        botTextColor: 0xFF001122,
        showNames: true,
      ));
      await pump(tester, state, const LayoutSpokePage());

      await tester.tap(find.text('Reset layout to defaults'));
      await tester.pumpAndSettle();

      const d = ChatInterface();
      expect(state.chatInterface.bubbles, d.bubbles);
      expect(state.chatInterface.messageSpacing, d.messageSpacing);
      expect(state.chatInterface.menuButtonOpacity, d.menuButtonOpacity);
      expect(state.chatInterface.botTextColor, 0xFF001122);
      expect(state.chatInterface.showNames, isTrue);
    });

    testWidgets('colours hands a colour back to the theme', (tester) async {
      final state = AppState();
      await state.updateChatInterface(const ChatInterface(
        userTextColor: 0xFF445566,
        backgroundColor: 0xFF778899,
      ));
      await pump(tester, state, const ColoursSpokePage());

      await tester.tap(find.text('Follow the theme again'));
      await tester.pumpAndSettle();
      expect(state.chatInterface.userTextColor, isNull);
      expect(state.chatInterface.backgroundColor, isNull);
    });
    testWidgets('the markup colours travel with markdown, not with the bubbles',
        (tester) async {
      final state = AppState();
      await pump(tester, state, const TextSpokePage());

      // Emphasis and quotes belong beside the wrapping rules that generalise
      // them, so this is the page that holds them.
      expect(find.text('Emphasis (*italic* / **bold**)'), findsOneWidget);
      expect(find.text('Quoted "text"'), findsOneWidget);
      expect(find.text('Font size'), findsOneWidget);

      await pump(tester, state, const ColoursSpokePage());
      expect(find.text('Emphasis (*italic* / **bold**)'), findsNothing);
      expect(find.text('Font size'), findsNothing);
    });

    testWidgets('an action can be moved between inline and the menu',
        (tester) async {
      final state = AppState();
      await pump(tester, state, const ActionsSpokePage());

      // Copy ships in the overflow; move it inline.
      final row = find.ancestor(
        of: find.text('Copy'),
        matching: find.byType(Row),
      );
      await tester.tap(find.descendant(
          of: row.first, matching: find.text('Inline')));
      await tester.pumpAndSettle();
      expect(state.chatInterface.inlineActions, contains(MessageAction.copy));
    });
  });
  group('text wrapping', () {
    testWidgets('a rule can be added through the sheet', (tester) async {
      final state = AppState();
      await pump(tester, state, const TextSpokePage());

      await tester.tap(find.text('Add wrapping rule'));
      await tester.pumpAndSettle();

      // Nothing to save until both symbols are given.
      final save = find.widgetWithText(FilledButton, 'Save');
      expect(tester.widget<FilledButton>(save).onPressed, isNull);

      await tester.enterText(
          find.widgetWithText(TextField, 'Start symbol'), '<');
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
      await state.updateChatInterface(const ChatInterface(textWrapRules: [
        TextWrapRule(start: '<', end: '>', color: 0xFFFFCC00),
      ]));
      await pump(tester, state, const TextSpokePage());

      // Scope every finder to the rule's own card: the page has other switches.
      final card = find.ancestor(
        of: find.textContaining('symbols hidden'),
        matching: find.byType(Card),
      );
      await tester.tap(
          find.descendant(of: card, matching: find.byType(Switch)));
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
      await state.updateChatInterface(const ChatInterface(
        markdown: false,
        textWrapRules: [TextWrapRule(start: '<', end: '>')],
      ));
      await pump(tester, state, const TextSpokePage());
      expect(find.textContaining('Markdown is off'), findsOneWidget);

      await state.updateChatInterface(
          state.chatInterface.copyWith(markdown: true));
      await tester.pumpAndSettle();
      expect(find.textContaining('Markdown is off'), findsNothing);
    });
  });
}









