import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../models/text_wrap.dart';
import '../services/jank_logger.dart';

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

final _htmlTag = RegExp(r'<(/?[a-zA-Z][a-zA-Z0-9]*)(\s[^<>]*)?/?>');
final _curlyQuotes = RegExp(r'[“”„‟]');
// A tag, a fenced/inline code run, or a "double-quoted" span (captured).
final _quoteSpan = RegExp(r'<[\s\S]*?>|```[\s\S]*?```|`[^`]*`|("[^"]+")');

/// Converts a message (markdown, possibly with inline/block HTML) to HTML,
/// applying the user's [wraps] to the source first, then wrapping
/// straight-double-quoted spans in <q> so they can be tinted — mirroring
/// Agnaistic's showdown + quote-wrap pipeline.
///
/// The quote marks stay inside the `<q>`: a browser draws them itself from
/// `q::before`/`::after`, but flutter_html has no generated content, so dropping
/// them here made every quoted run lose its quotes.
String messageToHtml(String text, {List<TextWrapRule> wraps = const []}) {
  final html = md.markdownToHtml(
    applyWrapRules(text, wraps),
    extensionSet: md.ExtensionSet.gitHubWeb,
  );
  final normalized =
      html.replaceAll(_curlyQuotes, '"').replaceAll('&quot;', '"');
  final quoted = normalized.replaceAllMapped(_quoteSpan, (m) {
    final quoted = m.group(1);
    if (quoted == null) return m.group(0)!;
    return '<q>$quoted</q>';
  });
  return resolveFontFamilies(quoted);
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
      // Single-quoted attribute on purpose: the quote-wrapping pass below scans
      // for double-quoted runs, and a double-quoted attribute here would look
      // like one.
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

