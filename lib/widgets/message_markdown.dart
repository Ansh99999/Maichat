import 'dart:collection';

import 'package:flutter/material.dart';

/// Colours and base text style used when turning a message's markdown/HTML into
/// [InlineSpan]s. [emphasis] tints *italic*/**bold** runs; [quote] tints text
/// inside "quotes"; code runs use [codeBackground]/[codeForeground]; [link]
/// tints `<a>`/link text.
class MarkdownStyles {
  const MarkdownStyles({
    required this.base,
    required this.emphasis,
    required this.quote,
    required this.codeBackground,
    required this.codeForeground,
    required this.link,
  });

  final TextStyle base;
  final Color emphasis;
  final Color quote;
  final Color codeBackground;
  final Color codeForeground;
  final Color link;

  @override
  bool operator ==(Object other) =>
      other is MarkdownStyles &&
      other.base == base &&
      other.emphasis == emphasis &&
      other.quote == quote &&
      other.codeBackground == codeBackground &&
      other.codeForeground == codeForeground &&
      other.link == link;

  @override
  int get hashCode => Object.hash(
        base,
        emphasis,
        quote,
        codeBackground,
        codeForeground,
        link,
      );
}

/// Parsed spans by `stylesHash:text`, most recently used last.
///
/// The chat rebuilds every visible turn on each streaming delta and each scroll,
/// and re-parsing a message's markdown each time is the single largest cost in
/// that rebuild. The spans are immutable and hold no gesture recognizers, so
/// handing back the same list — the same instances — is safe, and it also lets
/// the enclosing `TextSpan` compare equal so the paragraph is not laid out
/// again.
final LinkedHashMap<String, List<InlineSpan>> _spanCache =
    LinkedHashMap<String, List<InlineSpan>>();

/// Enough for a screenful of turns several times over, small enough that the
/// text it pins is negligible next to the conversation itself.
const int _spanCacheMax = 96;

/// Renders [text] as a light subset of markdown **and** HTML into inline spans:
/// headings, bullet/numbered lists and blockquotes at the line level, and
/// **bold**, *italic*, ***both***, `code`, ~~strike~~ and "quoted" runs inline,
/// plus common inline HTML tags (`<b> <i> <u> <s> <code> <mark> <q> <a>`) and
/// block tags (`<p> <div> <br> <h1-6> <blockquote> <ul>/<ol>/<li>`), and HTML
/// entities. Anything that doesn't parse is left as literal text, so raw prose
/// is never mangled.
List<InlineSpan> buildMessageSpans(String text, MarkdownStyles styles) {
  final key = '${styles.hashCode}:$text';
  final cached = _spanCache.remove(key);
  if (cached != null) {
    _spanCache[key] = cached; // Re-insert as most recently used.
    return cached;
  }
  final spans = List<InlineSpan>.unmodifiable(_parseMessage(text, styles));
  _spanCache[key] = spans;
  while (_spanCache.length > _spanCacheMax) {
    _spanCache.remove(_spanCache.keys.first);
  }
  return spans;
}

/// Drops the parsed-span cache. For tests.
void clearMessageSpanCache() => _spanCache.clear();

List<InlineSpan> _parseMessage(String text, MarkdownStyles styles) {
  final lines = _preprocessHtmlBlocks(text).split('\n');
  final out = <InlineSpan>[];
  for (var i = 0; i < lines.length; i++) {
    if (i > 0) out.add(const TextSpan(text: '\n'));
    _appendLine(out, lines[i], styles);
  }
  return out;
}

final _heading = RegExp(r'^(#{1,6})\s+(.*)$');
final _blockquote = RegExp(r'^>\s?(.*)$');
final _bullet = RegExp(r'^(\s*)[-*+]\s+(.*)$');
final _ordered = RegExp(r'^(\s*)(\d+)\.\s+(.*)$');
const _headingScale = [1.6, 1.45, 1.3, 1.18, 1.08, 1.0];

