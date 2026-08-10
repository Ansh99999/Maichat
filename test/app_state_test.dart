import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/settings.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stands in for a live endpoint: replays [deltas], or fails on demand.
class FakeClient extends ChatClient {
  FakeClient({this.deltas = const <String>[], this.failure});

  final List<String> deltas;
  final String? failure;
  List<ChatMessage>? lastHistory;

  @override
  Stream<String> streamChat({
    required AppSettings settings,
    required List<ChatMessage> history,
  }) async* {
    lastHistory = List<ChatMessage>.from(history);
    if (failure != null) throw ChatApiException(failure!);
    for (final delta in deltas) {
      yield delta;
    }
  }

  @override
  Future<List<String>> listModels(AppSettings settings) async => ['b', 'a'];
}

Future<AppState> _state(FakeClient client) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final state = AppState(client: client);
  await state.init();
  await state.updateSettings(
    const AppSettings(baseUrl: 'https://host.tld/v1', model: 'm'),
  );
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

    expect(client.lastHistory, hasLength(1));
    expect(client.lastHistory!.single.role, 'user');
    expect(client.lastHistory!.single.content, 'first');
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

  test('errored turns are not resent as context', () async {
    final client = FakeClient(failure: 'boom');
    final state = await _state(client);
    await state.send('one');

    final second = FakeClient(deltas: ['fine']);
    final resumed = AppState(client: second);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await resumed.init();
    await resumed.updateSettings(state.settings);
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

  test('conversations reload from storage', () async {
    final state = await _state(FakeClient(deltas: ['saved']));
    await state.send('persist me');

    final reopened = AppState(client: FakeClient());
    await reopened.init();

    expect(reopened.conversations, hasLength(1));
    expect(reopened.active.messages.last.content, 'saved');
    expect(reopened.settings.model, 'm');
  });
}
