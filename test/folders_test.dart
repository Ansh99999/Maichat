import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/conversation.dart';
import 'package:maichat/models/folder.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/preset.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stands in for a live endpoint, recording which provider a send went to — the
/// one fact the provider-override wire test turns on.
class FakeClient extends ChatClient {
  FakeClient({this.deltas = const <String>[]});

  final List<String> deltas;
  Provider? lastProvider;

  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    lastProvider = provider;
    for (final delta in deltas) {
      yield ChatDelta(text: delta);
    }
  }

  @override
  Future<List<String>> listModels(Provider provider) async => const <String>[];
}

Provider _provider({required String id, String model = 'm'}) => Provider(
      id: id,
      name: id,
      kind: ProviderKind.openai,
      baseUrl: 'https://host.tld/v1',
      apiKey: 'k',
      model: model,
    );

Future<AppState> _state(FakeClient client) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final state = AppState(client: client);
  await state.init();
  return state;
}

void main() {
  group('the Folder model', () {
    Folder sample() => Folder(
          id: 'f1',
          name: 'Noir',
          color: 0xFF102030,
          avatar: 'local:cover.png',
          tags: const ['detective', 'rain'],
          description: 'A rainy city.',
          characterIds: const ['c1', 'c2'],
          lorebookIds: const ['l1'],
          scenarioIds: const ['s1'],
          presetIds: const ['p1'],
          providerIds: const ['pr1'],
          documentIds: const ['d1'],
          galleryImageIds: const ['g1'],
          defaultPresetId: 'p1',
          defaultProviderId: 'pr1',
          presetOverrides: {'p1': Preset(id: 'p1', name: 'Folder preset')},
          lorebookOverrides: {'l1': Lorebook(id: 'l1', name: 'Folder book')},
          autoLorebooks: true,
          propagateLorebookEdits: true,
          sharedSummary: true,
          sharedEmbeddings: true,
        );

    test('an untitled folder still shows something', () {
      expect(Folder(id: 'x').displayName, 'Untitled folder');
      expect(Folder(id: 'x', name: 'Cases').displayName, 'Cases');
    });

    test('JSON round-trips every field, overrides included', () {
      final restored = Folder.fromJson(sample().toJson());
      expect(restored.id, 'f1');
      expect(restored.name, 'Noir');
      expect(restored.color, 0xFF102030);
      expect(restored.avatar, 'local:cover.png');
      expect(restored.tags, ['detective', 'rain']);
      expect(restored.description, 'A rainy city.');
      expect(restored.characterIds, ['c1', 'c2']);
      expect(restored.lorebookIds, ['l1']);
      expect(restored.scenarioIds, ['s1']);
      expect(restored.presetIds, ['p1']);
      expect(restored.providerIds, ['pr1']);
      expect(restored.documentIds, ['d1']);
      expect(restored.galleryImageIds, ['g1']);
      expect(restored.defaultPresetId, 'p1');
      expect(restored.defaultProviderId, 'pr1');
      expect(restored.presetOverrides['p1']?.displayName, 'Folder preset');
      expect(restored.lorebookOverrides['l1']?.displayName, 'Folder book');
      expect(restored.autoLorebooks, isTrue);
      expect(restored.propagateLorebookEdits, isTrue);
      expect(restored.sharedSummary, isTrue);
      expect(restored.sharedEmbeddings, isTrue);
    });

    test('clone is a deep copy under the same id', () {
      final original = sample();
      final copy = original.clone();
      expect(copy.id, original.id);
      copy.characterIds.add('c3');
      copy.presetOverrides['p1']!.name = 'Mutated';
      expect(original.characterIds, isNot(contains('c3')));
      expect(original.presetOverrides['p1']!.name, 'Folder preset');
    });

    test('holds and matches', () {
      final f = sample();
      expect(f.holds('c1'), isTrue);
      expect(f.holds('nope'), isFalse);
      expect(f.matches('noir'), isTrue);
      expect(f.matches('detective'), isTrue);
      expect(f.matches('rainy'), isTrue); // description
      expect(f.matches('spaceship'), isFalse);
    });
  });

  group('Conversation threading', () {
    test('folderId and providerOverride survive copyAs', () {
      final c = Conversation.empty()
        ..folderId = 'f1'
        ..providerOverride = 'pr9';
      final forked = c.copyAs(id: 'other');
      expect(forked.folderId, 'f1');
      expect(forked.providerOverride, 'pr9');
    });

    test('folderId and providerOverride survive a JSON round-trip', () {
      final c = Conversation.empty()
        ..folderId = 'f1'
        ..providerOverride = 'pr9';
      final restored = Conversation.fromJson(c.toJson());
      expect(restored.folderId, 'f1');
      expect(restored.providerOverride, 'pr9');
    });
  });

  group('AppState folder collection', () {
    test('add / save / duplicate / delete', () async {
      final state = await _state(FakeClient());
      final f = Folder(id: 'f1', name: 'Cases');
      await state.addFolder(f);
      expect(state.folders.single.id, 'f1');
      expect(state.folderById('f1')?.name, 'Cases');

      f.name = 'Old cases';
      await state.saveFolder(f);
      expect(state.folderById('f1')?.name, 'Old cases');

      final dupId = await state.duplicateFolder('f1');
      expect(dupId, isNot('f1'));
      expect(state.folders.length, 2);
      expect(state.folderById(dupId)?.name, 'Old cases (copy)');

      await state.deleteFolder('f1');
      expect(state.folderById('f1'), isNull);
      expect(state.folders.length, 1);
    });

    test('deleteFolder unbinds the chats that were under it', () async {
      final state = await _state(FakeClient());
      final char = Character(id: 'c1', name: 'Kit');
      await state.addCharacter(char);
      await state.addFolder(Folder(id: 'f1', characterIds: const ['c1']));
      final id = state.startChatWithCharacter(char, folderId: 'f1');
      expect(state.conversationById(id)?.folderId, 'f1');

      await state.deleteFolder('f1');
      expect(state.conversationById(id)?.folderId, isNull);
    });

    test('foldersOfCharacter finds every folder a character is in', () async {
      final state = await _state(FakeClient());
      await state.addFolder(Folder(id: 'f1', characterIds: const ['c1']));
      await state.addFolder(Folder(id: 'f2', characterIds: const ['c1', 'c2']));
      await state.addFolder(Folder(id: 'f3', characterIds: const ['c2']));
      final owning = state.foldersOfCharacter('c1').map((f) => f.id).toSet();
      expect(owning, {'f1', 'f2'});
    });

    test('addToFolder is idempotent; removeFromFolder clears the default',
        () async {
      final state = await _state(FakeClient());
      await state.addFolder(Folder(id: 'f1'));
      await state.addToFolder('f1', FolderItemKind.provider, 'pr1');
      await state.addToFolder('f1', FolderItemKind.provider, 'pr1');
      expect(state.folderById('f1')!.providerIds, ['pr1']);

      final f = state.folderById('f1')!..defaultProviderId = 'pr1';
      await state.saveFolder(f);
      await state.removeFromFolder('f1', FolderItemKind.provider, 'pr1');
      expect(state.folderById('f1')!.providerIds, isEmpty);
      expect(state.folderById('f1')!.defaultProviderId, isNull);
    });

    test('folderPresets applies the override; drops missing refs', () async {
      final state = await _state(FakeClient());
      await state.addPreset(Preset(id: 'p1', name: 'Library'));
      final folder = Folder(
        id: 'f1',
        presetIds: const ['p1', 'gone'],
        presetOverrides: {'p1': Preset(id: 'p1', name: 'Folder copy')},
      );
      await state.addFolder(folder);
      final presets = state.folderPresets(folder);
      expect(presets.length, 1); // 'gone' dropped
      expect(presets.single.displayName, 'Folder copy');
    });

    test('folderProviders lists the referenced providers in order', () async {
      final state = await _state(FakeClient());
      await state.addProvider(_provider(id: 'pr1'));
      await state.addProvider(_provider(id: 'pr2'));
      final folder = Folder(id: 'f1', providerIds: const ['pr2', 'pr1']);
      await state.addFolder(folder);
      expect(state.folderProviders(folder).map((p) => p.id), ['pr2', 'pr1']);
    });
  });

  group('provider resolution', () {
    test('providerFor prefers the per-chat override over the active one',
        () async {
      final state = await _state(FakeClient());
      await state.addProvider(_provider(id: 'app'));
      await state.addProvider(_provider(id: 'folder'));
      state.selectProvider('app');

      final plain = Conversation.empty();
      expect(state.providerFor(plain)?.id, 'app');

      final overridden = Conversation.empty()..providerOverride = 'folder';
      expect(state.providerFor(overridden)?.id, 'folder');

      // An override pointing at a deleted provider falls back to the active one.
      final stale = Conversation.empty()..providerOverride = 'ghost';
      expect(state.providerFor(stale)?.id, 'app');
    });

    test('startChatWithCharacter seeds the folder defaults', () async {
      final state = await _state(FakeClient());
      await state.addProvider(_provider(id: 'app'));
      await state.addProvider(_provider(id: 'folderProv'));
      await state.addPreset(Preset(id: 'fp', name: 'Folder preset'));
      state.selectProvider('app');

      final char = Character(id: 'c1', name: 'Kit');
      await state.addCharacter(char);
      await state.addLorebook(Lorebook(id: 'lb', name: 'Folder book'));
      await state.addFolder(Folder(
        id: 'f1',
        characterIds: const ['c1'],
        presetIds: const ['fp'],
        providerIds: const ['folderProv'],
        lorebookIds: const ['lb'],
        defaultPresetId: 'fp',
        defaultProviderId: 'folderProv',
        autoLorebooks: true,
      ));

      final id = state.startChatWithCharacter(char, folderId: 'f1');
      final chat = state.conversationById(id)!;
      expect(chat.folderId, 'f1');
      expect(chat.presetId, 'fp');
      expect(chat.providerOverride, 'folderProv');
      expect(chat.lorebookIds, contains('lb'));
    });

    test('a foldered chat sends to its override provider, not the active one',
        () async {
      final client = FakeClient(deltas: const ['ok']);
      final state = await _state(client);
      await state.addProvider(_provider(id: 'app', model: 'app-model'));
      await state.addProvider(_provider(id: 'folderProv', model: 'folder-model'));
      state.selectProvider('app');

      final char = Character(id: 'c1', name: 'Kit');
      await state.addCharacter(char);
      await state.addFolder(Folder(
        id: 'f1',
        characterIds: const ['c1'],
        providerIds: const ['folderProv'],
        defaultProviderId: 'folderProv',
      ));

      state.startChatWithCharacter(char, folderId: 'f1');
      await state.send('hello');

      expect(client.lastProvider?.id, 'folderProv');
    });
  });
}