void _appendLine(List<InlineSpan> out, String line, MarkdownStyles s) {
  final heading = _heading.firstMatch(line);
  if (heading != null) {
    final level = heading.group(1)!.length;
    final style = s.base.copyWith(
      fontWeight: FontWeight.bold,
      fontSize: (s.base.fontSize ?? 16) * _headingScale[level - 1],
    );
    out.addAll(_inline(heading.group(2)!, style, s));
    return;
  }
  final quote = _blockquote.firstMatch(line);
  if (quote != null) {
    final style = s.base.copyWith(color: s.quote, fontStyle: FontStyle.italic);
    out.add(TextSpan(text: '▎ ', style: style));
    out.addAll(_inline(quote.group(1)!, style, s));
    return;
  }
  final bullet = _bullet.firstMatch(line);
  if (bullet != null) {
    out.add(TextSpan(text: '${bullet.group(1)}•  ', style: s.base));
    out.addAll(_inline(bullet.group(2)!, s.base, s));
    return;
  }
  final ordered = _ordered.firstMatch(line);
  if (ordered != null) {
    out.add(TextSpan(
        text: '${ordered.group(1)}${ordered.group(2)}.  ', style: s.base));
    out.addAll(_inline(ordered.group(3)!, s.base, s));
    return;
  }
  out.addAll(_inline(line, s.base, s));
}
// APPEND-INLINE

/// Depth cap so pathological deeply-nested markup can't blow the stack or spend
/// quadratic time; past it, the remainder is rendered literally.
const int _maxDepth = 32;

List<InlineSpan> _inline(String s, TextStyle style, MarkdownStyles cfg,
    [int depth = 0]) {
  if (depth > _maxDepth) {
    return [TextSpan(text: _decodeEntities(s), style: style)];
  }
  final spans = <InlineSpan>[];
  final buf = StringBuffer();
  void flush() {
    if (buf.isNotEmpty) {
      spans.add(TextSpan(text: _decodeEntities(buf.toString()), style: style));
      buf.clear();
    }
  }

  var i = 0;
  while (i < s.length) {
    final c = s[i];

    // Inline HTML tag (<b>, <i>, <code>, <a>, <q>, <mark>, …).
    if (c == '<') {
      final consumed = _htmlInline(s, i, style, cfg, spans, flush, depth);
      if (consumed != -1) {
        i = consumed;
        continue;
      }
    }

    // Inline code — verbatim (entities and markup shown as typed).
    if (c == '`') {
      final end = s.indexOf('`', i + 1);
      if (end > i) {
        flush();
        spans.add(TextSpan(
          text: s.substring(i + 1, end),
          style: style.copyWith(
            fontFamily: 'monospace',
            color: cfg.codeForeground,
            backgroundColor: cfg.codeBackground,
          ),
        ));
        i = end + 1;
        continue;
      }
    }

    // Strikethrough ~~...~~
    if (c == '~' && i + 1 < s.length && s[i + 1] == '~') {
      final end = s.indexOf('~~', i + 2);
      if (end > i + 1) {
        flush();
        spans.addAll(_inline(
          s.substring(i + 2, end),
          style.copyWith(decoration: TextDecoration.lineThrough),
          cfg,
          depth + 1,
        ));
        i = end + 2;
        continue;
      }
    }

    // Emphasis * / _ (1 = italic, 2 = bold, 3 = both). Light boundary rules
    // avoid eating spaced asterisks and snake_case underscores.
    if (c == '*' || c == '_') {
      var run = 1;
      while (i + run < s.length && s[i + run] == c) {
        run++;
      }
      final next = i + run < s.length ? s[i + run] : '';
      final boundaryOk = c == '*' || !_isWord(i == 0 ? '' : s[i - 1]);
      if (next.isNotEmpty && !_isSpace(next) && boundaryOk) {
        final close = _findClose(s, i + run, c, run);
        if (close != -1) {
          flush();
          var ns = style.copyWith(color: cfg.emphasis);
          if (run >= 3) {
            ns = ns.copyWith(
                fontWeight: FontWeight.bold, fontStyle: FontStyle.italic);
          } else if (run == 2) {
            ns = ns.copyWith(fontWeight: FontWeight.bold);
          } else {
            ns = ns.copyWith(fontStyle: FontStyle.italic);
          }
          spans.addAll(_inline(s.substring(i + run, close), ns, cfg, depth + 1));
          i = close + run;
          continue;
        }
      }
    }

    // "Quoted" text — colour the quote marks and their contents.
    if (c == '"' || c == '“') {
      final closeChar = c == '“' ? '”' : '"';
      final end = s.indexOf(closeChar, i + 1);
      if (end > i) {
        flush();
        final qStyle = style.copyWith(color: cfg.quote);
        spans.add(TextSpan(text: c, style: qStyle));
        spans.addAll(_inline(s.substring(i + 1, end), qStyle, cfg, depth + 1));
        spans.add(TextSpan(text: closeChar, style: qStyle));
        i = end + 1;
        continue;
      }
    }

    buf.write(c);
    i++;
  }
  flush();
  return spans;
}

