import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/conversation.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/services/chat_codec.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records the exact history handed to the wire layer.
class _CaptureClient extends ChatClient {
  List<ChatMessage>? lastHistory;

  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    lastHistory = history;
    yield const ChatDelta(text: 'ok');
  }

  @override
  Future<List<String>> listModels(Provider provider) async => const [];
}

Future<(AppState, _CaptureClient)> _state() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final client = _CaptureClient();
  final state = AppState(client: client);
  await state.init();
  await state.addProvider(Provider(
    id: 'p',
    name: 'p',
    kind: ProviderKind.openai,
    baseUrl: 'https://example.com/v1',
    model: 'gpt',
    apiKey: 'k',
  ));
  return (state, client);
}

String _dump(List<ChatMessage>? msgs) =>
    (msgs ?? const <ChatMessage>[]).map((m) => '${m.role}: ${m.content}').join('\n');

Character _alice() => Character(
      id: 'alice',
      name: 'Alice',
      description: 'A curious explorer.',
      personality: 'Bold and kind.',
      firstMes: 'Hi, I am Alice.',
    );

Character _bob() => Character(
      id: 'bob',
      name: 'Bob',
      description: 'A gruff sailor.',
      personality: 'Weathered.',
    );

Character _cara() => Character(id: 'cara', name: 'Cara', description: 'A shy healer.');

