import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/services/character_codec.dart';
import 'package:maichat/services/character_sources.dart';

Uint8List _pngWithChara(String charaText) {
  final out = BytesBuilder();
  out.add(const [137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> data) {
    final len = ByteData(4)..setUint32(0, data.length);
    out.add(len.buffer.asUint8List());
    out.add(ascii.encode(type));
    out.add(data);
    out.add(const [0, 0, 0, 0]);
  }

  chunk('tEXt', [...ascii.encode('chara'), 0, ...ascii.encode(charaText)]);
  chunk('IEND', const []);
  return out.toBytes();
}

void main() {
  test('extracts JannyAI id candidates (full slug + bare uuid) from a URL', () {
    final uri = Uri.parse(
      'https://jannyai.com/characters/'
      'ced8a7c6-67f2-46bf-b17c-06720bbfad33_character-how-we-look-at-bro',
    );
    final ids = UrlSource.jannyCharacterIds(uri);
    expect(
      ids,
      contains(
        'ced8a7c6-67f2-46bf-b17c-06720bbfad33_character-how-we-look-at-bro',
      ),
    );
    expect(ids, contains('ced8a7c6-67f2-46bf-b17c-06720bbfad33'));
  });

  test('returns no candidates for a URL without a character id', () {
    expect(UrlSource.jannyCharacterIds(Uri.parse('https://jannyai.com/')),
        isEmpty);
  });

  /// A RisuAI link used to be fetched as `png-v3` and nothing else, so a card
  /// built with assets — which refuses that format outright — looked like a
  /// broken link. The ladder is the fix, and these pin each rung.
  group('a RisuAI link', () {
    late HttpServer server;
    late String base;
    final requests = <String>[];
    late Map<String, Object> routes;

    setUp(() async {
      requests.clear();
      routes = <String, Object>{};
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://${server.address.host}:${server.port}';
      server.listen((request) async {
        requests.add('${request.uri}');
        Object? body;
        for (final entry in routes.entries) {
          if ('${request.uri}'.contains(entry.key)) {
            body = entry.value;
            break;
          }
        }
        if (body == null) {
          request.response.statusCode = 404;
          await request.response.close();
          return;
        }
        if (body is List<int>) {
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add(body);
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(body);
        }
        await request.response.close();
      });
    });

    tearDown(() async => server.close(force: true));

    String card(String name) => jsonEncode({
          'spec': 'chara_card_v3',
          'spec_version': '3.0',
          'data': {'name': name, 'description': 'd', 'first_mes': 'Hi.'},
        });

    test('takes the JSON card when the card allows it', () async {
      routes['download/json-v3'] = card('Kuzi');
      final payload = await UrlSource.fetchRisuCard('abc', apiBase: base);
      expect(CharacterCodec.parseBytes(payload.bytes).name, 'Kuzi');
      expect(requests.single, contains('json-v3'));
      expect(requests.single, contains('non_commercial=true'));
    });

    test('falls through to png when json is refused', () async {
      routes['download/json-v3'] = jsonEncode({
        'error': 'Bad Request',
        'message': 'Invalid response from server',
      });
      routes['download/png-v3'] =
          _pngWithChara(base64Encode(utf8.encode(card('From PNG'))));
      final payload = await UrlSource.fetchRisuCard('abc', apiBase: base);
      expect(CharacterCodec.parseBytes(payload.bytes).name, 'From PNG');
      expect(payload.filename, endsWith('.png'));
    });

    test('an asset card ends up as CharX', () async {
      routes['download/json-v3'] = jsonEncode({'error': 'Bad Request'});
      routes['download/png-v3'] = jsonEncode({
        'error': 'Forbidden',
        'message': 'This card is not allowed to be downloaded in this format.',
      });
      routes['download/charx-v3'] =
          _pngWithChara(base64Encode(utf8.encode(card('From CharX'))));
      final payload = await UrlSource.fetchRisuCard('abc', apiBase: base);
      expect(payload.filename, endsWith('.charx'));
      expect(requests.length, 3);
    });

    test("a card refused in every format reports Realm's own reason", () async {
      routes['download/'] = jsonEncode({
        'error': 'Forbidden',
        'message': 'This card is not allowed to be downloaded in this format.',
      });
      await expectLater(
        UrlSource.fetchRisuCard('abc', apiBase: base),
        throwsA(isA<CharacterParseException>().having(
          (e) => e.message,
          'message',
          contains('not allowed to be downloaded in this format'),
        )),
      );
    });
  });
}
