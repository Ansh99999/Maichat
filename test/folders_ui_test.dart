import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/folder.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/preset.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/screens/folders/folder_edit_screen.dart';
import 'package:maichat/screens/folders/folder_essentials_screen.dart';
import 'package:maichat/screens/folders/folder_settings_screen.dart';
import 'package:maichat/screens/folders/folder_window.dart';
import 'package:maichat/screens/characters_screen.dart';
import 'package:maichat/services/avatar_store.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// Smoke tests for the folder screens: the model/state layer is covered in
/// folders_test.dart, but these screens are only exercised here — a build-time
/// throw (bad context read, null deref) would otherwise ship unseen since there
/// is no device to open them on.
class _FakeClient extends ChatClient {
  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {}

  @override
  Future<List<String>> listModels(Provider provider) async => const <String>[];
}

void main() {
  late Directory dir;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = Directory.systemTemp.createTempSync('folders-ui');
  });
  tearDown(() {
    dir.deleteSync(recursive: true);
    avatarDirectory = null;
  });

  // A folder with real, resolvable essentials — no avatar, so no file I/O.
  Future<AppState> boot() async {
    final state = AppState(client: _FakeClient(), avatars: AvatarStore(dir));
    await state.init();
    await state.addProvider(Provider(
      id: 'pr1',
      name: 'local',
      kind: ProviderKind.openai,
      baseUrl: 'https://host.tld/v1',
      model: 'm',
      apiKey: 'k',
    ));
    await state.addPreset(Preset(id: 'p1', name: 'Library'));
    await state.addCharacter(Character(id: 'c1', name: 'Kit'));
    await state.addFolder(Folder(
      id: 'f1',
      name: 'Noir',
      color: 0xFF102030,
      tags: const ['detective'],
      description: 'A rainy city.',
      characterIds: const ['c1'],
      presetIds: const ['p1'],
      providerIds: const ['pr1'],
      defaultPresetId: 'p1',
      defaultProviderId: 'pr1',
    ));
    return state;
  }

  Widget host(AppState state, Widget screen) =>
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(home: screen),
      );

  testWidgets('FoldersScreen builds and lists the folder', (tester) async {
    final state = await boot();
    await tester.pumpWidget(host(state, const CharactersScreen()));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // Switch the roster over to the inline folder list.
    await tester.tap(find.text('Folders'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Noir'), findsWidgets);
  });

  testWidgets('FolderEditScreen builds for an existing folder', (tester) async {
    final state = await boot();
    await tester.pumpWidget(
        host(state, FolderEditScreen(folder: state.folderById('f1'))));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('FolderEditScreen builds in create mode', (tester) async {
    final state = await boot();
    await tester.pumpWidget(host(state, const FolderEditScreen()));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('FolderEssentialsScreen builds', (tester) async {
    final state = await boot();
    await tester.pumpWidget(
        host(state, FolderEssentialsScreen(folder: state.folderById('f1')!)));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('folder window opens and tints from the folder', (tester) async {
    final state = await boot();
    await tester.pumpWidget(
      host(
        state,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showFolderWindow(context, folderId: 'f1'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Noir'), findsWidgets);
    expect(find.text('Kit'), findsWidgets);
  });

  testWidgets('FolderSettingsScreen builds', (tester) async {
    final state = await boot();
    await tester.pumpWidget(
        host(state, FolderSettingsScreen(folder: state.folderById('f1')!)));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
