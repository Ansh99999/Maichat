import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/services/chat_client.dart';

/// Testing a key has to send *that* key and nothing else, and has to tell a
/// refused credential apart from a host that was simply not there — those are
/// different problems with different fixes.
void main() {
  late HttpServer server;
  final seenAuth = <String?>[];

  Future<Provider> serve(
    int status,
    String body, {
    ProviderKind kind = ProviderKind.openai,
    List<String> keys = const <String>['sk-one'],
  }) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      seenAuth.add(request.headers.value('authorization') ??
          request.headers.value('x-api-key') ??
          request.headers.value('x-goog-api-key'));
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(body);
      await request.response.close();
    });
    return Provider(
      id: 'p',
      name: 'Test',
      kind: kind,
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      apiKeys: keys,
      model: 'test-model',
    );
  }

  setUp(seenAuth.clear);
  tearDown(() => server.close(force: true));

  test('a working key passes and says how many models it can reach', () async {
    final provider = await serve(
      200,
      jsonEncode({
        'data': [
          {'id': 'gpt-4o'},
          {'id': 'gpt-4o-mini'},
        ],
      }),
    );

    final result = await ChatClient().testKey(provider, 'sk-one');
    expect(result.ok, isTrue);
    expect(result.status, 200);
    expect(result.modelCount, 2);
    expect(result.message, contains('2 models'));
    expect(result.latency, isNotNull);
  });

  test('only the key under test is sent, never the rest of the pool', () async {
    final provider = await serve(
      200,
      jsonEncode({'data': <dynamic>[]}),
      keys: const <String>['sk-first', 'sk-second', 'sk-third'],
    );

    // Without narrowing, `apiKey` returns the first key and key 3 would appear to
    // work on key 1's authority.
    await ChatClient().testKey(provider, 'sk-third');
    expect(seenAuth.single, 'Bearer sk-third');
  });

  test('a refused key is reported as a key problem', () async {
    final provider = await serve(
      401,
      jsonEncode({
        'error': {'message': 'Incorrect API key provided'},
      }),
    );

    final result = await ChatClient().testKey(provider, 'sk-bad');
    expect(result.ok, isFalse);
    expect(result.status, 401);
    expect(result.isRejected, isTrue);
    expect(result.message.toLowerCase(), contains('api key'));
  });

  test('a wrong base URL is reported as a URL problem, not a key one', () async {
    final provider = await serve(404, jsonEncode({'error': 'nope'}));

    final result = await ChatClient().testKey(provider, 'sk-one');
    expect(result.ok, isFalse);
    expect(result.status, 404);
    expect(result.isRejected, isFalse);
    expect(result.message, contains('base URL'));
  });

  test('an empty key is refused without a request being made', () async {
    final provider = await serve(200, jsonEncode({'data': <dynamic>[]}));

    final result = await ChatClient().testKey(provider, '   ');
    expect(result.ok, isFalse);
    expect(seenAuth, isEmpty);
  });

  test('a host that authenticates but lists nothing still counts', () async {
    final provider = await serve(200, jsonEncode({'data': <dynamic>[]}));

    final result = await ChatClient().testKey(provider, 'sk-one');
    // Reachability is what was proven; the message says so rather than claiming
    // the key is good for models it never listed.
    expect(result.ok, isTrue);
    expect(result.message, contains('no models'));
  });

  test('an unreachable host is a transport failure, not a rejection', () async {
    // Bound then closed, so the port is dead but well-formed.
    final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = dead.port;
    await dead.close(force: true);
    final provider = Provider(
      id: 'p',
      name: 'Test',
      kind: ProviderKind.openai,
      baseUrl: 'http://127.0.0.1:$port/v1',
      apiKey: 'sk-one',
      model: 'test-model',
    );

    final result = await ChatClient().testKey(provider, 'sk-one');
    expect(result.ok, isFalse);
    expect(result.status, isNull);
    expect(result.isRejected, isFalse);

    // The tearDown expects a server; give it one it can close.
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  test('Anthropic keys go in x-api-key, not a bearer', () async {
    final provider = await serve(
      200,
      jsonEncode({'data': <dynamic>[]}),
      kind: ProviderKind.anthropic,
    );

    await ChatClient().testKey(provider, 'sk-ant-one');
    expect(seenAuth.single, 'sk-ant-one');
  });

  test('Gemini keys go in x-goog-api-key', () async {
    final provider = await serve(
      200,
      jsonEncode({'models': <dynamic>[]}),
      kind: ProviderKind.gemini,
    );

    await ChatClient().testKey(provider, 'AIza-one');
    expect(seenAuth.single, 'AIza-one');
  });
}
