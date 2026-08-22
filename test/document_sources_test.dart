import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/embedding.dart';
import 'package:maichat/services/document_sources.dart';

void main() {
  group('Wikipedia', () {
    test('recognises a Wikipedia article link', () {
      expect(
        isWikipedia(Uri.parse('https://en.wikipedia.org/wiki/Dragon')),
        true,
      );
      expect(
        isWikipedia(Uri.parse('https://de.wikipedia.org/wiki/Drache')),
        true,
      );
      expect(isWikipedia(Uri.parse('https://example.org/wiki/Dragon')), false);
      expect(
        isWikipedia(Uri.parse('https://en.wikipedia.org/')),
        false,
      );
    });

    test('builds the plain-text extract API URL from an article link', () {
      final api =
          buildWikipediaApiUrl(Uri.parse('https://en.wikipedia.org/wiki/Foo_Bar'));
      expect(api.host, 'en.wikipedia.org');
      expect(api.path, '/w/api.php');
      expect(api.queryParameters['titles'], 'Foo_Bar');
      expect(api.queryParameters['explaintext'], '1');
      expect(api.queryParameters['prop'], 'extracts');
    });

    test('uses the language subdomain', () {
      final api = buildWikipediaApiUrl(
          Uri.parse('https://fr.wikipedia.org/wiki/Chat'));
      expect(api.host, 'fr.wikipedia.org');
      expect(api.queryParameters['titles'], 'Chat');
    });

    test('parses the extract out of the API JSON', () {
      const body = '''
      {"query":{"pages":{"123":{"title":"Dragon","extract":"A dragon is a creature."}}}}''';
      final result = parseWikipediaExtract(body);
      expect(result.title, 'Dragon');
      expect(result.text, 'A dragon is a creature.');
    });

    test('returns empty on a malformed or missing extract', () {
      expect(parseWikipediaExtract('not json').text, '');
      expect(parseWikipediaExtract('{"query":{"pages":{}}}').text, '');
    });
  });

  group('stripHtml', () {
    test('removes tags and decodes entities', () {
      const html = '<p>Hello &amp; welcome</p><p>Second line</p>';
      final text = stripHtml(html);
      expect(text, contains('Hello & welcome'));
      expect(text, contains('Second line'));
      expect(text, isNot(contains('<p>')));
    });

    test('drops script and style contents entirely', () {
      const html =
          '<style>.a{color:red}</style><script>alert(1)</script><p>Body</p>';
      final text = stripHtml(html);
      expect(text, contains('Body'));
      expect(text, isNot(contains('alert')));
      expect(text, isNot(contains('color:red')));
    });
  });

  group('pastedDocument', () {
    test('wraps text with a name and paste source', () {
      final doc = pastedDocument('My notes', 'some text');
      expect(doc.name, 'My notes');
      expect(doc.text, 'some text');
      expect(doc.source, DocSource.paste);
      expect(doc.isEmpty, false);
    });

    test('falls back to a default name', () {
      expect(pastedDocument('', 'x').name, 'Pasted text');
    });
  });
}
