import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/chat_interface.dart';

void main() {
  test('defaults survive a JSON round trip', () {
    final restored = ChatInterface.fromJson(const ChatInterface().toJson());
    expect(restored, const ChatInterface());
  });

  test('a fully customised config round trips, colours included', () {
    const original = ChatInterface(
      showAvatars: false,
      avatarSize: 72,
      avatarShape: AvatarShape.rounded,
      avatarFit: AvatarFit.contain,
      textPlacement: TextPlacement.around,
      bubbles: false,
      fontSize: 20,
      bubbleOpacity: 0.5,
      userTextColor: 0xFF112233,
      botTextColor: 0xFF445566,
      userBubbleColor: 0xFF778899,
      botBubbleColor: 0xFFAABBCC,
      backgroundColor: 0xFF010203,
      avatarOffsetX: 12,
      avatarOffsetY: -8,
    );

    final restored = ChatInterface.fromJson(original.toJson());

    expect(restored, original);
    expect(restored.avatarShape, AvatarShape.rounded);
    expect(restored.textPlacement, TextPlacement.around);
    expect(restored.userTextColor, 0xFF112233);
    expect(restored.avatarOffset, const Offset(12, -8));
  });

  test('copyWith clears a colour to null (follow theme) via the sentinel', () {
    const withColour = ChatInterface(userTextColor: 0xFF112233);

    // Not passing the argument leaves it untouched...
    expect(withColour.copyWith().userTextColor, 0xFF112233);
    // ...passing null explicitly clears it.
    expect(withColour.copyWith(userTextColor: null).userTextColor, isNull);
    // ...and other fields are preserved when one is cleared.
    expect(withColour.copyWith(userTextColor: null).avatarSize, 44);
  });

  test('enum byName falls back to a sensible default for junk', () {
    expect(AvatarShape.byName('nonsense'), AvatarShape.circle);
    expect(AvatarFit.byName(null), AvatarFit.cover);
    expect(TextPlacement.byName(''), TextPlacement.beside);
  });

  test('unset colours are omitted from JSON, not written as null', () {
    final json = const ChatInterface().toJson();
    expect(json.containsKey('userTextColor'), isFalse);
    expect(json.containsKey('backgroundColor'), isFalse);
  });
}
