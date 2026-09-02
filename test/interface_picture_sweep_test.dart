import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/conversation.dart';
import 'package:maichat/services/avatar_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A real 1x1 PNG, so what is written is a picture a decoder would accept.
final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA'
    'DUlEQVR42mP8z8DAwAAABQABg1z0GwAAAABJRU5ErkJggg==');

/// The picture sweep deletes every file its keep-list does not name, and the list
/// used to name only characters, lorebooks, the gallery and the per-conversation
/// places. A picture held by the interface itself — the group-chat participant
/// bar's background — was claimed by nobody, so the next sweep threw it away.
///
/// It is not only a display bug: a backup ships the pictures directory as it
/// finds it, so a picture already swept could not be in the backup either.
void main() {
  late Directory pictures;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    pictures = Directory.systemTemp.createTempSync('sweep-pictures');
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

  int filesOnDisk() =>
      pictures.listSync().whereType<File>().length;

  test('a participant-bar picture survives the next sweep', () async {
    final state = await boot();
    final ref = await state.storePicture(_png);
    expect(ref, isNotNull, reason: 'the picture should have been filed');
    await state.updateChatInterface(
        state.chatInterface.copyWith(groupBarImage: ref));
    expect(filesOnDisk(), 1);

    // A fresh app over the same store and the same directory: init sweeps.
    final reopened = await boot();
    expect(reopened.chatInterface.groupBarImage, ref);
    expect(filesOnDisk(), 1,
        reason: 'the interface claims this picture, so it must be kept');
  });
  test("a chat's own copy of the interface keeps its picture too", () async {
    final state = await boot();
    final ref = await state.storePicture(_png);
    final conversation = Conversation(
      id: 'c1',
      title: 'Styled',
      messages: [],
      updatedAt: DateTime.now(),
    );
    conversation.interfaceOverride =
        const ChatInterface().copyWith(groupBarImage: ref);
    await state.importConversations([conversation]);
    expect(filesOnDisk(), 1);

    final reopened = await boot();
    expect(reopened.conversationById('c1')?.interfaceOverride?.groupBarImage,
        ref);
    expect(filesOnDisk(), 1,
        reason: 'a per-chat copy names its own pictures');
  });

  test("a saved look's picture is kept until the look is dropped", () async {
    final state = await boot();
    final ref = await state.storePicture(_png);
    await state.updateChatInterface(
        state.chatInterface.copyWith(backgroundImage: ref));
    final saved = await state.saveInterfacePreset('With a background');
    // Hand the app-wide settings back to the defaults: now the *look* is the only
    // thing referring to the picture.
    await state.updateChatInterface(const ChatInterface());
    expect(state.chatInterface.backgroundImage, isNull);

    final reopened = await boot();
    expect(reopened.savedInterfacePresets.single.ui.backgroundImage, ref);
    expect(filesOnDisk(), 1, reason: 'a saved look claims its own pictures');

    // Drop the look and the picture goes with it — the sweep runs on delete.
    await reopened.deleteInterfacePreset(saved!.id);
    expect(filesOnDisk(), 0);
  });

  test('a picture nothing refers to is still swept', () async {
    final state = await boot();
    await state.storePicture(_png);
    expect(filesOnDisk(), 1);

    // Nobody claimed it, so it is exactly what the sweep is for.
    await boot();
    expect(filesOnDisk(), 0);
  });

  test('the model names its own pictures in one place', () {
    const bare = ChatInterface();
    expect(bare.pictureRefs, isEmpty);
    expect(
      const ChatInterface(groupBarImage: 'local:bar.png').pictureRefs,
      ['local:bar.png'],
    );
    expect(
      const ChatInterface(
        groupBarImage: 'local:bar.png',
        backgroundImage: 'local:bg.png',
      ).pictureRefs,
      ['local:bar.png', 'local:bg.png'],
    );
    // An empty string is not a reference, and must not become a keep-list entry
    // that matches a file name of its own.
    expect(const ChatInterface(groupBarImage: '').pictureRefs, isEmpty);
  });
}

