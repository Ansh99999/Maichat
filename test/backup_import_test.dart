import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/services/avatar_store.dart';
import 'package:maichat/services/foreign_backup.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A real 1x1 PNG — small, and a decoder would accept it.
final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA'
    'DUlEQVR42mP8z8DAwAAABQABg1z0GwAAAABJRU5ErkJggg==');

/// A minimal PNG carrying [card] in a `chara` tEXt chunk, the way SillyTavern
/// embeds one. CRCs are left zero — the reader skips them.
Uint8List _cardPng(Map<String, dynamic> card) {
  final out = BytesBuilder();
  out.add(const [137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> data) {
    out.add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List());
    out.add(ascii.encode(type));
    out.add(data);
    out.add(const [0, 0, 0, 0]);
  }

  chunk('tEXt', [
    ...ascii.encode('chara'),
    0,
    ...ascii.encode(base64Encode(utf8.encode(jsonEncode(card)))),
  ]);
  chunk('IEND', const []);
  return out.toBytes();
}

Uint8List _zip(Map<String, Object> entries) {
  final archive = Archive();
  entries.forEach((name, content) {
    archive.add(content is Uint8List
        ? ArchiveFile.bytes(name, content)
        : ArchiveFile.string(name, content as String));
  });
  return ZipEncoder().encodeBytes(archive);
}

/// The Agnai account backup, in the shape its exporter writes.
Map<String, dynamic> _agnaiBackup() => <String, dynamic>{
      'kind': 'agnai-user-backup',
      'formatVersion': 1,
      'createdAt': '2026-08-01T00:00:00.000Z',
      'userId': 'u1',
      'includesKeys': true,
      'characters': [
        {
          '_id': 'ch1',
          'kind': 'character',
          'name': 'Aqua',
          'persona': {
            'kind': 'text',
            'attributes': {'text': ['A useless goddess']},
          },
          'greeting': 'I am Aqua!',
          'scenario': 'Axel town',
          'sampleChat': '',
          'avatar': '/assets/aqua.png',
        },
      ],
      'chats': [
        {
          '_id': 'c1',
          'characterId': 'ch1',
          'name': 'The quest',
          'greeting': 'I am Aqua!',
          'scenario': 'Axel town',
        },
      ],
      'messages': {
        'c1': [
          {'_id': 'm1', 'chatId': 'c1', 'userId': 'u1', 'msg': 'hello there'},
          {'_id': 'm2', 'chatId': 'c1', 'characterId': 'ch1', 'msg': 'hi!'},
        ],
      },
      'books': [
        {
          '_id': 'b1',
          'kind': 'memory',
          'name': 'Axel lore',
          'entries': [
            {
              'name': 'guild',
              'keywords': ['guild'],
              'entry': 'Where quests are taken',
              'priority': 100,
              'weight': 10,
              'enabled': true,
            },
          ],
        },
      ],
      'scenarios': [
        {
          '_id': 's1',
          'kind': 'scenario',
          'name': 'Opening',
          'text': 'You arrive in Axel',
          'overwriteCharacterScenario': true,
        },
      ],
      'presets': [
        {'_id': 'p1', 'name': 'Balanced', 'temp': 0.8, 'maxContextLength': 8192},
      ],
      'gallery': [
        {
          '_id': 'g1',
          'characterId': 'ch1',
          'image': '/assets/gallery-1.png',
          'title': 'Beach',
        },
      ],
      'user': {
        'providers': [
          {
            '_id': 'pr1',
            'name': 'My proxy',
            'url': 'https://proxy.tld/v1',
            'format': {'type': 'format', 'value': 'openai-chatv2'},
            'key': 'sk-a',
            'keys': ['sk-a', 'sk-b'],
          },
        ],
      },
    };