/// Finds the start of a closing run of [marker] for an opener [run] long, not
/// immediately preceded by a space (so `*a *` doesn't close). A single-marker
/// opener (italic) skips over longer runs, which are bold/both delimiters for a
/// nested span — so `*a **b** c*` parses as italic wrapping a bold, rather than
/// closing on the inner `**`.
int _findClose(String s, int start, String marker, int run) {
  var j = start;
  while (j < s.length) {
    if (s[j] == marker) {
      var len = 1;
      while (j + len < s.length && s[j + len] == marker) {
        len++;
      }
      final closes = run == 1 ? len == 1 : len >= run;
      if (closes && j > 0 && !_isSpace(s[j - 1])) return j;
      j += len;
    } else {
      j++;
    }
  }
  return -1;
}

bool _isSpace(String ch) => ch == ' ' || ch == '\t';

bool _isWord(String ch) =>
    ch.isNotEmpty && RegExp(r'[A-Za-z0-9]').hasMatch(ch);

// ---------------------------------------------------------------------------
// HTML
// ---------------------------------------------------------------------------

class _Tag {
  const _Tag(this.name, this.closing, this.selfClose, this.end);
  final String name;
  final bool closing;
  final bool selfClose;
  final int end;
}

final _tagPrefix = RegExp(r'</?([a-zA-Z][a-zA-Z0-9]*)([^<>]*)>');

/// Matches an HTML tag anchored exactly at [i], or null if there isn't one.
/// Bounds the work to the next `>` (and a sane tag length) so a stray `<`
/// followed by a long run of text can't trigger quadratic regex backtracking.
_Tag? _htmlTagAt(String s, int i) {
  final gt = s.indexOf('>', i);
  if (gt == -1 || gt - i > 256) return null;
  final m = _tagPrefix.matchAsPrefix(s, i);
  if (m == null) return null;
  final closing = m.group(0)!.startsWith('</');
  final attrs = m.group(2) ?? '';
  return _Tag(m.group(1)!.toLowerCase(), closing, attrs.trimRight().endsWith('/'),
      m.end);
}

/// The style an inline HTML tag applies, or null when the tag is unknown (so it
/// falls through to being rendered literally).
TextStyle? _htmlStyle(String name, TextStyle s, MarkdownStyles cfg) {
  switch (name) {
    case 'b':
    case 'strong':
      return s.copyWith(fontWeight: FontWeight.bold, color: cfg.emphasis);
    case 'i':
    case 'em':
      return s.copyWith(fontStyle: FontStyle.italic, color: cfg.emphasis);
    case 'u':
    case 'ins':
      return s.copyWith(decoration: TextDecoration.underline);
    case 's':
    case 'strike':
    case 'del':
      return s.copyWith(decoration: TextDecoration.lineThrough);
    case 'code':
    case 'kbd':
    case 'tt':
    case 'samp':
      return s.copyWith(
        fontFamily: 'monospace',
        color: cfg.codeForeground,
        backgroundColor: cfg.codeBackground,
      );
    case 'mark':
      return s.copyWith(backgroundColor: cfg.codeBackground);
    case 'q':
      return s.copyWith(color: cfg.quote);
    case 'a':
      return s.copyWith(color: cfg.link, decoration: TextDecoration.underline);
    case 'span':
    case 'small':
    case 'big':
    case 'sub':
    case 'sup':
    case 'font':
    case 'abbr':
    case 'cite':
      return s; // Passthrough: render children, ignore attributes.
    default:
      return null;
  }
}
// APPEND-HTML-2

/// Handles an inline HTML tag starting at [i]. Returns the index just past the
/// consumed tag (and its content), or -1 to leave the `<` as literal text.
int _htmlInline(
  String s,
  int i,
  TextStyle style,
  MarkdownStyles cfg,
  List<InlineSpan> spans,
  void Function() flush,
  int depth,
) {
  final tag = _htmlTagAt(s, i);
  if (tag == null || tag.closing) return -1;
  if (tag.name == 'br') {
    flush();
    spans.add(const TextSpan(text: '\n'));
    return tag.end;
  }
  final innerStyle = _htmlStyle(tag.name, style, cfg);
  if (innerStyle == null || tag.selfClose) return -1;
  final close = _findHtmlClose(s, tag.end, tag.name);
  if (close == null) return -1;
  flush();
  final inner = s.substring(tag.end, close.$1);
  if (tag.name == 'q') {
    spans.add(TextSpan(text: '“', style: innerStyle));
    spans.addAll(_inline(inner, innerStyle, cfg, depth + 1));
    spans.add(TextSpan(text: '”', style: innerStyle));
  } else {
    spans.addAll(_inline(inner, innerStyle, cfg, depth + 1));
  }
  return close.$2;
}

