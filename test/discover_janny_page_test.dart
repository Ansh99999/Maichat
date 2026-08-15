import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/services/discover/janny_page.dart';

/// JannyAI serves the definition as the props of an Astro island, HTML-escaped
/// into an attribute and wrapped in Astro's `[type, data]` envelope. This page
/// cannot be fetched from every machine (Cloudflare guards the front door), so
/// the parser is tested against a page built here — which is also the only way
/// to cover the shapes that break it.
void main() {
  /// Wraps [value] the way Astro serialises a plain prop.
  List<Object?> plain(Object? value) => <Object?>[0, value];

  /// Wraps a list the way Astro serialises an array prop.
  List<Object?> array(List<Object?> items) =>
      <Object?>[1, items.map(plain).toList()];

  Map<String, Object?> characterProps({
    String name = 'Aria',
    String personality = 'A ranger of the northern wood.',
    String firstMessage = 'You hear a bowstring draw.',
  }) =>
      <String, Object?>{
        'character': plain(<String, Object?>{
          'id': plain('uuid-1'),
          'name': plain(name),
          'personality': plain(personality),
          'scenario': plain('The wood at dusk.'),
          'firstMessage': plain(firstMessage),
          'exampleDialogs': plain('<START>\nAria: Quiet.'),
          'description': plain('<p>My first card, <b>be kind</b>.</p>'),
          'creatorId': plain('creator-uuid'),
          'tagIds': array(<Object?>[2, 53]),
        }),
        'imageUrl': plain('https://img.example/a.webp'),
      };

  String escape(Object? props) =>
      jsonEncode(props).replaceAll('&', '&amp;').replaceAll('"', '&quot;');

  /// A page shaped like JannyAI's, with [islandAttributes] controlling the tag.
  String page(
    Object? props, {
    String islandAttributes =
        'component-url="/_astro/CharacterButtons.abc.js" '
        'component-export="CharacterButtons"',
    bool withCreatorLine = true,
  }) =>
      '<!doctype html><html><head><title>Aria</title></head><body>'
      '${withCreatorLine ? '<div class="meta">Creator: <span class="x"></span>'
          '<a href="/creators/someone">@someone</a></div>' : ''}'
      '<astro-island uid="Z1abc" $islandAttributes '
      'props="${escape(props)}" ssr client="load"></astro-island>'
      // Pages are large; the parser refuses anything suspiciously small.
      '${'<p>filler</p>' * 100}'
      '</body></html>';

  group('Astro props decoding', () {
    test('a plain value is unwrapped', () {
      expect(decodeAstroValue(<Object?>[0, 'hi']), 'hi');
      expect(decodeAstroValue(<Object?>[0, 7]), 7);
      expect(decodeAstroValue(<Object?>[0, null]), isNull);
    });

    test('an object unwraps each of its own values in turn', () {
      final decoded = decodeAstroValue(<Object?>[
        0,
        <String, Object?>{
          'a': <Object?>[0, 'x'],
          'b': <Object?>[
            0,
            <String, Object?>{'c': <Object?>[0, 'y']},
          ],
        },
      ]);
      expect(decoded, <String, Object?>{
        'a': 'x',
        'b': <String, Object?>{'c': 'y'},
      });
    });

    test('an array unwraps its items', () {
      expect(
        decodeAstroValue(<Object?>[
          1,
          <Object?>[
            <Object?>[0, 2],
            <Object?>[0, 53],
          ],
        ]),
        <Object?>[2, 53],
      );
    });

    test('a type the app does not model hands back its raw data', () {
      // Astro also encodes dates, bigints and typed arrays. None appear in this
      // payload, and guessing at them would be worse than passing them through.
      expect(decodeAstroValue(<Object?>[3, '2026-01-01']), '2026-01-01');
      expect(decodeAstroValue('not wrapped'), 'not wrapped');
    });
  });

  group('attribute unescaping', () {
    test('the escapes JannyAI writes are undone', () {
      expect(unescapeAttribute('&quot;a&quot;'), '"a"');
      expect(unescapeAttribute('&lt;b&gt;'), '<b>');
      expect(unescapeAttribute('it&#39;s'), "it's");
    });

    test('text that legitimately contained an escape does not decode twice', () {
      // `&amp;lt;` means the literal text "&lt;", not the character "<".
      expect(unescapeAttribute('&amp;lt;'), '&lt;');
      expect(unescapeAttribute('Tom &amp; Jerry'), 'Tom & Jerry');
    });
  });

  group('page parsing', () {
    test('the definition comes out with JannyAI\'s fields uncrossed', () {
      final parsed = parseJannyPage(page(characterProps()));

      expect(parsed.hasDefinition, isTrue);
      expect(parsed.character['name'], 'Aria');
      // JannyAI's `personality` is the definition body …
      expect(parsed.character['personality'], 'A ranger of the northern wood.');
      // … and its `description` is the public blurb.
      expect(parsed.character['description'], contains('be kind'));
      expect(parsed.character['tagIds'], <Object?>[2, 53]);
      expect(parsed.imageUrl, 'https://img.example/a.webp');
      // The creator is rendered into the page, not always into the props.
      expect(parsed.creator, 'someone');
    });

    test('an island whose attributes are in another order still parses', () {
      // The extension's regex expects props last. Nothing guarantees that, so
      // the parser also sweeps every island on the page.
      final html = page(
        characterProps(),
        islandAttributes: 'renderer-url="/_astro/client.js"',
      );
      expect(html, isNot(contains('component-export')));
      final parsed = parseJannyPage(html);
      expect(parsed.character['name'], 'Aria');
    });

    test('a page with no definition in it is reported as such', () {
      final parsed = parseJannyPage(
        page(characterProps(personality: '', firstMessage: '')),
      );
      expect(parsed.hasDefinition, isFalse);
      expect(parsed.character['name'], 'Aria');
    });

    test('a Cloudflare check is told apart from a broken page', () {
      const challenge = '<!DOCTYPE html><html><head>'
          '<title>Just a moment...</title></head><body>'
          '<div id="challenge-platform"></div></body></html>';
      expect(looksLikeChallenge(challenge), isTrue);
      expect(
        () => parseJannyPage(challenge),
        throwsA(isA<JannyPageException>().having(
          (e) => e.message,
          'message',
          contains('Cloudflare check'),
        )),
      );
    });

    test('a real page is not mistaken for a check', () {
      expect(looksLikeChallenge(page(characterProps())), isFalse);
      expect(looksLikeCharacterPage(page(characterProps())), isTrue);
    });

    test('a page that has been restructured says so, with a count', () {
      final html = '<!doctype html><html><body>'
          '<astro-island props="{&quot;other&quot;:[0,1]}"></astro-island>'
          '${'<p>filler</p>' * 100}</body></html>';
      expect(
        () => parseJannyPage(html),
        throwsA(isA<JannyPageException>().having(
          (e) => e.message,
          'message',
          allOf(contains('no longer carries'), contains('1 islands')),
        )),
      );
    });

    test('something that is not a character page at all is rejected early', () {
      expect(
        () => parseJannyPage('<html><body>nope</body></html>'),
        throwsA(isA<JannyPageException>().having(
          (e) => e.message,
          'message',
          contains('did not look like'),
        )),
      );
    });

    test('the creator line is optional', () {
      final parsed = parseJannyPage(
        page(characterProps(), withCreatorLine: false),
      );
      expect(parsed.creator, isNull);
      expect(scrapeCreator('<div>no creator here</div>'), isNull);
    });
  });
}