void main() {
  group('an Agnai backup', () {
    test('reads every drawer out of the JSON export', () async {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(_agnaiBackup())));

      final backup =
          await readForeignBackupBytes(bytes, fileName: 'agnai-backup.json');

      expect(backup.source, ForeignSource.agnai);
      expect(backup.characters.single.name, 'Aqua');
      expect(backup.characters.single.description, contains('useless goddess'));
      expect(backup.characters.single.firstMes, 'I am Aqua!');
      expect(backup.lorebooks.single.name, 'Axel lore');
      expect(backup.lorebooks.single.entries.single.content,
          'Where quests are taken');
      expect(backup.scenarios.single.text, 'You arrive in Axel');
      expect(backup.presets.single.name, 'Balanced');
      // Three turns, not two: an Agnai chat opens with the character's
      // greeting, which lives on the chat rather than in its message list.
      expect(backup.messages, 3);
      // No archive, so the asset reference has nothing behind it and is dropped
      // rather than kept as a path into somebody else's server.
      expect(backup.characters.single.avatar, isEmpty);
      expect(backup.pictures, isEmpty);
    });

    test('binds each chat to its character by name', () async {
      final backup = await readForeignBackupBytes(
        Uint8List.fromList(utf8.encode(jsonEncode(_agnaiBackup()))),
      );

      final chat = backup.chats.single;
      expect(chat.characterName, 'Aqua');
      expect(chat.chat.conversation.title, 'The quest');
      expect(chat.chat.conversation.messages.first.content, 'I am Aqua!');
      expect(chat.chat.conversation.messages[1].content, 'hello there');
      expect(chat.chat.conversation.messages[1].role, 'user');
      expect(chat.chat.conversation.messages.last.role, 'assistant');
    });

    test('brings the provider and its whole key pool', () async {
      final backup = await readForeignBackupBytes(
        Uint8List.fromList(utf8.encode(jsonEncode(_agnaiBackup()))),
      );

      final provider = backup.providers.single;
      expect(provider.name, 'My proxy');
      expect(provider.baseUrl, 'https://proxy.tld/v1');
      // Each key once: Agnai lists the first key in both `key` and `keys`.
      expect(provider.apiKeys, ['sk-a', 'sk-b']);
    });

    test('takes the pictures out of the .zip and files them by character',
        () async {
      final pictures = Directory.systemTemp.createTempSync('agnai-pics');
      addTearDown(() {
        pictures.deleteSync(recursive: true);
        avatarDirectory = null;
      });
      final store = AvatarStore(pictures);
      final bytes = _zip(<String, Object>{
        'backup.json': jsonEncode(_agnaiBackup()),
        'assets/aqua.png': _png,
        'assets/gallery-1.png': _png,
      });

      final backup = await readForeignBackupBytes(
        bytes,
        fileName: 'agnai.zip',
        storePicture: store.write,
      );

      expect(backup.source, ForeignSource.agnai);
      // The picture is a file already — base64 never reaches the store.
      expect(avatarIsLocal(backup.characters.single.avatar), isTrue);
      expect(
        avatarRefFile(backup.characters.single.avatar)!.readAsBytesSync(),
        _png,
      );
      expect(backup.pictures.single.characterName, 'Aqua');
      expect(backup.pictures.single.title, 'Beach');
      expect(avatarRefFile(backup.pictures.single.ref)!.existsSync(), isTrue);
    });
  });
  // A SillyTavern data folder has a test file of its own — see
  // backup_sillytavern_test.dart, which builds the real layout.

  group('a bag of files, which is what a Chub export is', () {
    test('reads the cards and the lorebooks in it', () async {
      final bytes = _zip(<String, Object>{
        'Aqua.json': jsonEncode({
          'name': 'Aqua',
          'description': 'A goddess',
          'first_mes': 'I am Aqua!',
          'extensions': {'chub': {'full_path': 'someone/aqua'}},
        }),
        'Megumin.png': _cardPng(<String, dynamic>{
          'name': 'Megumin',
          'description': 'An archwizard',
          'first_mes': 'Explosion!',
        }),
        'axel-lorebook.json': jsonEncode({
          'name': 'Axel',
          'entries': [
            {
              'keys': ['guild'],
              'content': 'Where quests are taken',
              'enabled': true,
            },
          ],
        }),
      });

      final backup = await readForeignBackupBytes(bytes, fileName: 'chub.zip');

      expect(backup.characters.map((c) => c.name), containsAll(['Aqua', 'Megumin']));
      expect(backup.lorebooks.single.name, 'Axel');
      expect(backup.chats, isEmpty);
    });

    test('a single card on its own, whatever it is called', () async {
      final png = _cardPng(<String, dynamic>{
        'name': 'Aqua',
        'description': 'A goddess',
        'first_mes': 'I am Aqua!',
      });

      // No extension at all: the bytes are sniffed, not the name.
      final backup = await readForeignBackupBytes(png, fileName: 'download');

      expect(backup.source, ForeignSource.file);
      expect(backup.characters.single.name, 'Aqua');
    });

    test('and a file with nothing in it complains', () async {
      await expectLater(
        readForeignBackupBytes(
          Uint8List.fromList(utf8.encode('{"unrelated":true}')),
          fileName: 'thing.json',
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
  group('applying one', () {
    late Directory pictures;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      pictures = Directory.systemTemp.createTempSync('import-pics');
    });

    tearDown(() {
      pictures.deleteSync(recursive: true);
      avatarDirectory = null;
    });

    test('puts everything in place, chats attached to their character',
        () async {
      final state = AppState(avatars: AvatarStore(pictures));
      await state.init();
      final backup = await state.readForeignBytes(_zip(<String, Object>{
        'backup.json': jsonEncode(_agnaiBackup()),
        'assets/aqua.png': _png,
        'assets/gallery-1.png': _png,
      }));

      await state.applyForeignBackup(backup);

      final character = state.characters.single;
      expect(character.name, 'Aqua');
      // The card's picture became a file, as every picture in this app does.
      expect(avatarIsLocal(character.avatar), isTrue);
      expect(avatarRefFile(character.avatar)!.readAsBytesSync(), _png);
      // The chat arrived bound to it, persona and all.
      final chat = state.conversations.single;
      expect(chat.characterId, character.id);
      expect(chat.characterName, 'Aqua');
      expect(chat.systemPrompt, contains('Aqua'));
      expect(chat.messages.length, 3);
      // And the library.
      expect(state.lorebooks.single.name, 'Axel lore');
      expect(state.scenarios.single.name, 'Opening');
      expect(state.presets.map((p) => p.name), contains('Balanced'));
      expect(state.providers.single.apiKeys, ['sk-a', 'sk-b']);
      // The gallery picture is filed under the character it belongs to.
      expect(state.gallery.single.characterId, character.id);
      expect(state.gallery.single.title, 'Beach');
    });

    test('two files at once are applied together', () async {
      final state = AppState(avatars: AvatarStore(pictures));
      await state.init();
      final cards = await state.readForeignBytes(
        _cardPng(<String, dynamic>{
          'name': 'Megumin',
          'description': 'An archwizard',
          'first_mes': 'Explosion!',
        }),
        fileName: 'Megumin.png',
      );
      final chat = await state.readForeignBytes(
        Uint8List.fromList(utf8.encode(
          '${jsonEncode({'user_name': 'You', 'character_name': 'Megumin'})}\n'
          '${jsonEncode({'name': 'You', 'is_user': true, 'mes': 'again?'})}',
        )),
        fileName: 'Megumin - 2026.jsonl',
      );
      cards.absorb(chat);

      await state.applyForeignBackup(cards);

      expect(state.characters.single.name, 'Megumin');
      expect(
        state.conversations.single.characterId,
        state.characters.single.id,
      );
    });
  });
}
