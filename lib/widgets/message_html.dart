import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../models/text_wrap.dart';
import '../services/inline_images.dart';
import '../services/jank_logger.dart';
import 'html_image.dart';

/// Colours + base size for the HTML renderer, mirroring the ChatInterface text
/// options so an HTML message matches a plain one. [wraps] carries the user's
/// own symbol pairs, applied to the message source before it becomes HTML.
class HtmlMessageStyle {
  const HtmlMessageStyle({
    required this.base,
    required this.emphasis,
    required this.quote,
    required this.codeBackground,
    required this.codeForeground,
    required this.link,
    required this.fontSize,
    this.wraps = const [],
  });

  final Color base;
  final Color emphasis;
  final Color quote;
  final Color codeBackground;
  final Color codeForeground;
  final Color link;
  final double fontSize;
  final List<TextWrapRule> wraps;

  @override
  bool operator ==(Object other) =>
      other is HtmlMessageStyle &&
      other.base == base &&
      other.emphasis == emphasis &&
      other.quote == quote &&
      other.codeBackground == codeBackground &&
      other.codeForeground == codeForeground &&
      other.link == link &&
      other.fontSize == fontSize &&
      listEquals(other.wraps, wraps);

  @override
  int get hashCode => Object.hash(
        base,
        emphasis,
        quote,
        codeBackground,
        codeForeground,
        link,
        fontSize,
        Object.hashAll(wraps),
      );
}

/// Whether [text] contains any HTML tag — the signal to route a message to the
/// full HTML+CSS engine instead of the lightweight inline renderer.
bool looksLikeHtml(String text) => _htmlTag.hasMatch(text);

/// Whether a message has to go through the HTML engine at all.
///
/// Tags are the obvious reason. The other is a **picture**: the lightweight
/// renderer builds [InlineSpan]s and has nowhere to put a bitmap, so a turn
/// carrying `![](https://files.catbox.moe/x.png)` — or just the bare link —
/// showed the characters instead of the photograph. That was the reported bug,
/// and it is fixed by sending those turns down this path, where [_html] draws
/// them through the shared picture cache.
bool messageNeedsHtml(String text) =>
    looksLikeHtml(text) || carriesInlineImage(text);

final _htmlTag = RegExp(r'<(/?[a-zA-Z][a-zA-Z0-9]*)(\s[^<>]*)?/?>');

/// Converts a message (markdown, possibly with inline/block HTML) to HTML,
/// applying the user's [wraps] to the source first, then wrapping
/// straight-double-quoted spans in <q> so they can be tinted — mirroring
/// Agnaistic's showdown + quote-wrap pipeline.
///
/// The quote marks stay inside the `<q>`: a browser draws them itself from
/// `q::before`/`::after`, but flutter_html has no generated content, so dropping
/// them here made every quoted run lose its quotes.
String messageToHtml(String text, {List<TextWrapRule> wraps = const []}) {
  final source = stripReasoningWrappers(text);
  final html = md.markdownToHtml(
    applyWrapRules(source, wraps),
    extensionSet: md.ExtensionSet.gitHubWeb,
  );
  // A bare link to a picture becomes the picture. Markdown has already turned it
  // into an `<a>`; this is the one place that knows a photograph was meant.
  return linkedImagesToPictures(
      tameRichCss(resolveFontFamilies(wrapQuotedSpans(html))));
}

// --- quoted spans -----------------------------------------------------------

/// Curly quotes, folded to straight ones so a run typed with them is tinted too.
final _curlyQuotes = RegExp(r'[“”„‟]');

/// A straight-double-quoted run of prose.
final _quotedRun = RegExp(r'"[^"]+"');

/// A fenced or inline code run that survived markdown — inside a raw HTML block
/// markdown copies its contents through, backticks and all.
final _rawCode = RegExp(r'```[\s\S]*?```|`[^`\n]*`');

/// Inline elements a quoted run is allowed to cross. `"Hello **there**"` is one
/// quotation and reaches this pass as `"Hello <strong>there</strong>"`, so the
/// run has to be let through the emphasis.
const Set<String> _quoteCrossable = {
  'em', 'i', 'strong', 'b', 'u', 's', 'strike', 'del', 'ins', 'mark', 'small',
  'sub', 'sup', 'span', 'a', 'abbr', 'cite', 'time', 'font', 'q', 'img', 'wbr',
};

/// Elements whose body is not prose, copied through without being read: a quote
/// in code is part of the code.
const Set<String> _quoteOpaque = {
  'code', 'pre', 'style', 'script', 'textarea', 'title',
};

