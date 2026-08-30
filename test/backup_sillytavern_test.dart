import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/services/avatar_store.dart';
import 'package:maichat/services/foreign_backup.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Imports a SillyTavern backup — the real thing: the zip its own
/// `createBackupArchive` writes, whose entries are the user's data directory
/// exactly as `USER_DIRECTORY_TEMPLATE` lays it out.
///
/// The fixture below is built from that layout file by file, with the shapes
/// SillyTavern's own endpoints write: a card PNG under `characters/`, a chat
/// under `chats/<card file>/` (the folder is the only record of whose chat it
/// is), a group in two halves, `worlds/` and `OpenAI Settings/` taken verbatim
/// from SillyTavern's own default content, and `settings.json` carrying the
/// personas and the tag map.
void main() {
  late Directory root;
  late Directory pictures;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    root = Directory.systemTemp.createTempSync('st-import');
    pictures = Directory('${root.path}/pictures')..createSync();
  });

  tearDown(() {
    root.deleteSync(recursive: true);
    avatarDirectory = null;
  });
  /// A real 1x1 PNG, so every picture in the fixture is one a decoder accepts.
  final png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA'
      'DUlEQVR42mP8z8DAwAAABQABg1z0GwAAAABJRU5ErkJggg==');

  /// A distinguishable picture, so "which file ended up where" is answerable.
  Uint8List picture(int seed) =>
      Uint8List.fromList(<int>[...png, ...List<int>.filled(4, seed)]);

  /// A character card in a PNG's `chara` tEXt chunk — how SillyTavern stores
  /// every card in `characters/`.
  Uint8List card(Map<String, dynamic> data, {int seed = 0}) {
    final out = BytesBuilder();
    out.add(const [137, 80, 78, 71, 13, 10, 26, 10]);
    void chunk(String type, List<int> bytes) {
      out.add((ByteData(4)..setUint32(0, bytes.length)).buffer.asUint8List());
      out.add(ascii.encode(type));
      out.add(bytes);
      out.add(const [0, 0, 0, 0]); // the reader skips CRCs
    }

    chunk('tEXt', [
      ...ascii.encode('chara'),
      0,
      ...ascii.encode(base64Encode(utf8.encode(jsonEncode(data)))),
    ]);
    chunk('IEND', <int>[seed]);
    return out.toBytes();
  }

  String jsonl(List<Map<String, dynamic>> lines) =>
      lines.map(jsonEncode).join('\n');

  /// SillyTavern's own header line, then its turns. `user_name` and
  /// `character_name` have read "unused" since names moved onto every turn.
  List<Map<String, dynamic>> transcript({
    required String character,
    String? mediaUrl,
  }) =>
      <Map<String, dynamic>>[
        {
          'user_name': 'unused',
          'character_name': 'unused',
          'create_date': '2026-1-1 @12h 00m 00s 000ms',
          'chat_metadata': {'integrity': 'abc', 'tainted': false},
        },
        {
          'name': 'User',
          'is_user': true,
          'is_system': false,
          'send_date': 'January 1, 2026 12:00pm',
          'mes': 'Hello there.',
        },
        {
          'name': character,
          'is_user': false,
          'is_system': false,
          'send_date': 'January 1, 2026 12:01pm',
          'mes': '*She smiles.* Second try.',
          'swipe_id': 1,
          'swipes': ['*She smiles.* First try.', '*She smiles.* Second try.'],
          'swipe_info': <dynamic>[<String, dynamic>{}, <String, dynamic>{}],
          if (mediaUrl != null)
            'extra': {
              'media': [
                {'url': mediaUrl, 'type': 'image', 'title': 'a portrait'},
              ],
              'inline_image': false,
            },
        },
        {
          // SillyTavern's own interface notices are not transcript.
          'name': 'System',
          'is_user': false,
          'is_system': true,
          'mes': 'Group generation has started.',
        },
      ];
  /// `settings.json`, with the parts an import can use: the personas (a map of
  /// avatar file to name, with the descriptions keyed the same way), which one is
  /// default, and the tags the user pinned onto their cards.
  Map<String, dynamic> settings() => <String, dynamic>{
        'username': 'User',
        'user_avatar': 'user-default.png',
        'power_user': {
          'personas': {
            'user-default.png': 'Ubuntu',
            'other.png': 'Second self',
          },
          'default_persona': 'user-default.png',
          'persona_descriptions': {
            'user-default.png': {
              'description': 'A tired developer.',
              'title': 'The usual',
              'position': 0,
              'depth': 2,
            },
          },
          'persona_description': 'A tired developer.',
        },
        'tags': [
          {'id': '1', 'name': 'Fantasy', 'color': 'rgba(1,1,1,1)'},
          {'id': '2', 'name': 'Guardian'},
        ],
        'tag_map': {
          'Seraphina.png': ['1', '2'],
          'Aqua.png': ['1'],
        },
        'oai_settings': {'preset_settings_openai': 'Default'},
      };

  /// The whole backup, written to a real zip on disk — the only shape the
  /// importer accepts for a large archive, and the shape the app actually gets.
  Future<File> backupZip({bool withPictures = true}) async {
    final file = File('${root.path}/default-user-2026-08-30.zip');
    final encoder = ZipFileEncoder()..create(file.path);
    void add(String name, List<int> bytes) =>
        encoder.addArchiveFile(ArchiveFile.bytes(name, bytes));
    void addText(String name, String text) =>
        encoder.addArchiveFile(ArchiveFile.string(name, text));

    add(
      'characters/Seraphina.png',
      card(<String, dynamic>{
        'spec': 'chara_card_v2',
        'spec_version': '2.0',
        'data': {
          'name': 'Seraphina',
          'description': 'Guardian of Eldoria.',
          'personality': 'Kind',
          'scenario': 'A forest glade',
          'first_mes': '*She turns.* Welcome.',
          'mes_example': '',
          'tags': ['guardian'],
          'creator': 'SillyTavern',
          'character_book': {
            'name': "Seraphina's lore",
            'entries': [
              {
                'keys': ['glade'],
                'content': 'The glade is a sanctuary.',
                'enabled': true,
                'insertion_order': 100,
              },
            ],
          },
        },
      }, seed: 1),
    );
    add(
      'characters/Aqua.png',
      card(<String, dynamic>{
        'name': 'Aqua',
        'description': 'A useless goddess.',
        'first_mes': 'I am Aqua!',
      }, seed: 2),
    );
    addText(
      'chats/Seraphina/2026-01-01 @12h 00m 00s 000ms.jsonl',
      jsonl(transcript(
        character: 'Seraphina',
        mediaUrl: withPictures ? 'user/images/Seraphina/00042.png' : null,
      )),
    );
    addText(
      'chats/Aqua/2026-02-02 @09h 30m 00s 000ms.jsonl',
      jsonl(transcript(character: 'Aqua')),
    );
    addText(
      'groups/1700000000000.json',
      jsonEncode({
        'id': '1700000000000',
        'name': 'The party',
        'members': ['Seraphina.png', 'Aqua.png'],
        'avatar_url': '',
        'chat_id': '1700000000000',
        'chats': ['1700000000000'],
        'disabled_members': <String>[],
        'activation_strategy': 0,
        'generation_mode': 0,
      }),
    );
    addText(
      'group chats/1700000000000.jsonl',
      jsonl(transcript(character: 'Seraphina')),
    );
    addText(
      'worlds/Eldoria.json',
      File('test/fixtures/st_eldoria_world.json').readAsStringSync(),
    );
    addText(
      'OpenAI Settings/Default.json',
      File('test/fixtures/st_openai_default.json').readAsStringSync(),
    );
    addText('settings.json', jsonEncode(settings()));
    addText('secrets.json', jsonEncode({'api_key_openai': 'sk-nope'}));
    if (withPictures) {
      add('User Avatars/user-default.png', picture(3));
      add('user/images/Seraphina/00042.png', picture(4));
      add('backgrounds/bedroom.jpg', picture(5));
      add('thumbnails/bg/bedroom.jpg', picture(6));
    }
    addText('themes/Dark.json', jsonEncode({'name': 'Dark'}));
    addText('QuickReplies/Default.json', jsonEncode({'name': 'qr'}));
    await encoder.close();
    return file;
  }
  /// A running app whose pictures directory is the temporary one, so the
  /// importer's writes can be checked on disk.
  Future<AppState> boot() async {
    final state = AppState(avatars: AvatarStore(pictures));
    await state.init();
    return state;
  }

  group('reading the archive', () {
    test('recognises it and reads every drawer', () async {
      final state = await boot();
      final file = await backupZip();

      final backup = await state.readForeignFile(file.path);

      expect(backup.source, ForeignSource.sillyTavern);
      // Two cards plus the two personas out of settings.json.
      expect(
        backup.characters.map((c) => c.displayName),
        containsAll(<String>['Seraphina', 'Aqua', 'Ubuntu', 'Second self']),
      );
      expect(backup.personaNames, containsAll(<String>['Ubuntu', 'Second self']));
      expect(backup.defaultPersonaName, 'Ubuntu');
      // Two one-to-one chats and the group's.
      expect(backup.chats.length, 3);
      // Eldoria plus the lorebook riding inside Seraphina's card.
      expect(
        backup.lorebooks.map((b) => b.name),
        containsAll(<String>['Eldoria', "Seraphina's lore"]),
      );
      expect(backup.presets.single.name, 'Default');
      expect(backup.presets.single.prompts, isNotEmpty);
    });

    test('binds each chat to the character whose folder it is in', () async {
      final state = await boot();

      final backup = await state.readForeignFile((await backupZip()).path);

      final byOwner = <String, ForeignChat>{
        for (final chat in backup.chats) chat.characterName: chat,
      };
      expect(byOwner.keys, containsAll(<String>['Seraphina', 'Aqua']));
      final chat = byOwner['Aqua']!.chat.conversation;
      // The header's names read "unused"; the folder is the real binding.
      expect(chat.title, contains('2026-02-02'));
      // Two turns, not three: the system notice is interface, not transcript.
      expect(chat.messages.length, 2);
      expect(chat.messages.first.content, 'Hello there.');
      // Swipes survive, and the one that was showing is the one selected.
      final reply = chat.messages.last;
      expect(reply.swipeCount, 2);
      expect(reply.content, '*She smiles.* Second try.');
    });

    test('brings the group and everyone who was in it', () async {
      final state = await boot();

      final backup = await state.readForeignFile((await backupZip()).path);

      final group = backup.chats.firstWhere(
        (chat) => chat.participantNames.isNotEmpty,
      );
      expect(group.chat.conversation.title, 'The party');
      expect(group.participantNames, ['Seraphina', 'Aqua']);
    });

    test('puts the pictures back where they belong, once each', () async {
      final state = await boot();

      final backup = await state.readForeignFile((await backupZip()).path);

      // The card's own portrait became a file.
      final seraphina =
          backup.characters.firstWhere((c) => c.displayName == 'Seraphina');
      expect(avatarIsLocal(seraphina.avatar), isTrue);
      expect(avatarRefFile(seraphina.avatar)!.existsSync(), isTrue);
      // So did the persona's.
      final persona =
          backup.characters.firstWhere((c) => c.displayName == 'Ubuntu');
      expect(avatarIsLocal(persona.avatar), isTrue);
      // The picture in the transcript is an attachment on the turn that had it.
      final chat = backup.chats
          .firstWhere((c) => c.characterName == 'Seraphina' &&
              c.participantNames.isEmpty)
          .chat
          .conversation;
      final attachment = chat.messages.last.images.single;
      expect(avatarIsLocal(attachment.ref), isTrue);
      expect(avatarRefFile(attachment.ref)!.readAsBytesSync(), picture(4));
      // …and the same file is the gallery record, not a second copy of it.
      expect(backup.pictures.single.ref, attachment.ref);
      expect(backup.pictures.single.characterName, 'Seraphina');
      // Four files, and no more: the two card portraits, the persona's picture
      // and the generated one. The wallpaper and its thumbnail are not pictures
      // this app has anywhere to put, and the generated one is not stored twice.
      expect(pictures.listSync().whereType<File>().length, 4);
    });

    test('says what it left behind instead of pretending it took it', () async {
      final state = await boot();

      final backup = await state.readForeignFile((await backupZip()).path);

      expect(backup.skipped['interface themes'], 1);
      expect(backup.skipped['quick replies'], 1);
      expect(backup.skipped['background pictures'], 1);
      expect(backup.skipped['thumbnails'], 1);
      expect(backup.skipped['API keys (not read)'], 1);
      expect(backup.leftOut(), contains('interface themes'));
    });
  });
  group('applying it', () {
    test('everything lands, attached to what it belongs to', () async {
      final state = await boot();
      final backup = await state.readForeignFile((await backupZip()).path);

      await state.applyForeignBackup(backup);

      expect(state.characters.length, 4);
      final seraphina = state.characters
          .firstWhere((c) => c.displayName == 'Seraphina');
      // The tags from the tag map are on the card, beside its own.
      expect(seraphina.tags, containsAll(<String>['Fantasy', 'Guardian']));
      expect(state.lorebooks.length, 2);
      expect(state.presets.map((p) => p.name), contains('Default'));
      // The persona SillyTavern was speaking as is the one new chats use.
      expect(state.defaultPersona?.displayName, 'Ubuntu');

      // Three chats, each bound to its character.
      expect(state.conversations.length, 3);
      final aqua = state.characters.firstWhere((c) => c.displayName == 'Aqua');
      final aquaChat = state.conversations
          .firstWhere((c) => c.characterId == aqua.id);
      expect(aquaChat.messages.length, 2);
      expect(aquaChat.systemPrompt, contains('useless goddess'));
      // The group chat knows who was in the room — and group chats are switched
      // on, because a group chat whose members cannot speak is not what was
      // imported.
      final group = state.conversations
          .firstWhere((c) => c.participantIds.isNotEmpty);
      expect(group.participantIds, containsAll(<String>[seraphina.id, aqua.id]));
      expect(state.chatInterface.groupChatsEnabled, isTrue);
      // The generated picture is in the gallery under its character, and is the
      // same file the message points at.
      final picture = state.gallery.single;
      expect(picture.characterId, seraphina.id);
      final chat = state.conversations
          .firstWhere((c) => c.characterId == seraphina.id &&
              c.participantIds.isEmpty);
      expect(chat.messages.last.images.single.ref, picture.image);
    });

    test('a second import does not lose the first', () async {
      final state = await boot();
      await state.applyForeignBackup(
        await state.readForeignFile((await backupZip()).path),
      );
      await state.applyForeignBackup(
        await state.readForeignFile((await backupZip()).path),
      );

      // Nothing is de-duplicated — a second import is a second copy, which is
      // what "add to what is here" means — but nothing is lost either.
      expect(state.conversations.length, 6);
      expect(state.characters.length, 8);
    });

    test('a data folder with no pictures still imports its text', () async {
      final state = await boot();

      final backup = await state.readForeignFile(
        (await backupZip(withPictures: false)).path,
      );
      await state.applyForeignBackup(backup);

      expect(state.characters.length, 4);
      expect(state.conversations.length, 3);
      expect(state.gallery, isEmpty);
      expect(state.conversations.every((c) =>
          c.messages.every((m) => m.images.isEmpty)), isTrue);
    });
  });
}
