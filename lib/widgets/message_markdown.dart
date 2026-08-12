import 'package:flutter/material.dart';

/// Colours and base text style used when turning a message's markdown into
/// [InlineSpan]s. [emphasis] tints *italic*/**bold** runs; [quote] tints text
/// inside "quotes"; code runs use [codeBackground]/[codeForeground].
class MarkdownStyles {
  const MarkdownStyles({
    required this.base,
    required this.emphasis,
    required this.quote,
    required this.codeBackground,
    required this.codeForeground,
  });

  final TextStyle base;
  final Color emphasis;
  final Color quote;
  final Color codeBackground;
  final Color codeForeground;
}

/// Renders [text] as a light subset of markdown into inline spans: headings,
/// bullet/numbered lists and blockquotes at the line level, and **bold**,
/// *italic*, ***both***, `code`, ~~strike~~ and "quoted" runs inline. Anything
/// that doesn't parse is left as literal text, so raw prose is never mangled.
List<InlineSpan> buildMessageSpans(String text, MarkdownStyles styles) {
  final lines = text.split('\n');
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

List<InlineSpan> _inline(String s, TextStyle style, MarkdownStyles cfg) {
  final spans = <InlineSpan>[];
  final buf = StringBuffer();
  void flush() {
    if (buf.isNotEmpty) {
      spans.add(TextSpan(text: buf.toString(), style: style));
      buf.clear();
    }
  }

  var i = 0;
  while (i < s.length) {
    final c = s[i];

    // Inline code — verbatim, no nested formatting.
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
          spans.addAll(_inline(s.substring(i + run, close), ns, cfg));
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
        spans.addAll(_inline(s.substring(i + 1, end), qStyle, cfg));
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

/// Finds the start of a closing run of [marker] at least [run] long, not
/// immediately preceded by a space (so `*a *` doesn't close).
int _findClose(String s, int start, String marker, int run) {
  var j = start;
  while (j < s.length) {
    if (s[j] == marker) {
      var len = 1;
      while (j + len < s.length && s[j + len] == marker) {
        len++;
      }
      if (len >= run && j > 0 && !_isSpace(s[j - 1])) return j;
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