/// Mask for a stretch that must be copied through but may sit inside a quoted
/// run — an inline tag, a code run. One character, so it cannot look like prose
/// and cannot itself contain a quote. `applyWrapRules` masks with the same one.
const String _mask = '\u0001';

/// Wraps each straight-double-quoted run of prose in [html] in a `<q>`, so the
/// Chat Interface's quote colour can reach it.
///
/// Deliberately a walk rather than one regex. The regex this replaces
/// (`("[^"]+")`, tried after an alternative that matched a whole tag) paired a
/// quote in the prose with the next quote *anywhere* in the document, and an
/// HTML document is full of quotes that belong to attributes. So a message with
/// an odd number of quotes in it — one `"` a model never closed — paired that
/// one with the `"` opening `src="…"` on the next picture and wrapped a `<q>`
/// around the first half of the tag. The tag was destroyed: the picture vanished
/// with no trace, and `" alt="` was left showing as text.
///
/// Two rules follow from that, and they are the whole function. A run never
/// reads what is inside a tag. And a run ends at anything that is not inline: a
/// `<q>` straddling `</p><p>` is unbalanced markup, and flutter_html then draws
/// every following paragraph inside the quotation.
String wrapQuotedSpans(String html) {
  if (!html.contains('"') &&
      !html.contains('&quot;') &&
      !_curlyQuotes.hasMatch(html)) {
    return html;
  }
  // The mask has to be absent from the text for the restore to line up, and a
  // control character in a message is not content worth keeping.
  final source = html.contains(_mask) ? html.replaceAll(_mask, '') : html;

  final out = StringBuffer();
  final run = StringBuffer(); // the current inline run, tags masked out
  final masked = <String>[]; // what each mask in [run] stands for, in order

  void flush() {
    if (run.isNotEmpty) out.write(_wrapRun(run.toString(), masked));
    run.clear();
    masked.clear();
  }

  void hide(String verbatim) {
    masked.add(verbatim);
    run.write(_mask);
  }

  final lower = source.toLowerCase();
  var i = 0;
  while (i < source.length) {
    final ch = source[i];
    if (ch == '<') {
      final gt = source.indexOf('>', i);
      if (gt < 0) {
        // An unclosed `<`: prose, then, like every other stray character.
        run.write(source.substring(i));
        break;
      }
      final tag = source.substring(i, gt + 1);
      final name = htmlTagName(tag);
      i = gt + 1;
      if (name != null && _quoteOpaque.contains(name)) {
        flush();
        out.write(tag);
        if (!tag.startsWith('</') && !tag.endsWith('/>')) {
          final close = lower.indexOf('</$name', i);
          final end = close < 0 ? source.length : close;
          out.write(source.substring(i, end));
          i = end;
        }
        continue;
      }
      if (name != null && _quoteCrossable.contains(name)) {
        hide(tag);
        continue;
      }
      flush(); // a block boundary, or a tag we know nothing about
      out.write(tag);
      continue;
    }
    if (ch == '`') {
      final code = _rawCode.matchAsPrefix(source, i);
      if (code != null) {
        hide(code.group(0)!);
        i = code.end;
        continue;
      }
    }
    run.write(ch);
    i++;
  }
  flush();
  return out.toString();
}

/// One inline run: fold its quote characters, wrap what pairs up, put back what
/// was masked out.
String _wrapRun(String run, List<String> masked) {
  var text = run.replaceAll(_curlyQuotes, '"').replaceAll('&quot;', '"');
  text = text.replaceAllMapped(_quotedRun, (m) => '<q>${m.group(0)}</q>');
  if (masked.isEmpty) return text;
  final parts = text.split(_mask);
  final restored = StringBuffer(parts.first);
  for (var i = 1; i < parts.length; i++) {
    restored
      ..write(masked[i - 1])
      ..write(parts[i]);
  }
  return restored.toString();
}

// --- reasoning wrappers ------------------------------------------------------

/// Model-internal reasoning that leaked into the message body wrapped in
/// Anthropic-style `<thinking>`/`<antthinking>` tags — distinct from the app's
/// own `<think>` reasoning tag, which [splitReasoning] has already pulled out
/// before a live reply is stored. Imported chats (Agnai/ST exports) routinely
/// carry these blocks inline; rendered verbatim they dump a wall of the model's
/// planning above every turn, so they are dropped from the *display* only —
/// [ChatMessage.content] keeps them for prompt-building and export.
final _reasoningWrapper = RegExp(
  r'<(thinking|antthinking)\b[^>]*>[\s\S]*?</\1\s*>',
  caseSensitive: false,
);

