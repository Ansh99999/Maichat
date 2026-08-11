import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/services/character_codec.dart';

/// A CCv3 `card.json`, optionally referencing an embedded main icon.
String _cardJson({bool withIcon = true}) => jsonEncode({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {
        'name': 'Kallen',
        'description': 'A resistance pilot.',
        'first_mes': 'Hello there.',
        'tags': ['mecha', 'rebel'],
        if (withIcon)
          'assets': [
            {
              'type': 'icon',
              'name': 'iconx',
              'uri': 'embeded://assets/icon/image/iconx.png',
              'ext': 'png',
            },
            {
              'type': 'icon',
              'name': 'main',
              'uri': 'embeded://assets/icon/image/main.png',
              'ext': 'png',
            },
          ],
      },
    });

// Stand-in asset bytes — the codec stores them verbatim as the avatar.
final Uint8List _mainIcon = Uint8List.fromList(List.generate(64, (i) => i));
final Uint8List _otherIcon = Uint8List.fromList(List.filled(32, 0xAB));

/// Builds a CharX (.charx) zip: card.json plus, optionally, its icon assets.
Uint8List _charxZip({bool withIcon = true}) {
  final archive = Archive()
    ..add(ArchiveFile.string('card.json', _cardJson(withIcon: withIcon)));
  if (withIcon) {
    archive
      ..add(ArchiveFile.bytes('assets/icon/image/iconx.png', _otherIcon))
      ..add(ArchiveFile.bytes('assets/icon/image/main.png', _mainIcon));
  }
  return ZipEncoder().encodeBytes(archive);
}

/// A minimal JPEG (SOI … EOI) with the CharX zip appended — the shape RisuAI
/// exports as "CharX embedded jpeg".
Uint8List _charxInJpeg({bool withIcon = true}) {
  final jpeg = <int>[0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(200, 0x11), 0xFF, 0xD9];
  return Uint8List.fromList([...jpeg, ..._charxZip(withIcon: withIcon)]);
}

void main() {
  test('reads a standalone .charx zip as a v3 card', () {
    final c = CharacterCodec.parseBytes(_charxZip());
    expect(c.name, 'Kallen');
    expect(c.format, CharacterFormat.tavernV3);
    expect(c.firstMes, 'Hello there.');
    expect(c.tags, ['mecha', 'rebel']);
  });

  test('uses the "main" icon asset as the avatar', () {
    final c = CharacterCodec.parseBytes(_charxZip());
    expect(c.avatarBytes, _mainIcon);
  });

  test('reads a CharX embedded in a JPEG (zip appended after EOI)', () {
    final c = CharacterCodec.parseBytes(_charxInJpeg());
    expect(c.name, 'Kallen');
    expect(c.format, CharacterFormat.tavernV3);
    // The offsets inside the zip are relative to the zip, not the file: the
    // avatar still resolves, proving the archive base was realigned.
    expect(c.avatarBytes, _mainIcon);
  });

  test('parseCards returns the single card from an embedded JPEG', () {
    final cards = CharacterCodec.parseCards(_charxInJpeg());
    expect(cards, hasLength(1));
    expect(cards.first.name, 'Kallen');
  });

  test('a CharX without any icon leaves the avatar empty', () {
    final c = CharacterCodec.parseBytes(_charxInJpeg(withIcon: false));
    expect(c.name, 'Kallen');
    expect(c.hasAvatar, isFalse);
  });

  test('a plain JPEG with no embedded card fails with a clear message', () {
    final plain = Uint8List.fromList(
      [0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(64, 0x00), 0xFF, 0xD9],
    );
    expect(
      () => CharacterCodec.parseBytes(plain),
      throwsA(isA<CharacterParseException>()),
    );
  });
}
