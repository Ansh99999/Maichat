import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/image_gen.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/services/image_client.dart';

/// The image studio's client against a loopback server: what it *sends* for each
/// dialect, and what it makes of what comes back.
///
/// Both APIs are asserted on the actual request, for the same reason the chat
/// wire tests are: an images request that goes to the right host under the wrong
/// key or the wrong path fails in a way that reads, on a phone, exactly like a
/// broken feature.
void main() {
  late HttpServer server;

  /// A real 1x1 PNG, so the bytes that come back are a picture.
  final png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA'
      'DUlEQVR42mP8z8DAwAAABQABg1z0GwAAAABJRU5ErkJggg==');

  String? path;
  String? contentType;
  Map<String, String> headers = <String, String>{};
  String body = '';
  List<int> raw = const <int>[];
  late String Function() reply;
  int status = 200;

  setUp(() async {
    path = null;
    contentType = null;
    headers = <String, String>{};
    body = '';
    raw = const <int>[];
    status = 200;
    reply = () => jsonEncode({
          'data': [
            {'b64_json': base64Encode(png)}
          ],
        });
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      path = request.uri.path;
      contentType = request.headers.contentType?.mimeType;
      request.headers.forEach((name, values) => headers[name] = values.first);
      if (request.method == 'POST') {
        raw = await request
            .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
        body = utf8.decode(raw, allowMalformed: true);
      }
      // A GET is the picture being downloaded from a link the host handed back.
      if (request.method == 'GET') {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(png);
        await request.response.close();
        return;
      }
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType('application', 'json');
      request.response.write(reply());
      await request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  ImageGenConfig config({
    ImageGenKind kind = ImageGenKind.openai,
    String model = 'gpt-image-1',
    String size = 'auto',
    String quality = '',
    int count = 1,
    String systemPrompt = '',
  }) =>
      ImageGenConfig(
        kind: kind,
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        apiKey: 'k',
        model: model,
        size: size,
        quality: quality,
        count: count,
        systemPrompt: systemPrompt,
      );

  group('OpenAI images', () {
    test('a plain generation posts to /images/generations', () async {
      final result = await ImageClient().generate(
        config: config(size: '1024x1024', quality: 'high', count: 2),
        prompt: 'a lighthouse at dusk',
      );

      expect(path, '/v1/images/generations');
      expect(headers['authorization'], 'Bearer k');
      final sent = jsonDecode(body) as Map<String, dynamic>;
      expect(sent['model'], 'gpt-image-1');
      expect(sent['prompt'], 'a lighthouse at dusk');
      expect(sent['size'], '1024x1024');
      expect(sent['quality'], 'high');
      expect(sent['n'], 2);
      expect(result.images.single, png);
    });

    test('"auto" and an unset quality send nothing at all — a host that does '
        'not know the field would reject it', () async {
      await ImageClient().generate(config: config(), prompt: 'anything');
      final sent = jsonDecode(body) as Map<String, dynamic>;
      expect(sent.containsKey('size'), isFalse);
      expect(sent.containsKey('quality'), isFalse);
      expect(sent.containsKey('n'), isFalse);
    });

    test('a link-only reply is downloaded, because a link is not a picture',
        () async {
      reply = () => jsonEncode({
            'data': [
              {'url': 'http://127.0.0.1:${server.port}/picture.png'}
            ],
          });
      final result =
          await ImageClient().generate(config: config(), prompt: 'a fox');
      expect(result.images.single, png);
    });

    test('reference pictures switch to the multipart /images/edits path',
        () async {
      // There is no JSON form of the edits endpoint, so this is the one request
      // in the app that is not JSON.
      final result = await ImageClient().generate(
        config: config(),
        prompt: 'put a hat on it',
        references: [ImageReference(bytes: Uint8List.fromList(png))],
      );

      expect(path, '/v1/images/edits');
      expect(contentType, 'multipart/form-data');
      expect(body, contains('name="prompt"'));
      expect(body, contains('put a hat on it'));
      expect(body, contains('name="image[]"'));
      expect(result.images.single, png);
    });

    test('a rejected key is reported in the app\'s own words', () async {
      status = 401;
      reply = () => jsonEncode({'error': {'message': 'bad key'}});
      await expectLater(
        ImageClient().generate(config: config(), prompt: 'x'),
        throwsA(isA<ChatApiException>().having(
          (e) => e.message,
          'message',
          allOf(contains('HTTP 401'), contains('bad key')),
        )),
      );
    });

    test('an answer with no pictures in it says so', () async {
      reply = () => jsonEncode({'data': <Object>[]});
      await expectLater(
        ImageClient().generate(config: config(), prompt: 'x'),
        throwsA(isA<ChatApiException>()
            .having((e) => e.message, 'message', contains('no pictures'))),
      );
    });
  });

  group('Gemini', () {
    ImageGenConfig gemini({String systemPrompt = ''}) => config(
          kind: ImageGenKind.gemini,
          model: 'gemini-2.5-flash-image',
          systemPrompt: systemPrompt,
        );

    test('posts generateContent asking for an image modality', () async {
      reply = () => jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'Here you go.'},
                    {
                      'inlineData': {
                        'mimeType': 'image/png',
                        'data': base64Encode(png),
                      },
                    },
                  ],
                },
              },
            ],
          });
      final result = await ImageClient().generate(
        config: gemini(systemPrompt: 'watercolour, muted'),
        prompt: 'a harbour',
      );

      expect(path, '/v1/models/gemini-2.5-flash-image:generateContent');
      expect(headers['x-goog-api-key'], 'k');
      final sent = jsonDecode(body) as Map<String, dynamic>;
      expect(
        (sent['generationConfig'] as Map)['responseModalities'],
        containsAll(<String>['TEXT', 'IMAGE']),
      );
      expect(
        (((sent['systemInstruction'] as Map)['parts'] as List).first
            as Map)['text'],
        'watercolour, muted',
      );
      expect(result.images.single, png);
      expect(result.text, contains('Here you go.'));
    });

    test('a reference picture rides inline in the same parts array', () async {
      reply = () => jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {
                      'inlineData': {
                        'mimeType': 'image/png',
                        'data': base64Encode(png),
                      },
                    },
                  ],
                },
              },
            ],
          });
      await ImageClient().generate(
        config: gemini(),
        prompt: 'again but at night',
        references: [
          ImageReference(bytes: Uint8List.fromList(png), mime: 'image/png'),
        ],
      );

      final sent = jsonDecode(body) as Map<String, dynamic>;
      final parts =
          ((sent['contents'] as List).first as Map)['parts'] as List;
      expect((parts.first as Map)['text'], 'again but at night');
      expect(((parts.last as Map)['inlineData'] as Map)['data'],
          base64Encode(png));
    });

    test('a refusal arrives as text with no picture, and is passed on', () async {
      // Worth showing: "nothing came back" is the least useful thing the studio
      // could say when the model explained itself.
      reply = () => jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'I cannot draw that.'}
                  ],
                },
              },
            ],
          });
      await expectLater(
        ImageClient().generate(config: gemini(), prompt: 'x'),
        throwsA(isA<ChatApiException>()
            .having((e) => e.message, 'message', contains('I cannot draw that'))),
      );
    });

    test('an Imagen-style predictions reply is read too', () async {
      reply = () => jsonEncode({
            'predictions': [
              {'bytesBase64Encoded': base64Encode(png)}
            ],
          });
      final result =
          await ImageClient().generate(config: gemini(), prompt: 'a kite');
      expect(result.images.single, png);
    });
  });

  group('refusing to send a request that cannot work', () {
    test('an empty prompt and a missing model are refused before the network',
        () async {
      await expectLater(
        ImageClient().generate(config: config(), prompt: '   '),
        throwsA(isA<ChatApiException>()),
      );
      await expectLater(
        ImageClient().generate(config: config(model: ''), prompt: 'x'),
        throwsA(isA<ChatApiException>()),
      );
      expect(path, isNull, reason: 'nothing should have been sent');
    });
  });

  group('what a request will go to', () {
    test('the studio can show the exact URL for either dialect', () {
      expect(
        ImageClient.uriFor(config()).toString(),
        endsWith('/v1/images/generations'),
      );
      expect(
        ImageClient.uriFor(config(), edit: true).toString(),
        endsWith('/v1/images/edits'),
      );
      expect(
        ImageClient.uriFor(config(kind: ImageGenKind.gemini, model: 'm b'))
            .toString(),
        endsWith('/v1/models/m%20b:generateContent'),
      );
    });

    test('an empty endpoint falls back to the dialect\'s own root', () {
      const bare = ImageGenConfig(model: 'gpt-image-1');
      expect(bare.resolvedBaseUrl, ImageGenKind.openai.defaultBaseUrl);
      expect(bare.isReady, isTrue);
    });
  });

  group('the composed prompt', () {
    test('wraps the standing instructions and the avoid list around it', () {
      const cfg = ImageGenConfig(
        model: 'm',
        systemPrompt: 'watercolour',
        negativePrompt: 'text, logos',
      );
      expect(cfg.composePrompt('a harbour'),
          'watercolour\n\na harbour\n\nAvoid: text, logos');
      // Nothing set: the prompt is sent exactly as typed.
      expect(const ImageGenConfig(model: 'm').composePrompt('a harbour'),
          'a harbour');
    });

    test('the config round-trips through JSON', () {
      const cfg = ImageGenConfig(
        kind: ImageGenKind.gemini,
        baseUrl: 'https://host.tld/v1beta',
        apiKey: 'k',
        model: 'm',
        size: '512x512',
        quality: 'low',
        count: 3,
        systemPrompt: 's',
        negativePrompt: 'n',
      );
      final back = ImageGenConfig.fromJson(cfg.toJson());
      expect(back.kind, ImageGenKind.gemini);
      expect(back.baseUrl, 'https://host.tld/v1beta');
      expect(back.model, 'm');
      expect(back.size, '512x512');
      expect(back.quality, 'low');
      expect(back.count, 3);
      expect(back.systemPrompt, 's');
      expect(back.negativePrompt, 'n');
      // An untouched config writes almost nothing.
      expect(const ImageGenConfig().toJson().keys, ['kind']);
    });
  });
}