/// [text] with any `<thinking>`/`<antthinking>` block removed.
String stripReasoningWrappers(String text) {
  if (!text.contains('<')) return text;
  return text.replaceAll(_reasoningWrapper, '').trimLeft();
}

// --- text wrapping ----------------------------------------------------------

/// Code runs, masked before wrap rules are applied so a rule can't restyle text
/// that is meant to be shown verbatim.
final _codeRun = RegExp(r'```[\s\S]*?```|`[^`\n]*`');

/// Nesting cap for wrapped runs — deep enough for any real message, shallow
/// enough that pathological input can't recurse without bound.
const int _maxWrapDepth = 8;

/// Rewrites each run matched by a [TextWrapRule] in the *source* [text] as a
/// coloured `<span>`, dropping or keeping the markers per rule.
///
/// This runs before markdown → HTML rather than after, because a rule's markers
/// are written as typed: by the time the source is HTML, a `<`/`>` pair has
/// become `&lt;`/`&gt;` (or been read as a tag) and no longer matches.
String applyWrapRules(String text, List<TextWrapRule> rules) {
  final active = activeWrapRules(rules);
  if (active.isEmpty) return text;

  // Mask code first, restore after, so `<x>` inside backticks stays literal.
  final codes = <String>[];
  final masked = text.replaceAllMapped(_codeRun, (m) {
    codes.add(m.group(0)!);
    return '${codes.length - 1}';
  });

  var out = _wrapSource(masked, active, 0);
  if (codes.isNotEmpty) {
    out = out.replaceAllMapped(
      RegExp('(\\d+)'),
      (m) => codes[int.parse(m.group(1)!)],
    );
  }
  return out;
}

String _wrapSource(String s, List<TextWrapRule> rules, int depth) {
  if (depth > _maxWrapDepth) return s;
  final out = StringBuffer();
  var i = 0;
  scan:
  while (i < s.length) {
    for (final rule in rules) {
      final match = matchWrap(s, i, rule);
      if (match == null) continue;
      final (from, end, resume) = match;
      final inner = s.substring(from, end);
      // A run that crosses a blank line would straddle two block elements and
      // leave the span unbalanced, so leave it alone.
      if (inner.contains('\n\n')) continue;
      final body = rule.hideMarkers
          ? _wrapSource(inner, rules, depth + 1)
          : '${_escape(rule.start)}'
              '${_wrapSource(inner, rules, depth + 1)}'
              '${_escape(rule.end)}';
      // Single-quoted attribute on purpose. The quote-wrapping pass no longer
      // reads inside a tag, so this is belt and braces rather than load-bearing
      // — but a double-quoted attribute written into the *source*, before
      // markdown has run, is prose as far as that pass is concerned.
      out.write(rule.color == null
          ? body
          : "<span style='color: ${_cssColor(rule.color!)}'>$body</span>");
      i = resume;
      continue scan;
    }
    out.write(s[i]);
    i++;
  }
  return out.toString();
}

/// Markers are shown as typed, so `<` and `&` have to be escaped on the way
/// into the HTML.
String _escape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String _cssColor(int argb) =>
    '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

// --- font-family ------------------------------------------------------------

