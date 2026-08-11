import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/services/character_codec.dart';

/// Builds a minimal PNG (signature + one `tEXt` chunk + `IEND`) carrying
/// [charaText] under the `chara` keyword, mirroring how SillyTavern embeds a
/// card. CRCs are left zero — the reader skips them.
Uint8List _pngWithChara(String charaText) {
  final out = BytesBuilder();
  out.add(const [137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> data) {
    final len = ByteData(4)..setUint32(0, data.length);
    out.add(len.buffer.asUint8List());
    out.add(ascii.encode(type));
    out.add(data);
    out.add(const [0, 0, 0, 0]); // fake CRC
  }

  chunk('tEXt', [...ascii.encode('chara'), 0, ...ascii.encode(charaText)]);
  chunk('IEND', const []);
  return out.toBytes();
}

void main() {
  test('parses a SillyTavern v2 card (spec + data)', () {
    final card = {
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': {
        'name': 'Aria',
        'description': 'A calm librarian.',
        'personality': 'gentle',
        'scenario': 'the library at dusk',
        'first_mes': 'Hello, {{user}}.',
        'mes_example': '<START>',
        'system_prompt': 'Be concise.',
        'alternate_greetings': ['Hi again.'],
        'tags': ['sfw', 'oc'],
        'creator': 'someone',
        'character_version': '1.1',
      },
    };
    final c = CharacterCodec.parseJson(jsonEncode(card));
    expect(c.name, 'Aria');
    expect(c.format, CharacterFormat.tavernV2);
    expect(c.description, 'A calm librarian.');
    expect(c.firstMes, 'Hello, {{user}}.');
    expect(c.systemPrompt, 'Be concise.');
    expect(c.alternateGreetings, ['Hi again.']);
    expect(c.tags, ['sfw', 'oc']);
    expect(c.characterVersion, '1.1');
  });

  test('parses a flat v1 card', () {
    final card = {
      'name': 'Bo',
      'description': 'desc',
      'personality': 'grumpy',
      'scenario': 'a tavern',
      'first_mes': 'Yo.',
      'mes_example': 'ex',
    };
    final c = CharacterCodec.parseJson(jsonEncode(card));
    expect(c.name, 'Bo');
    expect(c.format, CharacterFormat.tavernV1);
    expect(c.firstMes, 'Yo.');
    expect(c.mesExample, 'ex');
  });

  test('parses a v3 card as tavernV3', () {
    final card = {
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {'name': 'Cee', 'first_mes': 'hi'},
    };
    final c = CharacterCodec.parseJson(jsonEncode(card));
    expect(c.format, CharacterFormat.tavernV3);
    expect(c.name, 'Cee');
  });

  test('parses an Agnai export, flattening a text persona', () {
    final card = {
      'name': 'Del',
      'description': 'author blurb',
      'persona': {
        'kind': 'text',
        'attributes': {
          'text': ['likes tea', 'hates noise'],
        },
      },
      'scenario': 'a cafe',
      'greeting': 'Welcome!',
      'sampleChat': 'sample',
    };
    final c = CharacterCodec.parseJson(jsonEncode(card));
    expect(c.format, CharacterFormat.agnai);
    expect(c.name, 'Del');
    expect(c.description, contains('likes tea'));
    expect(c.description, contains('hates noise'));
    expect(c.scenario, 'a cafe');
    expect(c.firstMes, 'Welcome!');
    expect(c.mesExample, 'sample');
    // Agnai's top-level description is the author blurb, not the persona.
    expect(c.creatorNotes, 'author blurb');
  });

  test('flattens an Agnai wpp/attribute persona into key: value lines', () {
    final card = {
      'name': 'Eve',
      'persona': {
        'kind': 'wpp',
        'attributes': {
          'species': ['android'],
          'mood': ['curious', 'warm'],
        },
      },
      'greeting': 'Hi',
    };
    final c = CharacterCodec.parseJson(jsonEncode(card));
    expect(c.description, contains('species: android'));
    expect(c.description, contains('mood: curious, warm'));
  });

  test('extracts a card embedded in a PNG tEXt chunk (base64)', () {
    final card = {
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': {'name': 'Pixel', 'first_mes': 'boop'},
    };
    final base64Card = base64.encode(utf8.encode(jsonEncode(card)));
    final png = _pngWithChara(base64Card);
    final c = CharacterCodec.parseBytes(png, filename: 'pixel.png');
    expect(c.name, 'Pixel');
    expect(c.firstMes, 'boop');
    expect(c.format, CharacterFormat.tavernV2);
  });

  test("a PNG card's own image becomes the avatar", () {
    final card = {
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': {'name': 'Pixel'},
    };
    final base64Card = base64.encode(utf8.encode(jsonEncode(card)));
    final png = _pngWithChara(base64Card);
    final c = CharacterCodec.parseBytes(png);
    // No URL in the card, so the PNG bytes are kept as the portrait.
    expect(c.avatarIsUrl, isFalse);
    expect(c.avatarBytes, isNotNull);
    expect(base64.decode(c.avatar), png);
  });

  test('a PNG with no card chunk fails clearly', () {
    final png = Uint8List.fromList(const [137, 80, 78, 71, 13, 10, 26, 10]);
    expect(
      () => CharacterCodec.parseBytes(png),
      throwsA(isA<CharacterParseException>()),
    );
  });

  test('non-card JSON and junk are rejected', () {
    expect(() => CharacterCodec.parseJson('{}'),
        throwsA(isA<CharacterParseException>()));
    expect(() => CharacterCodec.parseJson('not json'),
        throwsA(isA<CharacterParseException>()));
  });

  test('export produces a v2 card that round-trips', () {
    final original = Character(
      id: 'x',
      name: 'Fern',
      description: 'a botanist',
      personality: 'patient',
      scenario: 'a greenhouse',
      firstMes: 'Mind the ferns.',
      mesExample: 'ex',
      systemPrompt: 'stay leafy',
      alternateGreetings: const ['Over here.'],
      tags: const ['nature'],
      creator: 'me',
      characterVersion: '2.0',
      format: CharacterFormat.manual,
    );
    final json = CharacterCodec.exportTavernV2(original);
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    expect(decoded['spec'], 'chara_card_v2');
    // Core fields mirrored at the top for v1 readers.
    expect(decoded['name'], 'Fern');

    final reparsed = CharacterCodec.parseJson(json);
    expect(reparsed.name, 'Fern');
    expect(reparsed.description, 'a botanist');
    expect(reparsed.firstMes, 'Mind the ferns.');
    expect(reparsed.systemPrompt, 'stay leafy');
    expect(reparsed.alternateGreetings, const ['Over here.']);
    expect(reparsed.tags, const ['nature']);
    expect(reparsed.format, CharacterFormat.tavernV2);
  });

  test('composed system prompt and greeting resolve macros', () {
    final c = Character(
      id: 'x',
      name: 'Nova',
      description: '{{char}} guards the gate.',
      firstMes: 'Halt, {{user}}!',
    );
    final prompt = c.composedSystemPrompt(userName: 'Sam');
    expect(prompt, contains('Nova'));
    expect(prompt, contains('Sam'));
    expect(prompt, isNot(contains('{{char}}')));
    expect(c.resolvedGreeting(userName: 'Sam'), 'Halt, Sam!');
  });
}
