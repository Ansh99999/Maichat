import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/services/image_tools.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A real PNG, [side]x[side], of noisy pixels so it does not compress away —
/// a stand-in for a picture straight off the camera roll. Written by hand
/// because `dart:ui` cannot rasterize in a headless test.
Uint8List noisyPng(int side) {
  final raw = BytesBuilder();
  var seed = 1;
  for (var y = 0; y < side; y++) {
    raw.addByte(0); // filter: none
    for (var x = 0; x < side; x++) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      raw.add([(seed >> 16) & 0xff, (seed >> 8) & 0xff, seed & 0xff]);
    }
  }
  final idat = ZLibCodec(level: 6).encode(raw.takeBytes());

  final ihdr = BytesBuilder()
    ..add(_be32(side))
    ..add(_be32(side))
    ..add([8, 2, 0, 0, 0]); // 8-bit, truecolour

  return Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    ..._chunk('IHDR', ihdr.takeBytes()),
    ..._chunk('IDAT', idat),
    ..._chunk('IEND', const []),
  ]);
}

List<int> _be32(int v) => [
      (v >> 24) & 0xff,
      (v >> 16) & 0xff,
      (v >> 8) & 0xff,
      v & 0xff,
    ];

List<int> _chunk(String type, List<int> data) {
  final body = <int>[...ascii.encode(type), ...data];
  return [..._be32(data.length), ...body, ..._be32(_crc32(body))];
}

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return crc ^ 0xffffffff;
}

void main() {
  late Uint8List big;

  setUpAll(() {
    big = noisyPng(1200);
  });

  testWidgets('an oversized picture is shrunk on its way into storage',
      (tester) async {
    expect(big.length, greaterThan(kAvatarShrinkAboveBytes),
        reason: 'the fixture has to be big enough to trigger the shrink');

    // Image work needs real async: the fake clock a widget test runs under
    // never lets the codec finish.
    await tester.runAsync(() async {
      final small = await shrinkAvatarBytes(big);
      expect(small.length, lessThan(big.length));

      final codec = await ui.instantiateImageCodec(small);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, kMaxAvatarSide);
      expect(frame.image.height, kMaxAvatarSide);
    });
  });

  testWidgets('ordinary card art is left byte-for-byte alone', (tester) async {
    await tester.runAsync(() async {
      final modest = noisyPng(64);
      expect(modest.length, lessThan(kAvatarShrinkAboveBytes));
      expect(identical(await shrinkAvatarBytes(modest), modest), isTrue);
    });
  });

  testWidgets('URLs, junk and empties pass straight through', (tester) async {
    await tester.runAsync(() async {
      expect(await shrinkAvatarBase64('https://example.com/a.png'),
          'https://example.com/a.png');
      expect(await shrinkAvatarBase64(''), '');
      final junk = 'x' * (kAvatarShrinkAboveBytes + 10);
      expect(await shrinkAvatarBase64(junk), junk);
    });
  });

  testWidgets('saving a character caps the avatar it carries', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.runAsync(() async {
      final state = AppState();
      await state.init();

      final encoded = base64Encode(big);
      await state.saveCharacter(
          Character(id: 'c', name: 'Sumire', avatar: encoded));

      final stored = state.characters.single.avatar;
      expect(stored.length, lessThan(encoded.length));
      // Still a usable picture, just a sane one.
      expect(() => base64Decode(stored), returnsNormally);
      debugPrint('avatar: ${encoded.length} -> ${stored.length} base64 chars');
    });
  });
}