/// Desktop/web font names mapped onto the generic families the platform font
/// manager actually knows. Android ships `serif`, `sans-serif`, `monospace` and
/// `cursive` (fonts.xml); "Times New Roman" and friends exist on neither
/// Android nor iOS, so asking for them by name silently yields the default
/// font.
const Map<String, String> _genericFor = {
  // Serif
  'times new roman': 'serif', 'times': 'serif', 'georgia': 'serif',
  'garamond': 'serif', 'palatino': 'serif', 'palatino linotype': 'serif',
  'book antiqua': 'serif', 'baskerville': 'serif', 'cambria': 'serif',
  'constantia': 'serif', 'didot': 'serif', 'bodoni mt': 'serif',
  'noto serif': 'serif', 'droid serif': 'serif', 'pt serif': 'serif',
  'liberation serif': 'serif', 'dejavu serif': 'serif',
  'ms serif': 'serif', 'serif': 'serif', 'ui-serif': 'serif',
  // Sans-serif
  'arial': 'sans-serif', 'helvetica': 'sans-serif',
  'helvetica neue': 'sans-serif', 'verdana': 'sans-serif',
  'tahoma': 'sans-serif', 'trebuchet ms': 'sans-serif',
  'segoe ui': 'sans-serif', 'calibri': 'sans-serif',
  'candara': 'sans-serif', 'optima': 'sans-serif',
  'gill sans': 'sans-serif', 'futura': 'sans-serif',
  'century gothic': 'sans-serif', 'lucida grande': 'sans-serif',
  'noto sans': 'sans-serif', 'open sans': 'sans-serif',
  'liberation sans': 'sans-serif', 'dejavu sans': 'sans-serif',
  'sans-serif': 'sans-serif', 'ui-sans-serif': 'sans-serif',
  'system-ui': 'sans-serif', '-apple-system': 'sans-serif',
  'blinkmacsystemfont': 'sans-serif', 'roboto': 'sans-serif',
  // Monospace
  'courier new': 'monospace', 'courier': 'monospace',
  'consolas': 'monospace', 'monaco': 'monospace', 'menlo': 'monospace',
  'lucida console': 'monospace', 'dejavu sans mono': 'monospace',
  'liberation mono': 'monospace', 'sf mono': 'monospace',
  'source code pro': 'monospace', 'fira code': 'monospace',
  'monospace': 'monospace', 'ui-monospace': 'monospace',
  // Handwriting / display
  'comic sans ms': 'cursive', 'brush script mt': 'cursive',
  'segoe script': 'cursive', 'lucida handwriting': 'cursive',
  'cursive': 'cursive', 'fantasy': 'cursive',
};

final _styleAttr = RegExp(r'''style\s*=\s*(["'])(.*?)\1''',
    caseSensitive: false, dotAll: true);
final _fontFamilyDecl =
    RegExp(r'font-family\s*:\s*([^;]*)', caseSensitive: false);
final _faceAttr = RegExp(r'''(<font\b[^>]*?\bface\s*=\s*)(["'])(.*?)\2''',
    caseSensitive: false, dotAll: true);
final _outerQuotes = RegExp(r'''^\s*["']|["']\s*$''');

/// Rewrites every `font-family` in [html] to a family the device can resolve.
///
/// Two things make this necessary. Flutter can only use fonts the platform (or
/// the app bundle) provides, and `flutter_html` keeps just the *first* name in a
/// font stack — it never sets `fontFamilyFallback` — so `font-family: 'Times New
/// Roman', serif` asked for a font no phone has and threw away the `serif`
/// fallback that would have worked. We do the substitution the browser would
/// effectively end up doing: the first name that maps to a generic family wins,
/// and an unrecognised name is passed through (with its quotes stripped) in case
/// it really is installed.
String resolveFontFamilies(String html) {
  if (!html.contains('font')) return html;
  var out = html.replaceAllMapped(_styleAttr, (m) {
    final quote = m.group(1)!;
    final body = m.group(2)!;
    final rewritten = body.replaceAllMapped(_fontFamilyDecl, (decl) {
      final resolved = resolveFontFamilyList(decl.group(1)!);
      return resolved == null ? decl.group(0)! : 'font-family: $resolved';
    });
    return 'style=$quote$rewritten$quote';
  });
  out = out.replaceAllMapped(_faceAttr, (m) {
    final resolved = resolveFontFamilyList(m.group(3)!);
    return resolved == null
        ? m.group(0)!
        : '${m.group(1)}${m.group(2)}$resolved${m.group(2)}';
  });
  return out;
}

/// The family to actually ask for, given a CSS font stack, or null when the
/// stack is empty.
String? resolveFontFamilyList(String value) {
  final names = value
      .split(',')
      .map((n) => n.replaceAll(_outerQuotes, '').trim())
      .where((n) => n.isNotEmpty)
      .toList();
  if (names.isEmpty) return null;
  for (final name in names) {
    final generic = _genericFor[name.toLowerCase()];
    if (generic != null) return generic;
  }
  return names.first;
}

// --- taming model CSS --------------------------------------------------------

/// CSS properties `flutter_html` cannot render and that only make a mess if left
/// in: shadows, filters, transforms and the flexbox family. Dropped outright.
const Set<String> _dropProps = {
  'box-shadow', 'text-shadow', 'filter', 'backdrop-filter', 'transform',
  'transition', 'animation', 'font-variant', 'display', 'justify-content',
  'align-items', 'align-content', 'flex', 'flex-direction', 'flex-wrap',
  'gap', 'text-transform',
};

final _decl = RegExp(r'([-a-zA-Z]+)\s*:\s*([^;]+)');
final _fontSizeUnit = RegExp(r'([\d.]+)\s*(rem|em)\b', caseSensitive: false);