/// Finds the matching close tag for [name] opened at [start], honouring nesting.
/// Returns (startOfCloseTag, endOfCloseTag) or null.
(int, int)? _findHtmlClose(String s, int start, String name) {
  var depth = 1;
  var j = start;
  while (j < s.length) {
    if (s[j] == '<') {
      final t = _htmlTagAt(s, j);
      if (t != null && t.name == name && !t.selfClose) {
        if (t.closing) {
          depth--;
          if (depth == 0) return (j, t.end);
        } else {
          depth++;
        }
        j = t.end;
        continue;
      }
    }
    j++;
  }
  return null;
}

/// Normalises block-level HTML into the line-based markdown the renderer
/// already understands (paragraphs/divs → blank lines, headings → `#`, ordered
/// lists → `1.`/`2.`, other list items → `-`, blockquotes → `>`), leaving
/// inline tags for [_inline]. Inline code spans are masked first so HTML shown
/// as code (e.g. `<div>`) survives verbatim.
String _preprocessHtmlBlocks(String t) {
  if (!t.contains('<')) return t;

  final codes = <String>[];
  var s = t.replaceAllMapped(RegExp(r'`[^`\n]*`'), (m) {
    codes.add(m.group(0)!);
    return '${codes.length - 1}';
  });

  // Ordered lists: number their items before the generic <li> rule.
  s = s.replaceAllMapped(
    RegExp(r'<ol(\s[^>]*)?>(.*?)</ol\s*>', caseSensitive: false, dotAll: true),
    (m) {
      var n = 0;
      final body = m.group(2)!.replaceAllMapped(
            RegExp(r'<li(\s[^>]*)?>', caseSensitive: false),
            (_) => '\n${++n}. ',
          );
      return '\n$body\n';
    },
  );

  s = s
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'<p(\s[^>]*)?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</div\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<div(\s[^>]*)?>', caseSensitive: false), '\n')
      .replaceAllMapped(
        RegExp(r'<h([1-6])(\s[^>]*)?>', caseSensitive: false),
        (m) => '\n${'#' * int.parse(m.group(1)!)} ',
      )
      .replaceAll(RegExp(r'</h[1-6]\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<blockquote(\s[^>]*)?>', caseSensitive: false), '\n> ')
      .replaceAll(RegExp(r'</blockquote\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<li(\s[^>]*)?>', caseSensitive: false), '\n- ')
      .replaceAll(RegExp(r'</li\s*>', caseSensitive: false), '')
      .replaceAll(RegExp(r'</?[uo]l(\s[^>]*)?>', caseSensitive: false), '\n');

  // Restore the masked inline code spans.
  if (codes.isNotEmpty) {
    s = s.replaceAllMapped(
      RegExp('(\\d+)'),
      (m) => codes[int.parse(m.group(1)!)],
    );
  }
  return s;
}

final _entity = RegExp(r'&(#x?[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);');
const _named = {
  'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' ',
  'mdash': '—', 'ndash': '–', 'hellip': '…', 'copy': '©', 'reg': '®',
  'trade': '™', 'deg': '°', 'laquo': '«', 'raquo': '»', 'rsquo': '’',
  'lsquo': '‘', 'ldquo': '“', 'rdquo': '”', 'middot': '·', 'bull': '•',
};

/// Decodes the HTML entities that show up in model output. Out-of-range numeric
/// references are left as their literal source rather than crashing the render.
String _decodeEntities(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(_entity, (m) {
    final body = m.group(1)!;
    if (body.startsWith('#x') || body.startsWith('#X')) {
      final code = int.tryParse(body.substring(2), radix: 16);
      return _fromCode(code) ?? m.group(0)!;
    }
    if (body.startsWith('#')) {
      final code = int.tryParse(body.substring(1));
      return _fromCode(code) ?? m.group(0)!;
    }
    return _named[body] ?? m.group(0)!;
  });
}

/// A single character for a valid Unicode scalar, or null when out of range
/// (String.fromCharCode throws above 0x10FFFF).
String? _fromCode(int? code) {
  if (code == null || code < 0 || code > 0x10FFFF) return null;
  return String.fromCharCode(code);
}



