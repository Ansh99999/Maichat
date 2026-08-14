import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/widgets/avatar_image.dart';
import 'package:maichat/widgets/character_avatar.dart';
import 'package:maichat/widgets/message_bubble.dart';

/// A 1x1 PNG — the pixel count is irrelevant here; what is being measured is
/// how many *distinct* providers and cache entries one avatar produces.
const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8DAwAAABQABg1z0GwAAAABJRU5ErkJggg==';

Character _sumire() => Character(id: 'sumire', name: 'Sumire', avatar: _png);

void main() {
  setUp(() {
    clearAvatarImageCache();
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  group('avatar providers', () {
    test('the same picture at the same size is the same provider', () {
      final a = avatarImage(_png, displaySize: 48, devicePixelRatio: 3);
      final b = avatarImage(_png, displaySize: 48, devicePixelRatio: 3);
      expect(a, isNotNull);
      // Identity, not just equality: this is what keeps the image cache to one
      // entry and the base64 decode to one run.
      expect(identical(a, b), isTrue);
    });

    test('a very different display size gets its own, larger decode', () {
      final small = avatarImage(_png, displaySize: 40, devicePixelRatio: 1);
      final large = avatarImage(_png, displaySize: 300, devicePixelRatio: 3);
      expect(identical(small, large), isFalse);
    });

    test('nearby sizes share a bucket', () {
      final a = avatarImage(_png, displaySize: 40, devicePixelRatio: 1);
      final b = avatarImage(_png, displaySize: 52, devicePixelRatio: 1);
      expect(identical(a, b), isTrue);
    });

    test('no picture, junk and URLs behave', () {
      expect(avatarImage('   '), isNull);
      expect(avatarImage('not base64 at all !!!'), isNull);
      expect(avatarImage('https://example.com/a.png'), isNotNull);
    });
  });

  group('a chat with a character', () {
    testWidgets('one avatar stays one image no matter how many turns show it',
        (tester) async {
      final character = _sumire();
      final messages = <ChatMessage>[
        for (var i = 0; i < 12; i++)
          ChatMessage(
            role: i.isEven ? 'user' : 'assistant',
            content: 'turn $i',
          ),
      ];

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            itemCount: messages.length,
            itemBuilder: (context, i) => MessageBubble(
              message: messages[i],
              ui: const ChatInterface(),
              character: character,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(CharacterAvatar), findsWidgets);

      // Scrolling past the picture and back used to add a fresh full-size
      // bitmap to the image cache each time a turn was rebuilt.
      for (var i = 0; i < 6; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -400));
        await tester.pump();
      }
      for (var i = 0; i < 6; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, 400));
        await tester.pump();
      }
      await tester.pumpAndSettle();

      expect(imageCache.liveImageCount, 1);
      expect(imageCache.currentSize, lessThanOrEqualTo(1));
    });
  });

  group('avatarBytes', () {
    test('still decodes for callers that want raw bytes', () {
      final bytes = _sumire().avatarBytes;
      expect(bytes, isNotNull);
      expect(bytes, base64Decode(_png));
    });
  });
}
