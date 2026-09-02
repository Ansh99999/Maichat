import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/backup.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/conversation.dart';
import 'package:maichat/models/interface_preset.dart';
import 'package:maichat/services/avatar_store.dart';
import 'package:maichat/services/backup_store.dart';
import 'package:maichat/services/embedding_store.dart';
import 'package:maichat/services/interface_preset_io.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A real 1x1 PNG, so what is written is a picture a decoder would accept.
final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA'
    'DUlEQVR42mP8z8DAwAAABQABg1z0GwAAAABJRU5ErkJggg==');

void main() {
  late Directory pictures;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    pictures = Directory.systemTemp.createTempSync('looks');
  });

  tearDown(() {
    pictures.deleteSync(recursive: true);
    avatarDirectory = null;
  });

  Future<AppState> boot() async {
    final state = AppState(avatars: AvatarStore(pictures));
    await state.init();
    return state;
  }

  group('a look carries appearance, not behaviour', () {
    test('lookOnly puts the Chat behaviour switches back', () {
      const busy = ChatInterface(
        bubbles: false,
        groupChatsEnabled: true,
        responseHintEnabled: true,
        responseHintDepth: 5,
      );
      final look = busy.lookOnly;
      expect(look.bubbles, isFalse, reason: 'appearance is kept');
      expect(look.groupChatsEnabled, isFalse);
      expect(look.responseHintEnabled, isFalse);
      expect(look.responseHintDepth, kDefaultResponseHintDepth);
    });

    test('applying a look leaves the behaviour switches as they were', () {
      const current = ChatInterface(
        groupChatsEnabled: true,
        responseHintEnabled: true,
        responseHintDepth: 7,
      );
      const look = ChatInterface(bubbles: false, fontSize: 20);
      final next = current.applyLook(look);

      expect(next.bubbles, isFalse);
      expect(next.fontSize, 20);
      // Switching to a look must not switch off a feature.
      expect(next.groupChatsEnabled, isTrue);
      expect(next.responseHintEnabled, isTrue);
      expect(next.responseHintDepth, 7);
    });
  });
  group('saving, applying and dropping a look', () {
    test('the shipped looks are offered and cannot be deleted', () async {
      final state = await boot();
      expect(state.interfacePresets, hasLength(kBuiltInInterfacePresets.length));
      expect(state.savedInterfacePresets, isEmpty);

      final builtIn = state.interfacePresets.first;
      expect(builtIn.isBuiltIn, isTrue);
      await state.deleteInterfacePreset(builtIn.id);
      expect(state.interfacePresets, hasLength(kBuiltInInterfacePresets.length));
    });

    test('a saved look survives a restart, and behaviour is not in it',
        () async {
      final state = await boot();
      await state.updateChatInterface(const ChatInterface(
        bubbles: false,
        fontSize: 21,
        groupChatsEnabled: true,
      ));
      final saved = await state.saveInterfacePreset('  Night reading  ');
      expect(saved, isNotNull);
      expect(saved!.name, 'Night reading', reason: 'the name is trimmed');
      expect(saved.ui.fontSize, 21);
      expect(saved.ui.groupChatsEnabled, isFalse,
          reason: 'a look never carries a feature switch');

      final reopened = await boot();
      final restored = reopened.savedInterfacePresets.single;
      expect(restored.name, 'Night reading');
      expect(restored.ui.bubbles, isFalse);
      expect(restored.ui.fontSize, 21);
    });

    test('an empty name saves nothing', () async {
      final state = await boot();
      expect(await state.saveInterfacePreset('   '), isNull);
      expect(state.savedInterfacePresets, isEmpty);
    });

    test('a look can be renamed and dropped', () async {
      final state = await boot();
      final saved = await state.saveInterfacePreset('First');
      await state.renameInterfacePreset(saved!.id, 'Second');
      expect(state.savedInterfacePresets.single.name, 'Second');

      await state.deleteInterfacePreset(saved.id);
      expect(state.savedInterfacePresets, isEmpty);
    });
  });
  group('what applying a look reaches', () {
    Future<AppState> withTwoChats() async {
      final state = await boot();
      await state.importConversations([
        Conversation(
            id: 'a', title: 'A', messages: [], updatedAt: DateTime.now()),
        Conversation(
            id: 'b', title: 'B', messages: [], updatedAt: DateTime.now()),
      ]);
      return state;
    }

    test('app-wide, it dresses every chat that has no copy of its own',
        () async {
      final state = await withTwoChats();
      await state.updateChatInterface(
          state.chatInterface.copyWith(groupChatsEnabled: true));
      final document = kBuiltInInterfacePresets
          .firstWhere((p) => p.name == 'Document');

      await state.applyInterfacePreset(document);

      expect(state.chatInterface.bubbles, isFalse);
      expect(state.interfaceFor(state.conversationById('a')).bubbles, isFalse);
      expect(state.interfaceFor(state.conversationById('b')).bubbles, isFalse);
      // Group chats stay on across the switch.
      expect(state.chatInterface.groupChatsEnabled, isTrue);
      // And no chat was given a copy of its own.
      expect(state.hasInterfaceOverride(state.conversationById('a')!), isFalse);
    });

    test('for one chat, it leaves the app and its sibling alone', () async {
      final state = await withTwoChats();
      final document = kBuiltInInterfacePresets
          .firstWhere((p) => p.name == 'Document');

      await state.applyInterfacePreset(document, conversationId: 'a');

      expect(state.interfaceFor(state.conversationById('a')).bubbles, isFalse);
      expect(state.hasInterfaceOverride(state.conversationById('a')!), isTrue);
      // The app-wide look and the other thread are untouched.
      expect(state.chatInterface.bubbles, isTrue);
      expect(state.interfaceFor(state.conversationById('b')).bubbles, isTrue);
    });

    test('the look in force is the one reported active', () async {
      final state = await withTwoChats();
      final bubbles =
          kBuiltInInterfacePresets.firstWhere((p) => p.name == 'Bubbles');
      final document =
          kBuiltInInterfacePresets.firstWhere((p) => p.name == 'Document');

      expect(state.isInterfacePresetActive(bubbles), isTrue);
      expect(state.isInterfacePresetActive(document), isFalse);

      // A behaviour switch must not make every look read as unselected.
      await state.updateChatInterface(
          state.chatInterface.copyWith(responseHintEnabled: true));
      expect(state.isInterfacePresetActive(bubbles), isTrue);

      await state.applyInterfacePreset(document, conversationId: 'a');
      expect(state.isInterfacePresetActive(document, conversationId: 'a'),
          isTrue);
      expect(state.isInterfacePresetActive(bubbles, conversationId: 'a'),
          isFalse);
      expect(state.isInterfacePresetActive(bubbles), isTrue,
          reason: 'app-wide is still Bubbles');
    });
  });
  group('out to a file and back', () {
    test('a look carries its pictures, and comes back with new names',
        () async {
      final state = await boot();
      final ref = await state.storePicture(_png);
      await state.updateChatInterface(state.chatInterface.copyWith(
        groupBarImage: ref,
        backgroundImage: ref,
        fontSize: 19,
        bubbles: false,
      ));
      final saved = await state.saveInterfacePreset('Carried');

      final file = exportInterfacePreset(
        saved!,
        read: (r) => avatarRefFile(r)!.readAsBytesSync(),
      );
      expect(file['format'], kInterfacePresetFormat);
      expect(file['name'], 'Carried');
      final carried = file['pictures'] as Map;
      expect(carried.keys, [ref], reason: 'one file, referred to twice');
      expect(base64Decode(carried[ref] as String), _png);

      // Read it back on a device that has never seen that file name.
      final elsewhere = Directory.systemTemp.createTempSync('elsewhere');
      addTearDown(() => elsewhere.deleteSync(recursive: true));
      final store = AvatarStore(elsewhere);
      final landed = await importInterfacePreset(
        jsonDecode(jsonEncode(file)),
        store: (bytes) async => store.write(bytes),
      );

      expect(landed.name, 'Carried');
      expect(landed.ui.fontSize, 19);
      expect(landed.ui.bubbles, isFalse);
      expect(landed.ui.backgroundImage, isNotNull);
      expect(landed.ui.groupBarImage, landed.ui.backgroundImage,
          reason: 'both references point at the one picture that was carried');
      expect(avatarRefFile(landed.ui.backgroundImage!)!.readAsBytesSync(), _png);
      expect(landed.isBuiltIn, isFalse);
    });

    test('a reference whose file has gone is dropped, not exported dangling',
        () async {
      const preset = InterfacePreset(
        id: 'look-1',
        name: 'Missing',
        ui: ChatInterface(groupBarImage: 'local:gone.png'),
      );
      final file = exportInterfacePreset(preset, read: (_) => null);
      expect(file.containsKey('pictures'), isFalse);
      expect((file['ui'] as Map).containsKey('groupBarImage'), isFalse);
    });

    test('a URL background needs no carrying and survives untouched', () async {
      const preset = InterfacePreset(
        id: 'look-1',
        name: 'Remote',
        ui: ChatInterface(backgroundImage: 'https://host.tld/bg.png'),
      );
      final file = exportInterfacePreset(preset, read: (_) => null);
      expect((file['ui'] as Map)['backgroundImage'], 'https://host.tld/bg.png');

      final landed = await importInterfacePreset(
        jsonDecode(jsonEncode(file)),
        store: (_) async => fail('nothing should be filed'),
      );
      expect(landed.ui.backgroundImage, 'https://host.tld/bg.png');
    });
    test('a file that is not one of ours is turned away with a sentence',
        () async {
      expect(looksLikeInterfacePreset({'format': 'something.else'}), isFalse);
      expect(looksLikeInterfacePreset({'format': kInterfacePresetFormat}),
          isTrue);

      await expectLater(
        importInterfacePreset('not even a map', store: (_) async => null),
        throwsA(isA<InterfacePresetFormatException>()),
      );
      await expectLater(
        importInterfacePreset({'format': 'agnai.preset'},
            store: (_) async => null),
        throwsA(predicate((e) =>
            e is InterfacePresetFormatException &&
            e.message.contains('not a MaiChat chat-interface look'))),
      );
      await expectLater(
        importInterfacePreset({
          'format': kInterfacePresetFormat,
          'formatVersion': kInterfacePresetFormatVersion + 1,
        }, store: (_) async => null),
        throwsA(predicate((e) =>
            e is InterfacePresetFormatException &&
            e.message.contains('newer version'))),
      );
    });

    test('an imported look is filed fresh, never over a built-in', () async {
      final state = await boot();
      final filed = await state.addInterfacePreset(const InterfacePreset(
        id: '${kBuiltInPresetPrefix}document',
        name: 'Impostor',
        ui: ChatInterface(fontSize: 25),
      ));

      expect(filed.isBuiltIn, isFalse,
          reason: 'a file cannot claim a shipped look\'s identity');
      expect(state.savedInterfacePresets.single.name, 'Impostor');
      // The real Document is still there and still itself.
      final document = state.interfacePresets
          .firstWhere((p) => p.id == '${kBuiltInPresetPrefix}document');
      expect(document.name, 'Document');
    });
  });

  group('a backup carries the looks', () {
    test('saved looks and their pictures come back after a restore', () async {
      final vectors = Directory.systemTemp.createTempSync('looks-vectors');
      final folder = Directory.systemTemp.createTempSync('looks-backups');
      addTearDown(() {
        vectors.deleteSync(recursive: true);
        folder.deleteSync(recursive: true);
      });

      Future<AppState> bootWithBackups({bool fresh = false}) async {
        if (fresh) SharedPreferences.setMockInitialValues(<String, Object>{});
        final state = AppState(
          avatars: AvatarStore(pictures),
          embeddings: EmbeddingStore(vectors),
          backups: BackupStore(folder),
        );
        await state.init();
        return state;
      }

      final source = await bootWithBackups(fresh: true);
      final ref = await source.storePicture(_png);
      await source.updateChatInterface(
          source.chatInterface.copyWith(backgroundImage: ref, fontSize: 23));
      await source.saveInterfacePreset('Travelling look');

      final record = await source.exportBackup(
        destination: BackupDestination.device,
      );
      final bytes = (await source.readBackup(record!))!;

      // A new device: nothing in the store, no pictures on disk.
      for (final file in pictures.listSync()) {
        file.deleteSync();
      }
      final fresh = await bootWithBackups(fresh: true);
      expect(fresh.savedInterfacePresets, isEmpty);

      await fresh.restoreBackup(bytes);

      // The look is back — carried by the store copy, which a backup takes entry
      // by entry, so nothing had to teach the backup code what a look is.
      final restored = fresh.savedInterfacePresets.single;
      expect(restored.name, 'Travelling look');
      expect(restored.ui.fontSize, 23);
      expect(restored.ui.backgroundImage, ref);
      // And so is the picture it points at.
      expect(avatarRefFile(ref!)!.existsSync(), isTrue);
    });
  });
}




