import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/services/avatar_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/avatar_image.dart';
import 'package:maichat/widgets/character_avatar.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A real 1x1 PNG.
final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA'
    'DUlEQVR42mP8z8DAwAAABQABg1z0GwAAAABJRU5ErkJggg==');

/// A JPEG, by its magic bytes, to check the extension sniffing.
final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);

void main() {
  late Directory dir;
  late AvatarStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('avatars');
    store = AvatarStore(dir);
    clearAvatarImageCache();
  });
  tearDown(() {
    dir.deleteSync(recursive: true);
    avatarDirectory = null;
  });

  group('references', () {
    test('round-trip a name', () {
      expect(avatarRef('a.png'), 'local:a.png');
      expect(avatarRefName('local:a.png'), 'a.png');
      expect(avatarIsLocal('local:a.png'), isTrue);
      expect(avatarIsLocal('https://x/a.png'), isFalse);
      expect(avatarRefName('https://x/a.png'), isNull);
    });

    test('a reference cannot climb out of the directory', () {
      expect(avatarRefName('local:../../secrets'), isNull);
      expect(avatarRefName('local:a/b.png'), isNull);
      expect(avatarRefName('local:'), isNull);
    });
  });

  group('writing pictures', () {
    test('a picture of any size becomes a file, at full size', () async {
      // Ten megabytes: exactly the case that used to be refused or shrunk.
      final big = Uint8List.fromList([
        ..._png,
        ...List<int>.filled(10 * 1024 * 1024, 7),
      ]);
      final ref = await store.write(big);
      final file = File('${dir.path}/${avatarRefName(ref)}');
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), big.length, reason: 'not resized, not capped');
      expect(ref, endsWith('.png'));
    });

    test('the extension follows the format', () async {
      expect(await store.write(_png), endsWith('.png'));
      expect(await store.write(_jpeg), endsWith('.jpg'));
      expect(await store.write(Uint8List.fromList([1, 2, 3])),
          endsWith('.img'));
    });

    test('adopt moves base64 into a file and leaves other forms alone',
        () async {
      final ref = await store.adopt(base64Encode(_png));
      expect(avatarIsLocal(ref), isTrue);
      expect(File('${dir.path}/${avatarRefName(ref)}').readAsBytesSync(), _png);

      expect(await store.adopt(''), '');
      expect(await store.adopt('https://x/a.png'), 'https://x/a.png');
      expect(await store.adopt(ref), ref, reason: 'already a file');
      expect(await store.adopt('not base64 !!'), 'not base64 !!');
    });

    test('sweep deletes only what nothing refers to', () async {
      final kept = await store.write(_png);
      final orphan = await store.write(_jpeg);
      expect(await store.sweep([kept, 'https://x/a.png']), 1);
      expect(File('${dir.path}/${avatarRefName(kept)}').existsSync(), isTrue);
      expect(File('${dir.path}/${avatarRefName(orphan)}').existsSync(), isFalse);
    });
  });

  group('drawing', () {
    test('a local reference resolves to the file on disk', () async {
      final ref = await store.write(_png);
      final provider = avatarImage(ref, displaySize: 48);
      expect(provider, isNotNull);
      expect(provider.toString(), contains('ResizeImage'));
      // Same picture, same size: still the one shared provider.
      expect(identical(avatarImage(ref, displaySize: 48), provider), isTrue);
    });

    test('a reference whose file is gone falls back to the monogram', () {
      expect(avatarImage('local:missing.png', displaySize: 48), isNull);
    });

    testWidgets('a character whose file vanished shows its initial instead',
        (tester) async {
      final character =
          Character(id: 'c', name: 'Sumire', avatar: 'local:gone.png');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: CharacterAvatar(character: character, radius: 24)),
      ));
      await tester.pump();
      expect(find.text('S'), findsOneWidget);
    });
  });

  group('the store stops holding pictures', () {
    test('a legacy base64 avatar is moved out on the next launch', () async {
      final legacy = base64Encode(_png);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.characters': jsonEncode([
          {'id': 'c1', 'name': 'Sumire', 'avatar': legacy},
        ]),
      });

      final state = AppState(avatars: store);
      await state.init();

      final character = state.characters.single;
      expect(avatarIsLocal(character.avatar), isTrue,
          reason: 'the picture is a file now');
      expect(File('${dir.path}/${avatarRefName(character.avatar)}')
          .readAsBytesSync(), _png);

      // And the preferences store no longer carries the image.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('characters'), isNot(contains(legacy)));
      expect(prefs.getString('characters'), contains('local:'));
    });

    test('saving a character never puts a picture back in the store',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final state = AppState(avatars: store);
      await state.init();

      await state.saveCharacter(
        Character(id: 'c', name: 'Sumire', avatar: base64Encode(_png)),
      );
      expect(avatarIsLocal(state.characters.single.avatar), isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('characters'), isNot(contains(base64Encode(_png))));
    });

    test('deleting a character takes its picture with it', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final state = AppState(avatars: store);
      await state.init();
      await state.saveCharacter(
        Character(id: 'c', name: 'Sumire', avatar: base64Encode(_png)),
      );
      final ref = state.characters.single.avatar;
      expect(File('${dir.path}/${avatarRefName(ref)}').existsSync(), isTrue);

      await state.deleteCharacter('c');
      expect(File('${dir.path}/${avatarRefName(ref)}').existsSync(), isFalse);
    });

    testWidgets('a URL avatar is left as a URL', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final state = AppState(avatars: store);
      await state.init();
      await state.saveCharacter(
        Character(id: 'c', name: 'Sumire', avatar: 'https://x/a.png'),
      );
      expect(state.characters.single.avatar, 'https://x/a.png');
    });
  });
}
