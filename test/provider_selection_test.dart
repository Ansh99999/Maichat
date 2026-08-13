import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Captures the provider (and thus model) each request actually goes to.
class _CaptureClient extends ChatClient {
  Provider? last;

  @override
  Stream<String> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    last = provider;
    yield 'x';
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
    id: 'p1',
    name: 'p1',
    kind: ProviderKind.openai,
    baseUrl: 'https://a/v1',
    model: 'model-A',
    apiKey: 'k',
  ));
  return (state, client);
}

void main() {
  test('changing the active model changes what is sent', () async {
    final (state, client) = await _state();
    await state.send('hi');
    expect(client.last?.model, 'model-A');

    await state.setActiveModel('model-B');
    await state.send('again');
    expect(client.last?.model, 'model-B');
  });

  test('switching the active provider changes what is sent', () async {
    final (state, client) = await _state();
    await state.addProvider(Provider(
      id: 'p2',
      name: 'p2',
      kind: ProviderKind.anthropic,
      baseUrl: 'https://b',
      model: 'model-Z',
      apiKey: 'k',
    )); // becomes active
    await state.send('hi');
    expect(client.last?.model, 'model-Z');

    await state.selectProvider('p1');
    await state.send('again');
    expect(client.last?.model, 'model-A');
  });

  test('a preset model binding does NOT override the active model', () async {
    final (state, client) = await _state();
    final def = state.defaultPreset!;
    def.model = 'preset-model';
    await state.savePreset(def);

    await state.setActiveModel('model-B');
    await state.send('hi');
    // The picker wins; the stale preset binding must not "live on".
    expect(client.last?.model, 'model-B');
  });

  test('a preset model is used only as a fallback when the provider has none',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final client = _CaptureClient();
    final state = AppState(client: client);
    await state.init();
    // Active provider with NO model of its own.
    await state.addProvider(Provider(
      id: 'p1',
      name: 'p1',
      kind: ProviderKind.openai,
      baseUrl: 'https://a/v1',
      model: '',
      apiKey: 'k',
    ));
    final def = state.defaultPreset!;
    def.model = 'preset-fallback';
    await state.savePreset(def);

    await state.send('hi');
    expect(client.last?.model, 'preset-fallback');
  });
}
