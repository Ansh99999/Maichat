import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/services/storage.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<AppState> _state({Storage? storage}) async {
  final state = AppState(storage: storage);
  await state.init();
  return state;
}

Character _char({required String id, required String name}) =>
    Character(id: id, name: name, description: 'desc of $name');

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('setDefaultPersona resolves and only fires when it changes', () async {
    final state = await _state();
    await state.addCharacter(_char(id: 'me', name: 'Mai'));
    expect(state.defaultPersona, isNull);

    var ticks = 0;
    state.addListener(() => ticks++);
    await state.setDefaultPersona('me');
    expect(state.defaultPersona?.id, 'me');
    expect(ticks, 1);

    // Setting the same id again is a no-op — no needless rebuild or write.
    await state.setDefaultPersona('me');
    expect(ticks, 1);
  });

  test('a fresh chat adopts the default persona', () async {
    final state = await _state();
    await state.addCharacter(_char(id: 'me', name: 'Mai'));
    await state.setDefaultPersona('me');

    state.newConversation();
    expect(state.active.impersonateId, 'me');
    expect(state.active.impersonateName, 'Mai');
  });

  test('with no default persona a fresh chat has none', () async {
    final state = await _state();
    state.newConversation();
    expect(state.active.impersonateId, isNull);
  });

  test('starting a character chat adopts the default persona', () async {
    final state = await _state();
    await state.addCharacter(_char(id: 'me', name: 'Mai'));
    await state.addCharacter(_char(id: 'ai', name: 'Aria'));
    await state.setDefaultPersona('me');

    final id = state.startChatWithCharacter(state.characterById('ai')!);
    final chat = state.conversationById(id)!;
    expect(chat.characterId, 'ai');
    expect(chat.impersonateId, 'me');
  });

  test('you never impersonate the character you are chatting with', () async {
    final state = await _state();
    await state.addCharacter(_char(id: 'me', name: 'Mai'));
    await state.setDefaultPersona('me');

    final id = state.startChatWithCharacter(state.characterById('me')!);
    final chat = state.conversationById(id)!;
    expect(chat.impersonateId, isNull);
  });

  test('deleting the persona character clears the default', () async {
    final storage = Storage();
    final state = await _state(storage: storage);
    await state.addCharacter(_char(id: 'me', name: 'Mai'));
    await state.setDefaultPersona('me');

    await state.deleteCharacter('me');
    expect(state.defaultPersona, isNull);
    expect(state.defaultPersonaId, isNull);
    // The cleared pointer is persisted, not just forgotten in memory.
    expect(await storage.loadDefaultPersonaId(), isNull);
  });

  test('the default persona survives a restart', () async {
    final storage = Storage();
    final first = await _state(storage: storage);
    await first.addCharacter(_char(id: 'me', name: 'Mai'));
    await first.setDefaultPersona('me');

    final second = await _state(storage: storage);
    expect(second.defaultPersonaId, 'me');
    expect(second.defaultPersona?.name, 'Mai');
  });

  test('a dangling persona id is dropped on load', () async {
    final storage = Storage();
    await storage.saveDefaultPersonaId('ghost'); // no such character
    final state = await _state(storage: storage);
    expect(state.defaultPersonaId, isNull);
  });
}
