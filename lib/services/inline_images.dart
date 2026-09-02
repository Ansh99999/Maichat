// Pictures that arrive as a *link* rather than as an attachment — the `![](…)`
// in a model's reply, the `<img>` in a creator's card, the bare
// `https://files.catbox.moe/….png` someone pasted.
//
// One place, because the chat and the character sheet had drifted: both build
// HTML and hand it to `flutter_html`, and both need the same three answers —
// is this URL a picture, does this text carry one at all (the signal to use the
// HTML engine instead of the cheap inline renderer), and how does a bare URL
// become an `<img>` once markdown has auto-linked it.

/// File extensions a renderer can actually draw.
const Set<String> _imageExtensions = {
  'png', 'jpg', 'jpeg', 'jfif', 'gif', 'webp', 'bmp', 'avif', 'apng', 'ico',
  'heic', 'heif',
};

/// Whether [url] points at a picture, judged by the extension on its **path** —
/// so a query string (`?width=600`, a CDN signature) does not hide it.
bool looksLikeImageUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return false;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return false;
  final path = uri.path.toLowerCase();
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return false;
  return _imageExtensions.contains(path.substring(dot + 1));
}

/// A markdown image, `![alt](src)`.
final _markdownImage = RegExp(r'!\[[^\]\n]*\]\(\s*<?([^\s)>]+)');

/// An `<img>` tag, however it is spelled.
final _imgTag = RegExp(r'<img\b', caseSensitive: false);

/// A bare `http(s)` URL ending in a picture's extension. Lazy, so it stops at the
/// extension rather than running on through whatever follows the URL, and
/// **bounded**: an unbounded lazy run makes a long stretch of non-matching text
/// after each `http` quadratic, and a creator's card can be a hundred kilobytes.
final _bareImageUrl = RegExp(
  r'''https?://[^\s<>"']{1,300}?'''
  r'\.(?:png|jpe?g|jfif|gif|webp|bmp|avif|apng|ico|heic|heif)\b',
  caseSensitive: false,
);

/// Whether [text] carries a picture that only the HTML engine can draw: a
/// markdown image, an `<img>`, or a bare link to a picture.
///
/// This is the routing signal. The lightweight inline renderer produces
/// `InlineSpan`s and has nowhere to put a bitmap, so a message it handles shows
/// `![](https://…)` as the literal characters — which is exactly what was
/// reported.
///
/// Each regex is gated behind a plain substring check: this runs on every visible
/// turn on every rebuild, including each frame of a streaming reply.
bool carriesInlineImage(String text) {
  if (text.isEmpty) return false;
  if (text.contains('](') && _markdownImage.hasMatch(text)) return true;
  if (text.contains('<') && _imgTag.hasMatch(text)) return true;
  return text.contains('http') && _bareImageUrl.hasMatch(text);
}

/// An `<a>` whose only content is its own href — what markdown's auto-linker
/// makes of a bare URL.
final _autolink = RegExp(
  r'''<a\s+href\s*=\s*(["'])([^"']+)\1\s*>([^<]*)</a\s*>''',
  caseSensitive: false,
);

/// Elements whose body is *not* prose and must be copied through untouched: CSS
/// that may well contain `url(…/thing.png)`, text shown verbatim, and the inside
/// of a link (already dealt with, or deliberately labelled).
const Set<String> _opaqueBodies = {
  'style', 'script', 'pre', 'code', 'textarea', 'title', 'a',
};

/// Turns a link to a picture in [html] into the picture itself.
///
/// Two shapes, because a picture URL reaches the renderer two ways. Markdown
/// auto-links a bare URL, so it arrives as an `<a>` — rewritten only when the
/// link's text *is* its href, since a deliberately labelled link ("[the
/// original](…/art.png)") means the author chose words over the photograph. And
/// markdown passes a raw HTML block straight through without auto-linking
/// anything inside it, so a URL sitting in a card's own `<div>` arrives as plain
/// text — found here by scanning the prose between tags and skipping the elements
/// whose contents are not prose.
String linkedImagesToPictures(String html) {
  if (!html.contains('http')) return html;
  return _bareUrlsToPictures(_autolinksToPictures(html));
}

String _autolinksToPictures(String html) {
  if (!html.contains('<a')) return html;
  return html.replaceAllMapped(_autolink, (m) {
    final href = m.group(2)!;
    final text = m.group(3)!.trim();
    if (text != href.trim() || !looksLikeImageUrl(href)) return m.group(0)!;
    return '<img src="$href" />';
  });
}

String _bareUrlsToPictures(String html) {
  final out = StringBuffer();
  final lower = html.toLowerCase();
  var i = 0;
  while (i < html.length) {
    if (html[i] == '<') {
      final gt = html.indexOf('>', i);
      if (gt < 0) {
        out.write(html.substring(i));
        break;
      }
      final tag = html.substring(i, gt + 1);
      out.write(tag);
      i = gt + 1;
      final name = htmlTagName(tag);
      if (name != null &&
          !tag.startsWith('</') &&
          !tag.endsWith('/>') &&
          _opaqueBodies.contains(name)) {
        final close = lower.indexOf('</$name', i);
        final end = close < 0 ? html.length : close;
        out.write(html.substring(i, end));
        i = end;
      }
      continue;
    }
    // Only worth a regex when a URL could actually start here.
    if (html[i] == 'h' || html[i] == 'H') {
      final match = _bareImageUrl.matchAsPrefix(html, i);
      if (match != null) {
        out.write('<img src="${match.group(0)}" />');
        i = match.end;
        continue;
      }
    }
    out.write(html[i]);
    i++;
  }
  return out.toString();
}

final _tagName = RegExp(r'^</?\s*([a-zA-Z][a-zA-Z0-9]*)');

/// The lowercased element name of a whole tag (`</DIV >` → `div`), or null when
/// [tag] is not one. Shared with the quote-wrapping pass in `message_html.dart`,
/// which walks the same documents for the same reason: a rewrite that reaches
/// inside a tag destroys it.
String? htmlTagName(String tag) =>
    _tagName.firstMatch(tag)?.group(1)?.toLowerCase();