/// Rewrites the model's inline CSS into what `flutter_html` can actually draw,
/// so a "designed card" reads as a card instead of a big black slab.
///
/// Two things were breaking these messages. A model wraps its card in a
/// full-bleed centering `<div style="background:#0a0a0a; display:flex; …">`;
/// `flutter_html` has no flexbox, so the wrapper stayed a full-width near-black
/// band around a small, uncentred card — the reported "black section". And it
/// ignores `box-shadow`/`rem`/`text-transform`, so titles came out mis-sized and
/// un-styled. Here the backdrop's background is stripped (the inner card keeps
/// its own palette), `rem`/`em` sizes become px, unsupported props are dropped,
/// and `text-transform` is applied to the text directly.
String tameRichCss(String html) {
  if (!html.contains('style')) return html;
  final transformed = _applyTextTransform(html);
  return transformed.replaceAllMapped(_styleAttr, (m) {
    final quote = m.group(1)!;
    final body = m.group(2)!;
    final rewritten = _tameStyleBody(body);
    return rewritten.isEmpty ? '' : 'style=$quote$rewritten$quote';
  });
}

String _tameStyleBody(String body) {
  // A centering/backdrop wrapper: its whole job is flex layout, so its
  // background is the band we don't want. Inner cards (bordered / fixed width)
  // are not wrappers and keep their look.
  final lower = body.toLowerCase();
  final isWrapper = lower.contains('display') && lower.contains('flex') ||
      lower.contains('justify-content') ||
      lower.contains('align-items');

  final kept = <String>[];
  var centred = false;
  for (final decl in _decl.allMatches(body)) {
    final prop = decl.group(1)!.toLowerCase();
    var value = decl.group(2)!.trim();
    if (_dropProps.contains(prop)) continue;
    if (isWrapper && (prop == 'background' || prop == 'background-color')) {
      continue; // the band — drop it, the inner card keeps its own.
    }
    if (isWrapper && (prop == 'padding' || prop == 'margin')) {
      continue; // collapse the wrapper's spacing so it doesn't tower.
    }
    if (prop == 'font-size') {
      value = value.replaceAllMapped(_fontSizeUnit, (u) {
        final n = double.tryParse(u.group(1)!) ?? 1;
        return '${(n * 16).round()}px';
      });
    }
    kept.add('$prop: $value');
  }
  if (isWrapper) centred = true;
  if (centred) kept.add('text-align: center');
  return kept.join('; ');
}

/// `text-transform` has no effect in `flutter_html`, so apply it to the element's
/// own text. Handled for the common case of a leaf element whose content is
/// plain text (the card's title/label rows), which is all the models emit.
final _textTransformEl = RegExp(
  r'''<(div|span|p|h[1-6]|b|strong|em)\b([^>]*\bstyle\s*=\s*["'][^"'>]*text-transform\s*:\s*(uppercase|lowercase|capitalize)[^"'>]*["'][^>]*)>([^<]*)</\1>''',
  caseSensitive: false,
);

String _applyTextTransform(String html) {
  if (!html.toLowerCase().contains('text-transform')) return html;
  return html.replaceAllMapped(_textTransformEl, (m) {
    final tag = m.group(1)!;
    final attrs = m.group(2)!;
    final kind = m.group(3)!.toLowerCase();
    final text = m.group(4)!;
    return '<$tag$attrs>${_transformText(text, kind)}</$tag>';
  });
}

String _transformText(String text, String kind) {
  switch (kind) {
    case 'uppercase':
      return text.toUpperCase();
    case 'lowercase':
      return text.toLowerCase();
    case 'capitalize':
      return text.replaceAllMapped(
          RegExp(r'\b\w'), (m) => m.group(0)!.toUpperCase());
    default:
      return text;
  }
}
// APPEND-HTMLWIDGET

/// Renders [text] as HTML/CSS with the full engine. Honours inline `style=`,
/// tables, images, lists, links, etc., while base/emphasis/quote/code colours
/// and font size follow the Chat Interface settings.
///
/// The result is cached per (text, style): parsing markdown, then HTML, then
/// building the render tree is by far the most expensive thing a message can
/// do, and the chat rebuilds every visible turn on each streaming delta and
/// each scroll. Returning the *same* widget instance for unchanged input lets
/// Flutter skip the subtree entirely.
Widget buildMessageHtml(String text, HtmlMessageStyle s) =>
    MessageHtml(text: text, style: s);

