import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/message_image.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/services/avatar_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// End-to-end coverage of a *picture on the wire*: a real [AppState] driving the
/// real [ChatClient] over a loopback server, so these assertions are on the JSON
/// that actually leaves the app.
///
/// Every dialect carries an attachment differently and there is no shared shape
/// to fall back on, so each one is asserted separately. A picture that assembles
/// perfectly and then goes out under the wrong key is indistinguishable, to the
/// user, from a model that cannot see.
///
/// The server answers 200 and closes without sending an event: the reply is not
/// what is under test, and an empty stream ends the send cleanly.
void main() {
  late HttpServer server;
  late Directory dir;
  Map<String, dynamic>? captured;

  /// A real 1x1 PNG, so what is written is a picture a decoder would accept.
  final png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA'
      'DUlEQVR42mP8z8DAwAAABQABg1z0GwAAAABJRU5ErkJggg==');

  Uint8List picture(int seed) =>
      Uint8List.fromList([...png, ...List<int>.filled(4, seed)]);

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = Directory.systemTemp.createTempSync('wire-images');
    captured = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.method == 'POST') {
        captured = jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
      }
      request.response.headers.contentType =
          ContentType('text', 'event-stream');
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    dir.deleteSync(recursive: true);
    avatarDirectory = null;
  });

  Future<AppState> boot(ProviderKind kind) async {
    final state = AppState(avatars: AvatarStore(dir));
    await state.init();
    await state.addProvider(Provider(
      id: 'p',
      name: 'local',
      kind: kind,
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      model: 'test-model',
      apiKey: 'k',
    ));
    return state;
  }

  /// Files a picture and returns what a message should carry for it.
  Future<MessageImage> attach(AppState state, [int seed = 1]) async {
    final image = await state.storeAttachment(picture(seed));
    expect(image, isNotNull, reason: 'the picture must have become a file');
    return image!;
  }

  /// Everything the request said, as one string — for "is the base64 in there at
  /// all" questions, where *where* it is is asserted separately.
  String whole() => jsonEncode(captured);

  test('the OpenAI chat dialect sends a data URL beside the text', () async {
    final state = await boot(ProviderKind.openai);
    await state.send('what is this?', images: [await attach(state)]);

    final messages = (captured!['messages'] as List).cast<Map<String, dynamic>>();
    final user = messages.lastWhere((m) => m['role'] == 'user');
    final content = user['content'] as List;
    expect(content.any((p) => (p as Map)['type'] == 'text'), isTrue);
    final image = content.firstWhere((p) => (p as Map)['type'] == 'image_url');
    final url = ((image as Map)['image_url'] as Map)['url'] as String;
    expect(url, startsWith('data:image/png;base64,'));
    expect(base64Decode(url.split(',').last), picture(1));
  });

  test('Anthropic sends a base64 image block ahead of the text', () async {
    final state = await boot(ProviderKind.anthropic);
    await state.send('what is this?', images: [await attach(state)]);

    final messages = (captured!['messages'] as List).cast<Map<String, dynamic>>();
    final user = messages.lastWhere((m) => m['role'] == 'user');
    final content = user['content'] as List;
    final first = content.first as Map;
    expect(first['type'], 'image',
        reason: 'Anthropic reads a question better after the picture');
    final source = first['source'] as Map;
    expect(source['type'], 'base64');
    expect(source['media_type'], 'image/png');
    expect(base64Decode(source['data'] as String), picture(1));
    expect((content.last as Map)['type'], 'text');
  });

  test('Gemini sends inlineData in the same parts array as the text', () async {
    final state = await boot(ProviderKind.gemini);
    await state.send('what is this?', images: [await attach(state)]);

    final contents = (captured!['contents'] as List).cast<Map<String, dynamic>>();
    final parts = (contents.last['parts'] as List).cast<Map<String, dynamic>>();
    expect(parts.first['text'], isA<String>());
    final inline = parts.last['inlineData'] as Map;
    expect(inline['mimeType'], 'image/png');
    expect(base64Decode(inline['data'] as String), picture(1));
  });

  test('the Responses API sends a flat input_image part', () async {
    final state = await boot(ProviderKind.openaiResponses);
    await state.send('what is this?', images: [await attach(state)]);

    final input = (captured!['input'] as List).cast<Map<String, dynamic>>();
    final content = (input.last['content'] as List).cast<Map<String, dynamic>>();
    expect(content.first['type'], 'input_text');
    final image = content.last;
    expect(image['type'], 'input_image');
    expect(image['image_url'] as String, startsWith('data:image/png;base64,'));
  });

  test('a picture sent earlier still rides along on later turns — the model '
      'is meant to remember it', () async {
    final state = await boot(ProviderKind.openai);
    await state.send('look at this', images: [await attach(state)]);
    await state.send('so what was it?');

    // Two user turns went out; the picture is still on the first of them.
    final messages = (captured!['messages'] as List).cast<Map<String, dynamic>>();
    final withPicture = messages.where(
      (m) => m['content'] is List &&
          (m['content'] as List).any((p) => (p as Map)['type'] == 'image_url'),
    );
    expect(withPicture, hasLength(1));
    expect(whole(), contains('so what was it?'));
  });

  test('a picture whose file has gone is dropped, not sent empty', () async {
    final state = await boot(ProviderKind.openai);
    await state.send('gone', images: const [MessageImage(ref: 'local:missing.png')]);

    final messages = (captured!['messages'] as List).cast<Map<String, dynamic>>();
    final user = messages.lastWhere((m) => m['role'] == 'user');
    // Back to a plain string: the words survive, the attachment does not.
    expect(user['content'], isA<String>());
    expect(whole(), isNot(contains('image_url')));
  });

  test('a request carries at most the newest few pictures', () async {
    // No size limit on a picture anywhere in the app — but ten photographs
    // re-uploaded on every turn for the rest of a chat is a request nobody can
    // send, so the count is capped and the recent ones win.
    final state = await boot(ProviderKind.openai);
    for (var i = 0; i < AppState.kMaxWireImages + 2; i++) {
      await state.send('turn $i', images: [await attach(state, i)]);
    }

    final messages = (captured!['messages'] as List).cast<Map<String, dynamic>>();
    var pictures = 0;
    for (final m in messages) {
      final content = m['content'];
      if (content is! List) continue;
      pictures += content
          .where((p) => (p as Map)['type'] == 'image_url')
          .length;
    }
    expect(pictures, AppState.kMaxWireImages);
    // The oldest picture is the one that was dropped.
    expect(whole(), isNot(contains(base64Encode(picture(0)))));
    expect(whole(), contains(base64Encode(picture(AppState.kMaxWireImages + 1))));
  });

  test('the copyable request preview elides the base64', () async {
    // The preview ends up on clipboards and in bug reports; a megabyte of base64
    // makes it useless, and the rest of the payload is the point of it.
    final state = await boot(ProviderKind.openai);
    await state.send('look', images: [await attach(state)]);

    final conversation = state.active;
    final assembled =
        state.assemblePromptForMessage(conversation, 0);
    final preview = state.requestPreview(assembled)!;
    expect(preview, contains('elided'));
    expect(preview, isNot(contains(base64Encode(picture(1)))));
    expect(preview, contains('image_url'),
        reason: 'the shape must still be visible, only the payload elided');
  });
}
