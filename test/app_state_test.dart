import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stands in for a live endpoint: replays [deltas], or fails on demand.
class FakeClient extends ChatClient {
  FakeClient({this.deltas = const <String>[], this.failure});

  final List<String> deltas;
  final String? failure;
  List<ChatMessage>? lastHistory;
  Provider? lastProvider;

  @override
  Stream<String> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    lastProvider = provider;
    lastHistory = List<ChatMessage>.from(history);
    if (failure != null) throw ChatApiException(failure!);
    for (final delta in deltas) {
      yield delta;
    }
  }

  @override
  Future<List<String>> listModels(Provider provider) async => ['b', 'a'];
}

Provider _provider({String id = 'p', String model = 'm'}) => Provider(
      id: id,
      name: 'Test',
      kind: ProviderKind.openai,
      baseUrl: 'https://host.tld/v1',
      apiKey: '',
      model: model,
    );

Future<AppState> _state(FakeClient client) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final state = AppState(client: client);
  await state.init();
  await state.addProvider(_provider());
  return state;
}

void main() {
  test('streamed deltas land in one assistant turn', () async {
    final state = await _state(FakeClient(deltas: ['Hel', 'lo ', 'there']));

    await state.send('hi');

    expect(state.streaming, isFalse);
    expect(state.active.messages.length, 2);
    expect(state.active.messages[0].content, 'hi');
    expect(state.active.messages[1].role, 'assistant');
    expect(state.active.messages[1].content, 'Hello there');
    expect(state.active.messages[1].error, isFalse);
  });

  test('the request history excludes the streaming placeholder', () async {
    final client = FakeClient(deltas: ['ok']);
    final state = await _state(client);

    await state.send('  first  ');

    // The default preset assembles the request; the user's turn is last and the
    // empty assistant placeholder is never sent.
    final history = client.lastHistory!;
    expect(history.last.role, 'user');
    expect(history.last.content, 'first');
    expect(history.every((m) => m.content.isNotEmpty), isTrue);
    expect(client.lastProvider!.model, 'm');
    expect(state.active.title, 'first');
  });

  test('a failure replaces the placeholder with an error turn', () async {
    final state = await _state(FakeClient(failure: 'check your API key'));

    await state.send('hi');

    expect(state.streaming, isFalse);
    expect(state.active.messages.last.error, isTrue);
    expect(state.active.messages.last.content, 'check your API key');
  });

  test('an empty stream is reported rather than left blank', () async {
    final state = await _state(FakeClient());

    await state.send('hi');

    expect(state.active.messages.last.error, isTrue);
    expect(state.active.messages.last.content, contains('empty response'));
  });

  test('nothing is sent when no provider is configured', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final state = AppState(client: FakeClient(deltas: ['x']));
    await state.init();

    await state.send('hi');

    expect(state.isConfigured, isFalse);
    expect(state.conversations, isEmpty);
  });

  test('errored turns are not resent as context', () async {
    final client = FakeClient(failure: 'boom');
    final state = await _state(client);
    await state.send('one');

    final second = FakeClient(deltas: ['fine']);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final resumed = AppState(client: second);
    await resumed.init();
    await resumed.addProvider(_provider(id: 'p2'));
    resumed.active.messages.addAll(state.active.messages);
    await resumed.send('two');

    expect(
      second.lastHistory!.map((m) => m.content),
      containsAllInOrder(['one', 'two']),
    );
    expect(second.lastHistory!.any((m) => m.content == 'boom'), isFalse);
  });

  test('new chat reuses an existing empty thread', () async {
    final state = await _state(FakeClient(deltas: ['x']));

    state.newConversation();
    final firstId = state.active.id;
    state.newConversation();

    expect(state.active.id, firstId);
    expect(state.conversations, hasLength(1));
  });

  test('sending starts a second thread and orders newest first', () async {
    final state = await _state(FakeClient(deltas: ['x']));
    await state.send('older');
    state.newConversation();
    await state.send('newer');

    expect(state.conversations, hasLength(2));
    expect(state.conversations.first.title, 'newer');
    expect(state.conversations.last.title, 'older');
  });

  test('deleting the active thread falls back to another', () async {
    final state = await _state(FakeClient(deltas: ['x']));
    await state.send('older');
    state.newConversation();
    await state.send('newer');

    await state.deleteConversation(state.active.id);

    expect(state.conversations, hasLength(1));
    expect(state.active.title, 'older');
  });

  test('conversations and providers reload from storage', () async {
    final state = await _state(FakeClient(deltas: ['saved']));
    await state.send('persist me');

    final reopened = AppState(client: FakeClient());
    await reopened.init();

    expect(reopened.conversations, hasLength(1));
    expect(reopened.active.messages.last.content, 'saved');
    expect(reopened.activeProvider?.model, 'm');
  });

  test('providers can be added, selected, updated and deleted', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final state = AppState(client: FakeClient());
    await state.init();

    await state.addProvider(_provider(id: 'a', model: 'm1'));
    await state.addProvider(
      Provider(
        id: 'b',
        name: 'B',
        kind: ProviderKind.anthropic,
        baseUrl: 'https://b/v1',
        apiKey: '',
        model: 'm2',
      ),
    );

    // The most recently added becomes active.
    expect(state.providers, hasLength(2));
    expect(state.activeProvider?.id, 'b');

    await state.selectProvider('a');
    expect(state.activeProvider?.id, 'a');

    await state.setActiveModel('m1x');
    expect(state.activeProvider?.model, 'm1x');

    await state.updateProvider(state.activeProvider!.copyWith(name: 'A2'));
    expect(state.activeProvider?.name, 'A2');
    expect(state.activeProvider?.model, 'm1x');

    // Deleting the active provider reassigns the active pointer.
    await state.deleteProvider('a');
    expect(state.providers, hasLength(1));
    expect(state.activeProvider?.id, 'b');
  });

  test('a legacy settings blob migrates to one active provider', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.settings':
          '{"baseUrl":"https://host.tld/v1","apiKey":"sk","model":"m"}',
    });
    final state = AppState(client: FakeClient());
    await state.init();

    expect(state.providers, hasLength(1));
    final migrated = state.providers.single;
    expect(migrated.kind, ProviderKind.openai);
    expect(migrated.baseUrl, 'https://host.tld/v1');
    expect(migrated.apiKey, 'sk');
    expect(migrated.model, 'm');
    expect(state.activeProvider?.id, migrated.id);
    expect(state.isConfigured, isTrue);
  });
}