void main() {
  group('models', () {
    test('Conversation carries participantIds across JSON', () {
      final c = Conversation.empty()
        ..characterId = 'alice'
        ..participantIds.addAll(['alice', 'bob', 'cara']);
      final back = Conversation.fromJson(c.toJson());
      expect(back.participantIds, ['alice', 'bob', 'cara']);
      expect(back.isGroup, isTrue);
      expect(back.memberIds, ['alice', 'bob', 'cara']);
    });

    test('a one-to-one thread is not a group and stores no participants', () {
      final c = Conversation.empty()..characterId = 'alice';
      expect(c.isGroup, isFalse);
      expect(c.memberIds, ['alice']);
      expect(c.toJson().containsKey('participantIds'), isFalse);
    });

    test('ChatMessage speaker round-trips and is absent when unset', () {
      final tagged = ChatMessage(
          role: 'assistant', content: 'hi', speakerId: 'bob', speakerName: 'Bob');
      final back = ChatMessage.fromJson(tagged.toJson());
      expect(back.speakerId, 'bob');
      expect(back.speakerName, 'Bob');

      final plain = ChatMessage(role: 'assistant', content: 'hi');
      expect(plain.toJson().containsKey('speakerId'), isFalse);
      expect(plain.toJson().containsKey('speakerName'), isFalse);
    });

    test('speaker survives swipe operations', () {
      final m = ChatMessage(role: 'assistant', content: 'a', speakerId: 'bob')
          .addSwipe(const MessageVariant(content: 'b'));
      expect(m.speakerId, 'bob');
      expect(m.withSwipe(0).speakerId, 'bob');
    });

    test('ChatInterface group fields round-trip', () {
      const ui = ChatInterface(
        groupChatsEnabled: true,
        groupBarHeight: 96,
        groupBarColor: 0xFF112233,
        groupBarImage: 'local:pic.png',
      );
      final back = ChatInterface.fromJson(ui.toJson());
      expect(back.groupChatsEnabled, isTrue);
      expect(back.groupBarHeight, 96);
      expect(back.groupBarColor, 0xFF112233);
      expect(back.groupBarImage, 'local:pic.png');
      expect(back, ui);
    });

    test('groupResponder round-trips (a member, random, and unset)', () {
      Conversation base() => Conversation.empty()
        ..characterId = 'alice'
        ..participantIds.addAll(['alice', 'bob']);

      final named = base()..groupResponder = 'bob';
      expect(Conversation.fromJson(named.toJson()).groupResponder, 'bob');

      final random = base()..groupResponder = kGroupResponderRandom;
      expect(Conversation.fromJson(random.toJson()).groupResponder,
          kGroupResponderRandom);

      // Unset is the default and stays out of the JSON entirely.
      final manual = base();
      expect(manual.toJson().containsKey('groupResponder'), isFalse);
      expect(Conversation.fromJson(manual.toJson()).groupResponder, isNull);
    });

    test('copyAs carries the group responder (fork/renumber keep it)', () {
      final c = Conversation.empty()
        ..characterId = 'alice'
        ..participantIds.addAll(['alice', 'bob'])
        ..groupResponder = 'bob';
      expect(c.copyAs(id: 'x').groupResponder, 'bob');
    });
  });
  // APPEND-GROUP-TESTS

  group('AppState group logic', () {
    Future<AppState> grouped() async {
      final (state, _) = await _state();
      await state.addCharacter(_alice());
      await state.addCharacter(_bob());
      await state.addCharacter(_cara());
      state.startChatWithCharacter(_alice());
      await state.addParticipant(state.active.id, _bob());
      return state;
    }

    test('adding a second character makes it a group, primary kept first',
        () async {
      final state = await grouped();
      expect(state.active.isGroup, isTrue);
      expect(state.active.participantIds, ['alice', 'bob']);
      expect(state.active.characterId, 'alice');
    });

    test('removing back to one collapses to a one-to-one thread', () async {
      final state = await grouped();
      await state.removeParticipant(state.active.id, 'bob');
      expect(state.active.isGroup, isFalse);
      expect(state.active.participantIds, isEmpty);
      expect(state.active.characterId, 'alice');
    });

    test('a plain send in a group adds no automatic reply', () async {
      final (state, client) = await _state();
      await state.addCharacter(_alice());
      await state.addCharacter(_bob());
      state.startChatWithCharacter(_alice());
      await state.addParticipant(state.active.id, _bob());

      final before = state.active.messages.length;
      await state.send('hello everyone');
      // Only the user's turn lands; nobody speaks until a chip (or an
      // auto-responder) picks them.
      expect(state.active.messages.length, before + 1);
      expect(state.active.messages.last.isUser, isTrue);
      expect(client.lastHistory, isNull); // never generated
    });

    test('a chosen member auto-replies to every send', () async {
      final (state, client) = await _state();
      await state.addCharacter(_alice());
      await state.addCharacter(_bob());
      state.startChatWithCharacter(_alice());
      await state.addParticipant(state.active.id, _bob());

      // Pick Bob as the auto-responder, then send twice: Bob answers both.
      await state.toggleGroupResponder(state.active.id, 'bob');
      await state.send('one');
      expect(state.active.messages.last.speakerId, 'bob');
      await state.send('two');
      expect(state.active.messages.last.speakerId, 'bob');
      expect(_dump(client.lastHistory), contains('Write the next reply as Bob only'));
    });

    test('a random responder picks a current member each send', () async {
      final (state, _) = await _state();
      await state.addCharacter(_alice());
      await state.addCharacter(_bob());
      state.startChatWithCharacter(_alice());
      await state.addParticipant(state.active.id, _bob());

      await state.toggleGroupResponder(state.active.id, kGroupResponderRandom);
      await state.send('anyone?');
      final speaker = state.active.messages.last.speakerId;
      expect(speaker, isNotNull);
      expect(['alice', 'bob'], contains(speaker));
    });

    test('toggleGroupResponder sets, then clears when tapped again', () async {
      final (state, _) = await _state();
      await state.addCharacter(_alice());
      await state.addCharacter(_bob());
      state.startChatWithCharacter(_alice());
      await state.addParticipant(state.active.id, _bob());

      await state.toggleGroupResponder(state.active.id, 'bob');
      expect(state.active.groupResponder, 'bob');
      // Tapping the same choice again returns the thread to manual.
      await state.toggleGroupResponder(state.active.id, 'bob');
      expect(state.active.groupResponder, isNull);
    });

    test('removing the chosen responder drops back to manual', () async {
      final (state, _) = await _state();
      await state.addCharacter(_alice());
      await state.addCharacter(_bob());
      await state.addCharacter(_cara());
      state.startChatWithCharacter(_alice());
      await state.addParticipant(state.active.id, _bob());
      await state.addParticipant(state.active.id, _cara());

      await state.toggleGroupResponder(state.active.id, 'bob');
      await state.removeParticipant(state.active.id, 'bob');
      // Bob is gone; the thread must not silently answer as someone else.
      expect(state.active.groupResponder, isNull);
    });

    test('nextSpeaker still round-robins over the participant order', () async {
      final state = await grouped();
      await state.addParticipant(state.active.id, _cara());
      // No member has spoken (only the greeting): the first is up.
      expect(state.nextSpeaker(state.active)?.id, 'alice');
      // Alice speaks (a chip tap), so Bob is next; then Cara.
      await state.speakAs('alice');
      expect(state.nextSpeaker(state.active)?.id, 'bob');
      await state.speakAs('bob');
      expect(state.nextSpeaker(state.active)?.id, 'cara');
    });

    test('only the responder\'s full card is sent; others are summarised',
        () async {
      final (state, client) = await _state();
      await state.addCharacter(_alice());
      await state.addCharacter(_bob());
      state.startChatWithCharacter(_alice());
      await state.addParticipant(state.active.id, _bob());

      await state.speakAs('alice'); // Alice replies.
      final text = _dump(client.lastHistory);
      expect(text, contains('A curious explorer')); // Alice's own card
      expect(text, contains('Write the next reply as Alice only'));
      expect(text, contains('Other characters present'));
      expect(text, contains('Bob')); // Bob summarised in the roster
    });

    test('the responding member owns the generated turn', () async {
      final (state, client) = await _state();
      await state.addCharacter(_alice());
      await state.addCharacter(_bob());
      state.startChatWithCharacter(_alice());
      await state.addParticipant(state.active.id, _bob());

      await state.speakAs('bob');
      final last = state.active.messages.last;
      expect(last.speakerId, 'bob');
      expect(last.speakerName, 'Bob');
      final text = _dump(client.lastHistory);
      expect(text, contains('Write the next reply as Bob only'));
    });

    test('speakAs makes the named member reply without a new user turn',
        () async {
      final (state, client) = await _state();
      await state.addCharacter(_alice());
      await state.addCharacter(_bob());
      state.startChatWithCharacter(_alice());
      await state.addParticipant(state.active.id, _bob());

      final before = state.active.messages.length;
      await state.speakAs('bob');
      final msgs = state.active.messages;
      // Exactly one turn was added (the reply), and it is Bob's.
      expect(msgs.length, before + 1);
      expect(msgs.last.speakerId, 'bob');
      expect(_dump(client.lastHistory), contains('Write the next reply as Bob only'));
    });
  });

  group('group chat portability', () {
    ChatMessage said(String role, String content, {String? id, String? name}) =>
        ChatMessage(role: role, content: content, speakerId: id, speakerName: name);

    Conversation groupThread() => Conversation(
          id: 'g1',
          title: 'Tavern',
          updatedAt: DateTime.utc(2026, 1, 1),
          characterId: 'alice',
          characterName: 'Alice',
          participantIds: const ['alice', 'bob'],
          messages: [
            said('user', 'hello'),
            said('assistant', 'Ahoy.', id: 'bob', name: 'Bob'),
            said('assistant', 'Hi there.', id: 'alice', name: 'Alice'),
          ],
        );

    test('SillyTavern export attributes each turn to its speaker', () {
      final jsonl = ChatCodec.exportSillyTavern(groupThread(),
          characterName: 'Alice', userName: 'You');
      // The header, then a Bob line and an Alice line.
      expect(jsonl, contains('"name":"Bob"'));
      expect(jsonl, contains('"name":"Alice"'));
    });

    test('native export round-trips a group in full', () {
      final text = ChatCodec.exportNative(groupThread());
      final back = ChatCodec.parse(text, fileName: 'g.json').single.conversation;
      expect(back.participantIds, ['alice', 'bob']);
      final bobs =
          back.messages.where((m) => m.speakerId == 'bob').toList();
      expect(bobs, isNotEmpty);
      expect(bobs.first.speakerName, 'Bob');
    });

    test('a multi-speaker jsonl imports as a reconstructed group', () {
      final jsonl = [
        '{"user_name":"You","character_name":"Alice"}',
        '{"name":"You","is_user":true,"mes":"hello"}',
        '{"name":"Bob","is_user":false,"mes":"Ahoy."}',
        '{"name":"Alice","is_user":false,"mes":"Hi there."}',
      ].join('\n');
      final chat = ChatCodec.parse(jsonl, fileName: 'g.jsonl').single.conversation;
      expect(chat.isGroup, isTrue);
      expect(chat.participantIds.length, 2);
      // Each AI turn keeps its speaker so a re-export stays attributable.
      final speakers =
          chat.messages.where((m) => !m.isUser).map((m) => m.speakerName).toSet();
      expect(speakers, containsAll(<String>['Bob', 'Alice']));
    });
  });
}