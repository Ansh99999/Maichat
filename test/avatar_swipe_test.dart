import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/gallery_image.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/avatar_swipe_sheet.dart';
import 'package:maichat/widgets/character_avatar.dart';
import 'package:maichat/widgets/message_bubble.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tapping an avatar in a chat opens that character's pictures to swipe through,
/// and choosing one applies it — here, or everywhere.
///
/// Drives the real [ChatScreen], because the chat and the settings preview are not
/// the same tree: the preview's avatars are drag handles and must stay inert.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// A chat with Aria, whose pool holds [pictures] refs (the first is worn).
  Future<AppState> chatWith({
    List<String> pictures = const ['local:one.png', 'local:two.png'],
    bool inGallery = true,
    Character? impersonating,
  }) async {
    final state = AppState();
    await state.init();
    final aria = Character(
      id: 'aria',
      name: 'Aria',
      firstMes: 'Hello.',
      avatar: pictures.isEmpty ? '' : pictures.first,
      avatars: pictures.skip(1).toList(),
    );
    await state.addCharacter(aria);
    if (impersonating != null) await state.addCharacter(impersonating);
    if (inGallery) {
      for (var i = 0; i < pictures.length; i++) {
        await state.saveGalleryImage(GalleryImage(
          id: 'img$i',
          image: pictures[i],
          title: 'Picture ${i + 1}',
          characterId: 'aria',
          createdAt: DateTime(2026, 4, 24, 12 - i),
        ));
      }
    }
    state.startChatWithCharacter(aria);
    // Avatars have to be on screen to be tapped.
    await state.updateChatInterface(const ChatInterface(
      botAvatar: AvatarStyle(size: 56, side: ChatSide.left),
      userAvatar: AvatarStyle(size: 56, side: ChatSide.right),
    ));
    if (impersonating != null) {
      await state.setImpersonation(impersonating);
    }
    return state;
  }

  Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: ChatScreen()),
      );

  /// Pumps the chat with explicit frames — the chat animates, so `pumpAndSettle`
  /// never returns.
  Future<void> pumpChat(WidgetTester tester, AppState state) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host(state));
    await tester.pump();
    await tester.pump();
  }

  /// Taps the avatar on a turn — the bot's by default, the user's with [user].
  ///
  /// Scoped to the message list on purpose: the composer's impersonate button is
  /// also a [CharacterAvatar], and it is the *last* one on screen, so a bare
  /// `find.byType(...).last` opens the impersonation picker instead.
  Future<void> openAvatar(WidgetTester tester, {bool user = false}) async {
    final avatars = find.descendant(
      of: find.byType(MessageBubble),
      matching: find.byType(CharacterAvatar),
    );
    await tester.tap(user ? avatars.last : avatars.first);
    await tester.pumpAndSettle();
  }

  group('the swipe viewer', () {
    testWidgets('tapping a character avatar opens their pictures',
        (tester) async {
      final state = await chatWith();
      await pumpChat(tester, state);

      await openAvatar(tester);
      expect(find.byType(AvatarSwipeScreen), findsOneWidget);
      expect(find.text('Aria'), findsWidgets);
      expect(find.text('1 / 2'), findsOneWidget,
          reason: 'opens at the picture being worn');
      for (final action in ['Set', 'Default', 'Float', 'Reset']) {
        expect(find.text(action), findsOneWidget, reason: action);
      }
    });

    testWidgets('Set applies a picture to this chat only', (tester) async {
      final state = await chatWith();
      await pumpChat(tester, state);
      await openAvatar(tester);

      // Swipe to the second picture, then keep it for this thread.
      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);

      await tester.tap(find.text('Set'));
      await tester.pumpAndSettle();

      expect(state.active.avatarOverrides['aria'], 'local:two.png');
      // The card is untouched — that is what makes it per-chat.
      expect(state.characterById('aria')!.avatar, 'local:one.png');
      // And the viewer closed, back to the chat.
      expect(find.byType(AvatarSwipeScreen), findsNothing);
    });

    testWidgets('Default changes the card, everywhere', (tester) async {
      final state = await chatWith();
      await pumpChat(tester, state);
      await openAvatar(tester);

      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Default'));
      await tester.pumpAndSettle();

      final aria = state.characterById('aria')!;
      expect(aria.avatar, 'local:two.png');
      // The old picture stays in the pool: trying a face loses nothing.
      expect(aria.avatars, ['local:one.png']);
      expect(state.active.avatarOverrides, isEmpty);
    });

    testWidgets('Reset is dead until this chat has a choice of its own',
        (tester) async {
      final state = await chatWith();
      await pumpChat(tester, state);
      await openAvatar(tester);

      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Reset'))
            .onPressed,
        isNull,
      );

      await tester.tap(find.text('Set'));
      await tester.pumpAndSettle();
      await openAvatar(tester);
      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();

      expect(state.active.avatarOverrides, isEmpty);
    });

    testWidgets('Float drops the picture onto the conversation', (tester) async {
      final state = await chatWith();
      await pumpChat(tester, state);
      await openAvatar(tester);

      await tester.tap(find.text('Float'));
      await tester.pumpAndSettle();

      expect(state.active.floatingImages.single.imageId, 'img0');
      expect(find.byType(AvatarSwipeScreen), findsNothing);
    });

    testWidgets('a picture that was never in the gallery still floats',
        (tester) async {
      // An avatar that arrived on an imported card was never a gallery record.
      // Floating is about looking at a picture, so it must work anyway — v1.14.0
      // refused, which is a distinction the user never asked for.
      final state = await chatWith(inGallery: false);
      await pumpChat(tester, state);
      await openAvatar(tester);

      await tester.tap(find.text('Float'));
      await tester.pumpAndSettle();

      final float = state.active.floatingImages.single;
      expect(float.imageRef, 'local:one.png');
      expect(float.imageId, isEmpty, reason: 'no record to tie it to');
      expect(state.floatingImagesFor(state.active).single.ref, 'local:one.png');
    });

    testWidgets('a picture the gallery does hold floats as that record',
        (tester) async {
      final state = await chatWith();
      await pumpChat(tester, state);
      await openAvatar(tester);

      await tester.tap(find.text('Float'));
      await tester.pumpAndSettle();

      // Tied to the record, so editing or deleting the picture reaches the float.
      final float = state.active.floatingImages.single;
      expect(float.imageId, 'img0');
      expect(float.imageRef, isEmpty);
    });

    testWidgets('a character with no picture is not opened at all',
        (tester) async {
      final state = await chatWith(pictures: const <String>[]);
      await pumpChat(tester, state);

      // The avatar still draws — as a monogram — but there is nothing behind it
      // to open, so the tap is deliberately inert.
      await tester.tap(find.descendant(
        of: find.byType(MessageBubble),
        matching: find.byType(CharacterAvatar),
      ).first);
      await tester.pumpAndSettle();
      expect(find.byType(AvatarSwipeScreen), findsNothing);
    });

    testWidgets('the user\'s avatar swipes only while impersonating',
        (tester) async {
      final plain = await chatWith();
      await pumpChat(tester, plain);
      // Speaking as themself, the user has no card and no pool, so their turns
      // wear a plain glyph — the only CharacterAvatar in the thread is the bot's.
      expect(
        find.descendant(
          of: find.byType(MessageBubble),
          matching: find.byType(CharacterAvatar),
        ),
        findsOneWidget,
      );

      final persona = Character(
        id: 'kai',
        name: 'Kai',
        avatar: 'local:kai.png',
        avatars: ['local:kai2.png'],
      );
      final impersonating = await chatWith(impersonating: persona);
      // A user turn to hang the user's avatar off. Added directly rather than via
      // `send`, which needs a provider and a network.
      impersonating.active.messages.add(
        ChatMessage(role: 'user', content: 'Hi there'),
      );
      await pumpChat(tester, impersonating);

      await openAvatar(tester, user: true);
      expect(find.byType(AvatarSwipeScreen), findsOneWidget);
      expect(find.text('Kai'), findsWidgets);
      expect(find.text('1 / 2'), findsOneWidget);

      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set'));
      await tester.pumpAndSettle();
      expect(impersonating.active.avatarOverrides['kai'], 'local:kai2.png');
    });
  });

  group('the chat draws the chosen picture', () {
    testWidgets('a per-chat choice reaches the bubble', (tester) async {
      final state = await chatWith();
      await pumpChat(tester, state);

      String? drawn() => tester
          .widget<CharacterAvatar>(find
              .descendant(
                of: find.byType(MessageBubble),
                matching: find.byType(CharacterAvatar),
              )
              .first)
          .avatarOverride;

      expect(drawn(), 'local:one.png');
      await state.setChatAvatar(state.active.id, 'aria', 'local:two.png');
      await tester.pump();
      await tester.pump();
      expect(drawn(), 'local:two.png');
    });

    testWidgets('the settings preview never makes an avatar tappable',
        (tester) async {
      // The preview passes `interactive`, where an avatar is a drag handle for
      // tuning the layout. Opening a viewer from there would fight the drag.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: ChatMessage(role: 'assistant', content: 'Hello.'),
            ui: const ChatInterface(
              botAvatar: AvatarStyle(size: 56, side: ChatSide.left),
            ),
            character: Character(id: 'a', name: 'Aria', avatar: 'local:a.png'),
            interactive: true,
            onAvatarTap: (_) => fail('the preview must not open a viewer'),
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(find.byType(CharacterAvatar).first, warnIfMissed: false);
      await tester.pump();
    });
  });
}
