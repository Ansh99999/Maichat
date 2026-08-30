import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/backup.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/conversation.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/models/scenario.dart';
import 'package:maichat/services/avatar_store.dart';
import 'package:maichat/services/backup_codec.dart';
import 'package:maichat/services/backup_store.dart';
import 'package:maichat/services/embedding_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A real 1x1 PNG, so what is written is a picture a decoder would accept.
final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA'
    'DUlEQVR42mP8z8DAwAAABQABg1z0GwAAAABJRU5ErkJggg==');

void main() {
  late Directory root;
  late Directory pictures;
  late Directory vectors;
  late Directory folder;

  setUp(() {
    root = Directory.systemTemp.createTempSync('backups');
    pictures = Directory('${root.path}/pictures')..createSync();
    vectors = Directory('${root.path}/vectors')..createSync();
    folder = Directory('${root.path}/kept')..createSync();
  });

  tearDown(() {
    root.deleteSync(recursive: true);
    avatarDirectory = null;
  });

  /// A running app on this device's directories. [fresh] wipes the store first,
  /// which is what "a new install" means here.
  Future<AppState> boot({bool fresh = false}) async {
    if (fresh) SharedPreferences.setMockInitialValues(<String, Object>{});
    final state = AppState(
      avatars: AvatarStore(pictures),
      embeddings: EmbeddingStore(vectors),
      backups: BackupStore(folder),
    );
    await state.init();
    return state;
  }

  /// An app with something in every drawer: a provider with a key, a character
  /// with a picture, a chat with two turns, a lorebook, a scenario, a gallery
  /// picture and a vector file.
  Future<AppState> seeded() async {
    final state = await boot(fresh: true);
    await state.addProvider(Provider(
      id: 'p1',
      name: 'Test',
      kind: ProviderKind.openai,
      baseUrl: 'https://host.tld/v1',
      apiKey: 'sk-live',
      model: 'gpt-test',
    ));
    final character = Character(id: 'c1', name: 'Aqua', description: 'A goddess')
      ..avatar = base64Encode(_png);
    await state.addCharacter(character);
    await state.addLorebook(Lorebook(id: 'b1', name: 'Axel'));
    await state.addScenario(Scenario(id: 's1', name: 'The guild', text: 'Hello'));
    await state.importConversations([
      Conversation(
        id: 'k1',
        title: 'Adventures',
        updatedAt: DateTime.utc(2026, 8, 1),
        characterId: 'c1',
        characterName: 'Aqua',
        messages: [
          ChatMessage(role: 'user', content: 'hi'),
          ChatMessage(role: 'assistant', content: 'hello there'),
        ],
      ),
    ]);
    await state.addGalleryImages([_png], characterId: 'c1', title: 'Beach');
    // A vector collection for the chat above — one an orphan sweep keeps,
    // since the conversation it belongs to exists.
    File('${vectors.path}/chat-k1.json')
        .writeAsStringSync('{"model":"m","records":[]}');
    return state;
  }
  group('a backup of everything', () {
    test('holds every drawer and says what is in it', () async {
      final state = await seeded();

      final record = await state.exportBackup(
        destination: BackupDestination.device,
      );

      expect(record, isNotNull);
      expect(record!.counts.characters, 1);
      expect(record.counts.chats, 1);
      expect(record.counts.messages, 2);
      expect(record.counts.lorebooks, 1);
      expect(record.counts.scenarios, 1);
      expect(record.counts.gallery, 1);
      expect(record.counts.providers, 1);
      // Two pictures on disk: the avatar and the gallery shot.
      expect(record.counts.pictures, 2);
      expect(record.counts.vectors, 1);
      expect(record.bytes, greaterThan(0));
      expect(File(record.path).existsSync(), isTrue);
      expect(state.backups.single.id, record.id);
    });

    test('restores onto an empty install exactly where things were', () async {
      final source = await seeded();
      final record = await source.exportBackup(
        destination: BackupDestination.device,
      );
      final bytes = (await source.readBackup(record!))!;
      final avatarRef = source.characters.single.avatar;
      final galleryRef = source.gallery.single.image;

      // A new device: nothing in the store, no pictures on disk.
      for (final file in pictures.listSync()) {
        file.deleteSync();
      }
      File('${vectors.path}/chat-k1.json').deleteSync();
      final fresh = await boot(fresh: true);
      expect(fresh.characters, isEmpty);
      expect(fresh.conversations, isEmpty);

      final counts = await fresh.restoreBackup(bytes);

      expect(counts.messages, 2);
      // The chat, its turns and its binding to the character.
      final chat = fresh.conversations.single;
      expect(chat.id, 'k1');
      expect(chat.title, 'Adventures');
      expect(chat.characterId, 'c1');
      expect(chat.messages.map((m) => m.content), ['hi', 'hello there']);
      // The library.
      expect(fresh.characters.single.name, 'Aqua');
      expect(fresh.lorebooks.single.name, 'Axel');
      expect(fresh.scenarios.single.text, 'Hello');
      expect(fresh.presets, isNotEmpty);
      // The provider, its key included.
      expect(fresh.providers.single.apiKey, 'sk-live');
      expect(fresh.activeProvider?.id, 'p1');
      // The pictures, under the same names — which is what makes a `local:`
      // reference in a message resolve to the same picture again.
      expect(fresh.characters.single.avatar, avatarRef);
      expect(avatarRefFile(avatarRef)!.readAsBytesSync(), _png);
      expect(fresh.gallery.single.image, galleryRef);
      expect(avatarRefFile(galleryRef)!.existsSync(), isTrue);
      // And the vectors.
      expect(File('${vectors.path}/chat-k1.json').existsSync(), isTrue);
    });
  });
  group('restoring over something', () {
    test('replace makes the app exactly the backup again', () async {
      final source = await seeded();
      final bytes = (await source.readBackup(
        (await source.exportBackup(destination: BackupDestination.device))!,
      ))!;

      // Life carries on after the backup: a new character, a renamed chat.
      await source.addCharacter(Character(id: 'later', name: 'Kazuma'));
      await source.renameConversation('k1', 'Renamed');
      expect(source.characters.length, 2);

      await source.restoreBackup(bytes);

      expect(source.characters.map((c) => c.id), ['c1']);
      expect(source.conversationById('k1')!.title, 'Adventures');
    });

    test('merging keeps what came after and folds the backup in', () async {
      final source = await seeded();
      final bytes = (await source.readBackup(
        (await source.exportBackup(destination: BackupDestination.device))!,
      ))!;
      await source.addCharacter(Character(id: 'later', name: 'Kazuma'));
      await source.renameConversation('k1', 'Renamed');

      await source.restoreBackup(bytes, replace: false);

      expect(source.characters.map((c) => c.id), containsAll(['c1', 'later']));
      // The backup's copy of a thing that exists in both wins.
      expect(source.conversationById('k1')!.title, 'Adventures');
    });

    test('a keyless backup does not wipe the key on the device', () async {
      final source = await seeded();
      await source.updateBackupPrefs(
        source.backupPrefs.copyWith(includeKeys: false),
      );
      final record = await source.exportBackup(
        destination: BackupDestination.device,
      );
      expect(record!.includesKeys, isFalse);
      final bytes = (await source.readBackup(record))!;
      // Prove the file really carries no key.
      expect(
        (decodeBackup(bytes).store['providers']!.asMap!['providers'] as List)
            .first,
        containsPair('apiKey', ''),
      );

      await source.restoreBackup(bytes);

      expect(source.providers.single.apiKey, 'sk-live');
    });

    test('a picture the backup left out is not lost from the device', () async {
      final source = await seeded();
      await source.updateBackupPrefs(
        source.backupPrefs.copyWith(includePictures: false),
      );
      final record = await source.exportBackup(
        destination: BackupDestination.device,
      );
      expect(record!.counts.pictures, 0);
      final bytes = (await source.readBackup(record))!;
      final avatarRef = source.characters.single.avatar;

      await source.restoreBackup(bytes);

      // The store still points at the file, and the file is still there — the
      // sweep after a restore keeps whatever the restored store references.
      expect(source.characters.single.avatar, avatarRef);
      expect(avatarRefFile(avatarRef)!.existsSync(), isTrue);
    });
  });
  group('the schedule', () {
    test('takes one when it is due, and not twice in the same period', () async {
      final state = await seeded();
      await state.updateBackupPrefs(state.backupPrefs.copyWith(
        schedule: BackupSchedule.daily,
        autoDestination: BackupDestination.device,
      ));

      final first = await state.runDueBackup(now: DateTime.utc(2026, 8, 30));
      expect(first, isNotNull);
      expect(first!.automatic, isTrue);
      expect(state.backupPrefs.lastRunAt, DateTime.utc(2026, 8, 30));

      // Same day: nothing owed.
      expect(await state.runDueBackup(now: DateTime.utc(2026, 8, 30, 23)), isNull);
      // The next day: owed again.
      expect(await state.runDueBackup(now: DateTime.utc(2026, 8, 31)), isNotNull);
      expect(state.backups.length, 2);
    });

    test('is never due when it is off, or when Drive is not connected', () {
      const off = BackupPrefs();
      expect(off.dueAt(DateTime.utc(2026)), isFalse);
      const drive = BackupPrefs(
        schedule: BackupSchedule.daily,
        autoDestination: BackupDestination.drive,
      );
      expect(drive.dueAt(DateTime.utc(2026)), isFalse);
    });

    test('keeps only as many as the setting says', () async {
      final state = await seeded();
      await state.updateBackupPrefs(state.backupPrefs.copyWith(keep: 2));

      for (var i = 0; i < 4; i++) {
        await state.exportBackup(destination: BackupDestination.device);
      }

      expect(folder.listSync().whereType<File>().length, 2);
      expect(
        state.backups
            .where((r) => r.destination == BackupDestination.device)
            .length,
        2,
      );
      // The two that survived are the newest two.
      final kept = state.backups.map((r) => r.path).toSet();
      for (final file in folder.listSync().whereType<File>()) {
        expect(kept, contains(file.path));
      }
    });

    test('a backup saved to a file of the user\'s is recorded, not kept',
        () async {
      final state = await seeded();
      String? asked;
      final record = await state.exportBackup(
        destination: BackupDestination.file,
        save: (name, bytes) async {
          asked = name;
          return '/somewhere/$name';
        },
      );

      expect(asked, startsWith('maichat-backup-'));
      expect(record!.destination, BackupDestination.file);
      expect(record.restorable, isFalse);
      expect(await state.readBackup(record), isNull);
      expect(folder.listSync(), isEmpty);
    });

    test('a cancelled save records nothing', () async {
      final state = await seeded();
      final record = await state.exportBackup(
        destination: BackupDestination.file,
        save: (name, bytes) async => null,
      );
      expect(record, isNull);
      expect(state.backups, isEmpty);
    });
  });
  group('the records', () {
    test('survive a restart and can be deleted with their file', () async {
      final state = await seeded();
      final record = await state.exportBackup(
        destination: BackupDestination.device,
      );

      // A restart reads the same store.
      final again = await boot();
      expect(again.backups.single.name, record!.name);
      expect(again.backupStats.count, 1);
      expect(again.backupStats.totalBytes, record.bytes);

      await again.deleteBackup(record.id);
      expect(again.backups, isEmpty);
      expect(File(record.path).existsSync(), isFalse);

      // And the deletion is remembered, not just forgotten in memory.
      final third = await boot();
      expect(third.backups, isEmpty);
    });

    test('a backup is not part of a backup', () async {
      final state = await seeded();
      await state.updateBackupPrefs(
        state.backupPrefs.copyWith(schedule: BackupSchedule.weekly),
      );
      final record = await state.exportBackup(
        destination: BackupDestination.device,
      );
      final snapshot = decodeBackup((await state.readBackup(record!))!);
      expect(snapshot.store.containsKey('backups'), isFalse);
      expect(snapshot.store.containsKey('backupPrefs'), isFalse);

      // So restoring an old one leaves the settings and the history alone.
      await state.restoreBackup((await state.readBackup(record))!);
      expect(state.backupPrefs.schedule, BackupSchedule.weekly);
      expect(state.backups, isNotEmpty);
    });

    test('search matches a name, a destination and what is inside', () async {
      final state = await seeded();
      final record = (await state.exportBackup(
        destination: BackupDestination.device,
      ))!;

      expect(record.matches(''), isTrue);
      expect(record.matches('maichat-backup'), isTrue);
      expect(record.matches('in the app'), isTrue);
      expect(record.matches('character'), isTrue);
      expect(record.matches('nonsense'), isFalse);
    });
  });
}
