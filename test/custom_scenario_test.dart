import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/services/character_codec.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A custom scenario is only worth anything if it actually reaches the model, so
/// this asserts the whole path: the model's single resolution point, persistence,
/// the wire, and the round-trip through an export.

class _FakeClient extends ChatClient {
  List<ChatMessage>? lastHistory;

  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    lastHistory = List<ChatMessage>.from(history);
    yield const ChatDelta(text: 'ok');
  }

  @override
  Future<List<String>> listModels(Provider provider) async => const [];
}

Provider _provider() => Provider(
      id: 'p',
      name: 'Test',
      kind: ProviderKind.openai,
      baseUrl: 'https://host.tld/v1',
      apiKey: 'k',
      model: 'm',
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('resolution', () {
    test("with none written, the card's scenario is the active one", () {
      final c = Character(id: 'c', name: 'Aria', scenario: 'A rainy night.');
      expect(c.activeScenario, 'A rainy night.');
      expect(c.hasCustomScenario, isFalse);
    });

    test('a custom scenario wins without destroying the card\'s', () {
      final c = Character(
        id: 'c',
        name: 'Aria',
        scenario: 'A rainy night.',
        customScenario: 'A bright morning.',
      );
      expect(c.activeScenario, 'A bright morning.');
      expect(c.scenario, 'A rainy night.');
      expect(c.hasCustomScenario, isTrue);
    });

    test('whitespace is not a scenario', () {
      final c = Character(
        id: 'c',
        name: 'Aria',
        scenario: 'Card.',
        customScenario: '   \n ',
      );
      expect(c.activeScenario, 'Card.');
      expect(c.hasCustomScenario, isFalse);
    });

    test('the composed persona and the definition both use the active one', () {
      final c = Character(
        id: 'c',
        name: 'Aria',
        description: 'A librarian.',
        scenario: 'Card scenario.',
        customScenario: 'Custom scenario.',
      );
      expect(c.composedSystemPrompt(), contains('Custom scenario.'));
      expect(c.composedSystemPrompt(), isNot(contains('Card scenario.')));
      expect(c.definition(), contains('Custom scenario.'));
      expect(c.definition(), isNot(contains('Card scenario.')));
    });
  });

  group('persistence', () {
    test('it round-trips through JSON', () {
      final c = Character(
        id: 'c',
        name: 'Aria',
        scenario: 'Card.',
        customScenario: 'Mine.',
      );
      final back = Character.fromJson(c.toJson());
      expect(back.scenario, 'Card.');
      expect(back.customScenario, 'Mine.');
      expect(back.activeScenario, 'Mine.');
    });

    test('a card without one writes no key, so old stores read unchanged', () {
      final c = Character(id: 'c', name: 'Aria', scenario: 'Card.');
      expect(c.toJson().containsKey('customScenario'), isFalse);
      expect(Character.fromJson(c.toJson()).customScenario, isEmpty);
    });

    test('a clone and a duplicate carry it', () {
      final c = Character(
        id: 'c',
        name: 'Aria',
        scenario: 'Card.',
        customScenario: 'Mine.',
      );
      expect(c.clone().customScenario, 'Mine.');
      expect(c.copyWith(id: 'other').customScenario, 'Mine.');
    });

    test('AppState saves and clears it', () async {
      final state = AppState(client: _FakeClient());
      await state.init();
      await state.addCharacter(
          Character(id: 'c', name: 'Aria', scenario: 'Card.'));

      await state.setCustomScenario('c', '  Mine.  ');
      expect(state.characterById('c')!.customScenario, 'Mine.');
      expect(state.characterById('c')!.activeScenario, 'Mine.');

      await state.setCustomScenario('c', '');
      expect(state.characterById('c')!.customScenario, isEmpty);
      expect(state.characterById('c')!.activeScenario, 'Card.');
    });
  });

  group('the wire', () {
    test('the custom scenario is what the request carries', () async {
      final client = _FakeClient();
      final state = AppState(client: client);
      await state.init();
      await state.addProvider(_provider());
      await state.selectProvider('p');

      final character = Character(
        id: 'c',
        name: 'Aria',
        description: 'A librarian.',
        scenario: 'The card says: a rainy night at the archive.',
        customScenario: 'Mine says: a bright morning on the roof.',
      );
      await state.addCharacter(character);
      state.startChatWithCharacter(character);
      await state.send('hello');

      final wire = client.lastHistory!.map((m) => m.content).join('\n');
      expect(wire, contains('a bright morning on the roof'));
      expect(wire, isNot(contains('a rainy night at the archive')),
          reason: "the card's scenario reached the model instead of the user's");
    });
  });

  group('export', () {
    test('the active scenario goes out in the standard slot', () {
      final c = Character(
        id: 'c',
        name: 'Aria',
        scenario: 'Card.',
        customScenario: 'Mine.',
      );
      final json = CharacterCodec.exportTavernV2(c);
      // Another app reads `scenario` and knows nothing of ours, so it must find
      // the one actually in force.
      expect(json, contains('"scenario": "Mine."'));
      expect(json, contains('cardScenario'));
    });

    test('our own export round-trips both halves', () {
      final c = Character(
        id: 'c',
        name: 'Aria',
        scenario: 'Card.',
        customScenario: 'Mine.',
      );
      final back = CharacterCodec.parseJson(CharacterCodec.exportTavernV2(c));
      expect(back.customScenario, 'Mine.');
      expect(back.scenario, 'Card.');
      expect(back.activeScenario, 'Mine.');
    });

    test("a foreign card's scenario lands as the card's, not as a custom one",
        () {
      const foreign = '{"spec":"chara_card_v2","spec_version":"2.0","data":'
          '{"name":"Aria","scenario":"Theirs."}}';
      final c = CharacterCodec.parseJson(foreign);
      expect(c.scenario, 'Theirs.');
      expect(c.customScenario, isEmpty);
      expect(c.hasCustomScenario, isFalse);
    });

    test('a card we exported with no custom scenario reads back plainly', () {
      final c = Character(id: 'c', name: 'Aria', scenario: 'Card.');
      final back = CharacterCodec.parseJson(CharacterCodec.exportTavernV2(c));
      expect(back.scenario, 'Card.');
      expect(back.customScenario, isEmpty);
    });
  });
}
