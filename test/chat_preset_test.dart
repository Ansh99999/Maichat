import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/preset.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeClient extends ChatClient {
  @override
  Future<List<String>> listModels(Provider provider) async => const [];
}

Future<AppState> _state() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final state = AppState(client: _FakeClient());
  await state.init();
  return state;
}

void main() {
  test('choosing a preset binds the chat and clears any override', () async {
    final state = await _state();
    final a = Preset.create(name: 'Alpha');
    await state.addPreset(a);
    final conv = state.active;

    await state.setConversationPreset(conv.id, a.id);
    expect(state.presetFor(conv)!.id, a.id);
    expect(conv.presetOverride, isNull);
  });

  test('save-for-this-chat stores an override without touching the library',
      () async {
    final state = await _state();
    final a = Preset.create(name: 'Alpha');
    await state.addPreset(a);
    final conv = state.active;
    await state.setConversationPreset(conv.id, a.id);

    final edited = Preset.fromJson(a.toJson())
      ..name = 'Alpha (this chat)'
      ..temperature = 0.3;
    await state.saveChatPresetOverride(conv.id, edited);

    // The chat now sees the override…
    expect(state.presetFor(conv)!.name, 'Alpha (this chat)');
    expect(state.presetFor(conv)!.temperature, 0.3);
    // …but the shared library preset is unchanged.
    expect(state.presetById(a.id)!.name, 'Alpha');
    expect(state.presetById(a.id)!.temperature, a.temperature);
  });

  test('save-for-entire-preset updates the library and clears the override',
      () async {
    final state = await _state();
    final a = Preset.create(name: 'Alpha');
    await state.addPreset(a);
    final conv = state.active;
    await state.saveChatPresetOverride(
      conv.id,
      Preset.fromJson(a.toJson())..name = 'temp override',
    );
    expect(conv.presetOverride, isNotNull);

    final edited = Preset.fromJson(a.toJson())..name = 'Alpha v2';
    await state.savePresetToLibrary(conv.id, edited);

    expect(state.presetById(a.id)!.name, 'Alpha v2');
    expect(conv.presetOverride, isNull);
    expect(conv.presetId, a.id);
    expect(state.presetFor(conv)!.name, 'Alpha v2');
  });

  test('an override survives a reload from storage', () async {
    final state = await _state();
    final a = Preset.create(name: 'Alpha');
    await state.addPreset(a);
    final conv = state.active;
    await state.setConversationPreset(conv.id, a.id);
    await state.saveChatPresetOverride(
      conv.id,
      Preset.fromJson(a.toJson())..name = 'Kept',
    );

    final reopened = AppState(client: _FakeClient());
    await reopened.init();
    final reloaded = reopened.conversations.firstWhere((c) => c.id == conv.id);
    expect(reloaded.presetOverride, isNotNull);
    expect(reopened.presetFor(reloaded)!.name, 'Kept');
  });
}
