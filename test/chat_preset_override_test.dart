import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/preset.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A "save for this chat only" pins the chat to a frozen copy of the preset.
/// That is intended, but it used to be invisible and irreversible from the UI:
/// afterwards every edit to the shared preset (raising the context size, for
/// instance) applied everywhere except that chat, with nothing on screen to
/// explain it. The chat must be able to rejoin the library preset.
void main() {
  Future<AppState> boot() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final state = AppState();
    await state.init();
    await state.addProvider(Provider(
      id: 'p',
      name: 'l',
      kind: ProviderKind.openai,
      baseUrl: 'https://example.com/v1',
      model: 'm',
      apiKey: 'k',
    ));
    return state;
  }

  test('a chat override shadows later library edits until it is cleared',
      () async {
    final state = await boot();
    final preset = Preset.create(name: 'Mine')..maxContext = 4095;
    await state.addPreset(preset);
    await state.setDefaultPreset(preset.id);

    final card = Character(id: 'c', name: 'C', description: 'D');
    await state.addCharacter(card);
    final chatId = state.startChatWithCharacter(card);
    await state.setConversationPreset(chatId, preset.id);

    // "This chat only" — the chat is now pinned to a snapshot.
    await state.saveChatPresetOverride(chatId, preset);
    expect(state.hasPresetOverride(state.active), isTrue);

    // The user raises the context size on the shared preset.
    await state.savePreset(Preset.fromJson(preset.toJson())..maxContext = 92000);
    expect(state.presetById(preset.id)!.maxContext, 92000);
    // The pinned chat deliberately keeps its own value...
    expect(state.presetFor(state.active)?.maxContext, 4095);

    // ...and can rejoin the shared preset, which is what the UI now offers.
    await state.clearChatPresetOverride(chatId);
    expect(state.hasPresetOverride(state.active), isFalse);
    expect(state.presetFor(state.active)?.maxContext, 92000);
  });

  test('clearing an override the chat does not have is a no-op', () async {
    final state = await boot();
    final preset = Preset.create(name: 'Mine');
    await state.addPreset(preset);
    final card = Character(id: 'c', name: 'C');
    await state.addCharacter(card);
    final chatId = state.startChatWithCharacter(card);

    await state.clearChatPresetOverride(chatId);
    expect(state.hasPresetOverride(state.active), isFalse);
  });
}
