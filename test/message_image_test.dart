import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/message_image.dart';

/// The attachment model, and the two places a picture could silently be dropped
/// on its way to a request: a same-role merge, and a swipe.
void main() {
  const picture = MessageImage(ref: 'local:a.png', mime: 'image/png');

  group('MessageImage', () {
    test('round-trips, and never carries its bytes into storage', () {
      final json = picture.withData('AAAA').toJson();
      expect(json, {'ref': 'local:a.png', 'mime': 'image/png'});
      expect(MessageImage.fromJson(json), picture);
      expect(MessageImage.fromJson(json).hasData, isFalse);
    });

    test('a missing mime is derived from the reference', () {
      expect(MessageImage.fromJson({'ref': 'local:a.jpg'}).mime, 'image/jpeg');
      expect(MessageImage.fromJson({'ref': 'local:a.webp'}).mime, 'image/webp');
      expect(MessageImage.fromJson({'ref': 'local:a.gif'}).mime, 'image/gif');
      expect(MessageImage.fromJson({'ref': 'local:a.bin'}).mime, 'image/png');
    });

    test('a url is told apart from a file', () {
      expect(picture.isUrl, isFalse);
      expect(const MessageImage(ref: 'https://host.tld/a.png').isUrl, isTrue);
    });

    test('mime is sniffed from the bytes, like the file extension is', () {
      expect(mimeForBytes(const [0xFF, 0xD8, 0xFF, 0x00]), 'image/jpeg');
      expect(mimeForBytes(const [0x47, 0x49, 0x46, 0x38]), 'image/gif');
      expect(mimeForBytes(const [0x89, 0x50, 0x4E, 0x47]), 'image/png');
      expect(
        mimeForBytes(const [
          0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50,
        ]),
        'image/webp',
      );
    });

    test('elided keeps the shape and drops the payload', () {
      final elided = picture.withData('AAAABBBB').elided();
      expect(elided.hasData, isTrue);
      expect(elided.data, contains('elided'));
      expect(elided.data, isNot(contains('AAAA')));
    });
  });

  group('a turn carrying pictures', () {
    test('round-trips through JSON', () {
      final m = ChatMessage(
        role: 'user',
        content: 'look',
        images: const [picture, MessageImage(ref: 'local:b.jpg', mime: 'image/jpeg')],
      );
      final back = ChatMessage.fromJson(m.toJson());
      expect(back.images.length, 2);
      expect(back.images.first, picture);
      expect(back.hasImages, isTrue);
    });

    test('a turn with nothing attached writes no images key', () {
      expect(
        ChatMessage(role: 'user', content: 'hi').toJson().containsKey('images'),
        isFalse,
      );
    });

    test('an empty or malformed entry is dropped rather than kept as a blank',
        () {
      final back = ChatMessage.fromJson({
        'role': 'user',
        'content': 'x',
        'images': [
          {'ref': ''},
          'nonsense',
          {'ref': 'local:c.png'},
        ],
      });
      expect(back.images.single.ref, 'local:c.png');
    });

    test('swipes carry the pictures with them', () {
      final m = ChatMessage(
        role: 'assistant',
        content: 'first',
        images: const [picture],
      );
      final two = m.addSwipe(const MessageVariant(content: 'second'));
      expect(two.images, [picture]);
      expect(two.withSwipe(0).images, [picture]);
      expect(two.removeSwipe(1).images, [picture]);
      expect(m.copyWith(content: 'edited').images, [picture]);
    });

    test('copyWith can clear the pictures, which a null default could not', () {
      final m = ChatMessage(role: 'user', content: 'x', images: const [picture]);
      expect(m.copyWith(images: const <MessageImage>[]).hasImages, isFalse);
    });

    test('a same-role merge keeps every picture', () {
      // A preset that frames the conversation can merge a `user` framing block
      // into the very turn a picture was attached to; losing it there would make
      // attachments work under one preset and vanish under another.
      final merged = mergeSameRole([
        ChatMessage(role: 'user', content: 'look', images: const [picture]),
        ChatMessage(
          role: 'user',
          content: '</chat>',
          images: const [MessageImage(ref: 'local:b.png')],
        ),
      ]);
      expect(merged.length, 1);
      expect(merged.single.images.map((i) => i.ref),
          ['local:a.png', 'local:b.png']);
      expect(merged.single.content, 'look\n\n</chat>');
    });
  });

  group('the OpenAI chat shape', () {
    test('a text-only turn keeps the exact shape it always had', () {
      final m = ChatMessage(role: 'user', content: 'hello');
      expect(m.toApi(), {'role': 'user', 'content': 'hello'});
    });

    test('a picture with no bytes to send is left out entirely', () {
      // The file was swept or never written: send the words rather than an
      // attachment the host will reject.
      final m = ChatMessage(role: 'user', content: 'hello', images: const [picture]);
      expect(m.toApi(), {'role': 'user', 'content': 'hello'});
    });

    test('a picture becomes a data URL beside the text', () {
      final m = ChatMessage(
        role: 'user',
        content: 'what is this',
        images: [picture.withData('QUJD')],
      );
      final content = m.toApi()['content'] as List;
      expect(content.first, {'type': 'text', 'text': 'what is this'});
      expect((content.last as Map)['type'], 'image_url');
      expect(
        ((content.last as Map)['image_url'] as Map)['url'],
        'data:image/png;base64,QUJD',
      );
    });

    test('a picture that lives online is sent as its own address', () {
      final m = ChatMessage(
        role: 'user',
        content: '',
        images: const [MessageImage(ref: 'https://host.tld/a.png')],
      );
      final content = m.toApi()['content'] as List;
      // No text part at all when nothing was typed — a picture on its own.
      expect(content.length, 1);
      expect(
        ((content.single as Map)['image_url'] as Map)['url'],
        'https://host.tld/a.png',
      );
    });
  });
}
