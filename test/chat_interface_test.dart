import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/chat_interface.dart';

void main() {
  test('defaults survive a JSON round trip', () {
    final restored = ChatInterface.fromJson(const ChatInterface().toJson());
    expect(restored, const ChatInterface());
    // Defaults put the bot on the left and the user on the right.
    expect(restored.botAvatar.side, ChatSide.left);
    expect(restored.userAvatar.side, ChatSide.right);
  });

  test('a fully customised config round trips, per-role and colours', () {
    const original = ChatInterface(
      botAvatar: AvatarStyle(
        show: true,
        size: 96,
        shape: AvatarShape.rounded,
        fit: AvatarFit.free,
        side: ChatSide.left,
        offsetX: 10,
        offsetY: -4,
      ),
      userAvatar: AvatarStyle(
        show: false,
        size: 40,
        shape: AvatarShape.square,
        fit: AvatarFit.contain,
        side: ChatSide.left,
      ),
      syncAvatars: false,
      textPlacement: TextPlacement.around,
      bubbles: false,
      fontSize: 20,
      bubbleOpacity: 0.5,
      showNames: true,
      userName: 'Ansh',
      markdown: false,
      userTextColor: 0xFF112233,
      botBubbleColor: 0xFFAABBCC,
      backgroundColor: 0xFF010203,
      emphasisColor: 0xFF00FF00,
      quoteColor: 0xFF123456,
    );

    final restored = ChatInterface.fromJson(original.toJson());

    expect(restored, original);
    expect(restored.botAvatar.fit, AvatarFit.free);
    expect(restored.userAvatar.side, ChatSide.left);
    expect(restored.userName, 'Ansh');
    expect(restored.markdown, isFalse);
    expect(restored.emphasisColor, 0xFF00FF00);
    expect(restored.quoteColor, 0xFF123456);
    expect(restored.botAvatar.offset.dx, 10);
  });

  test('name typography + alignment round trip', () {
    const original = ChatInterface(
      showNames: true,
      botNameSize: 18,
      userNameSize: 9,
      botNameAlign: NameAlign.center,
      userNameAlign: NameAlign.end,
      botNamePosition: NamePosition.below,
      userNamePosition: NamePosition.above,
    );
    final restored = ChatInterface.fromJson(original.toJson());
    expect(restored, original);
    expect(restored.botNameSize, 18);
    expect(restored.userNameSize, 9);
    expect(restored.botNameAlign, NameAlign.center);
    expect(restored.userNameAlign, NameAlign.end);
    expect(restored.botNamePosition, NamePosition.below);
    expect(restored.userNamePosition, NamePosition.above);
  });

  test('name defaults and enum byName fall back sensibly', () {
    const ui = ChatInterface();
    expect(ui.botNameSize, 12);
    expect(ui.userNameSize, 12);
    expect(ui.botNameAlign, NameAlign.start);
    expect(ui.userNameAlign, NameAlign.start);
    expect(ui.botNamePosition, NamePosition.above);
    expect(ui.userNamePosition, NamePosition.above);
    expect(NameAlign.byName('nonsense'), NameAlign.start);
    expect(NameAlign.byName('center'), NameAlign.center);
    expect(NameAlign.center.textAlign, TextAlign.center);
    expect(NamePosition.byName('nonsense'), NamePosition.above);
    expect(NamePosition.byName('below'), NamePosition.below);
  });

  test('copyWith clears a colour to null (follow theme) via the sentinel', () {
    const withColour = ChatInterface(userTextColor: 0xFF112233);
    expect(withColour.copyWith().userTextColor, 0xFF112233);
    expect(withColour.copyWith(userTextColor: null).userTextColor, isNull);
    expect(withColour.copyWith(userTextColor: null).userName, 'You');
  });

  test('unset colours are omitted from JSON, not written as null', () {
    final json = const ChatInterface().toJson();
    expect(json.containsKey('userTextColor'), isFalse);
    expect(json.containsKey('backgroundColor'), isFalse);
  });

  test('enum byName falls back sensibly for junk', () {
    expect(AvatarShape.byName('nonsense'), AvatarShape.circle);
    expect(AvatarFit.byName(null), AvatarFit.cover);
    expect(TextPlacement.byName(''), TextPlacement.beside);
    expect(ChatSide.byName('x', fallback: ChatSide.right), ChatSide.right);
  });

  test('migrates the old single-avatar shape onto both roles', () {
    // The pre-split JSON had flat avatar fields and one offset.
    final legacy = {
      'showAvatars': true,
      'avatarSize': 72.0,
      'avatarShape': 'rounded',
      'avatarFit': 'contain',
      'textPlacement': 'below',
      'bubbles': false,
      'fontSize': 18.0,
      'avatarOffsetX': 5.0,
      'avatarOffsetY': 6.0,
      'userTextColor': 0xFF445566,
    };

    final migrated = ChatInterface.fromJson(legacy);

    // Both avatars pick up the old look; only the default side differs.
    expect(migrated.botAvatar.size, 72);
    expect(migrated.userAvatar.size, 72);
    expect(migrated.botAvatar.shape, AvatarShape.rounded);
    expect(migrated.userAvatar.fit, AvatarFit.contain);
    expect(migrated.botAvatar.side, ChatSide.left);
    expect(migrated.userAvatar.side, ChatSide.right);
    expect(migrated.bubbles, isFalse);
    expect(migrated.textPlacement, TextPlacement.below);
    expect(migrated.userTextColor, 0xFF445566);
  });

  test('withAvatar respects the sync flag', () {
    const base = ChatInterface(syncAvatars: false);

    // Unsynced: editing the bot leaves the user untouched.
    final unsynced = base.withAvatar(false, base.botAvatar.copyWith(size: 100));
    expect(unsynced.botAvatar.size, 100);
    expect(unsynced.userAvatar.size, 44);

    // Synced: the look mirrors to both, but each keeps its own side.
    const synced = ChatInterface(syncAvatars: true);
    final next =
        synced.withAvatar(false, synced.botAvatar.copyWith(size: 100));
    expect(next.botAvatar.size, 100);
    expect(next.userAvatar.size, 100);
    expect(next.botAvatar.side, ChatSide.left);
    expect(next.userAvatar.side, ChatSide.right);
  });
}
