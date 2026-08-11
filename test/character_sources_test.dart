import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/services/character_sources.dart';

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
}