class MessageHtml extends StatefulWidget {
  const MessageHtml({super.key, required this.text, required this.style});

  final String text;
  final HtmlMessageStyle style;

  @override
  State<MessageHtml> createState() => _MessageHtmlState();
}

/// Caps how many *expensive* flutter_html renders happen in a single frame,
/// across every message on screen. Opening a chat used to build a whole
/// screenful of HTML bubbles in one frame — a ~600ms UI-thread freeze on a real
/// device (measured). Spreading them over a few frames keeps any one frame off
/// the freeze cliff. Under light load — a single streaming message updating —
/// the budget is never reached, so that path is unchanged (no placeholder, no
/// flash, no extra frame).
class _HtmlFrameBudget {
  static const int _perFrame = 3;
  static int _left = _perFrame;
  static bool _hooked = false;

  // Reset the allowance at each frame boundary. A persistent frame callback runs
  // on every frame that happens but never *schedules* one, so this adds no idle
  // cost (unlike a game-loop). Registered once, lazily, the first time a budget
  // is requested.
  static void _hook() {
    if (_hooked) return;
    _hooked = true;
    SchedulerBinding.instance.addPersistentFrameCallback((_) {
      _left = _perFrame;
    });
  }

  static bool take() {
    _hook();
    if (_left <= 0) return false;
    _left--;
    return true;
  }
}

class _MessageHtmlState extends State<MessageHtml> {
  Widget? _built;
  String? _builtText;
  HtmlMessageStyle? _builtStyle;
  bool _scheduled = false;

  bool get _fresh =>
      _built != null &&
      _builtText == widget.text &&
      _builtStyle == widget.style;

  @override
  Widget build(BuildContext context) {
    if (_fresh) return _built!;
    if (_HtmlFrameBudget.take()) {
      JankLogger.instance.noteHtmlParse();
      _built = _html(widget.text, widget.style);
      _builtText = widget.text;
      _builtStyle = widget.style;
      return _built!;
    }
    // Over this frame's budget: try again next frame. Meanwhile show the last
    // rich render if there is one (so a streaming update never flashes), else a
    // cheap text stand-in that reserves roughly the right height.
    if (!_scheduled) {
      _scheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scheduled = false;
        if (mounted && !_fresh) setState(() {});
      });
    }
    return _built ??
        Text(
          widget.text,
          style: TextStyle(
            color: widget.style.base,
            fontSize: widget.style.fontSize,
            height: 1.35,
          ),
        );
  }
}

Widget _html(String text, HtmlMessageStyle s) {
  return Html(
    data: messageToHtml(text, wraps: s.wraps),
    onLinkTap: (url, _, _) => _open(url),
    // Every `<img>` — the model's own, a card's, a bare link that became one —
    // goes through the shared cache and decodes at the width it is drawn at.
    // The built-in renderer would fetch a 3000px photograph at full resolution
    // and squash it, which in a scrolling thread is both the memory and the
    // stutter. Capped shorter than a character sheet's: a picture inside a turn
    // must not be the whole screen.
    extensions: [inlineImageExtension(color: s.base, maxHeight: 320)],
    style: {
      'body': Style(
        margin: Margins.zero,
        padding: HtmlPaddings.zero,
        color: s.base,
        fontSize: FontSize(s.fontSize),
        lineHeight: LineHeight(1.35),
      ),
      'p': Style(margin: Margins.only(top: 0, bottom: 8)),
      'em': Style(color: s.emphasis, fontStyle: FontStyle.italic),
      'i': Style(color: s.emphasis),
      'q': Style(color: s.quote),
      'a': Style(color: s.link),
      'code': Style(
        backgroundColor: s.codeBackground,
        color: s.codeForeground,
        fontFamily: 'monospace',
      ),
      'pre': Style(
        backgroundColor: s.codeBackground,
        color: s.codeForeground,
        padding: HtmlPaddings.all(8),
        margin: Margins.symmetric(vertical: 6),
      ),
      'blockquote': Style(
        margin: Margins.only(left: 8),
        padding: HtmlPaddings.only(left: 10),
        border: Border(left: BorderSide(color: s.quote, width: 3)),
        color: s.quote,
      ),
      'table': Style(border: Border.all(color: s.base.withValues(alpha: 0.3))),
      'th': Style(padding: HtmlPaddings.all(4)),
      'td': Style(padding: HtmlPaddings.all(4)),
    },
  );
}

Future<void> _open(String? url) async {
  if (url == null) return;
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

