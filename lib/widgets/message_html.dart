import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

/// Colours + base size for the HTML renderer, mirroring the ChatInterface text
/// options so an HTML message matches a plain one.
class HtmlMessageStyle {
  const HtmlMessageStyle({
    required this.base,
    required this.emphasis,
    required this.quote,
    required this.codeBackground,
    required this.codeForeground,
    required this.link,
    required this.fontSize,
  });

  final Color base;
  final Color emphasis;
  final Color quote;
  final Color codeBackground;
  final Color codeForeground;
  final Color link;
  final double fontSize;

  @override
  bool operator ==(Object other) =>
      other is HtmlMessageStyle &&
      other.base == base &&
      other.emphasis == emphasis &&
      other.quote == quote &&
      other.codeBackground == codeBackground &&
      other.codeForeground == codeForeground &&
      other.link == link &&
      other.fontSize == fontSize;

  @override
  int get hashCode => Object.hash(
        base,
        emphasis,
        quote,
        codeBackground,
        codeForeground,
        link,
        fontSize,
      );
}

/// Whether [text] contains any HTML tag — the signal to route a message to the
/// full HTML+CSS engine instead of the lightweight inline renderer.
bool looksLikeHtml(String text) => _htmlTag.hasMatch(text);

final _htmlTag = RegExp(r'<(/?[a-zA-Z][a-zA-Z0-9]*)(\s[^<>]*)?/?>');
final _curlyQuotes = RegExp(r'[“”„‟]');
// A tag, a fenced/inline code run, or a "double-quoted" span (captured).
final _quoteSpan = RegExp(r'<[\s\S]*?>|```[\s\S]*?```|`[^`]*`|("[^"]+")');

/// Converts a message (markdown, possibly with inline/block HTML) to HTML, then
/// wraps straight-double-quoted spans in <q> so they can be tinted — mirroring
/// Agnaistic's showdown + quote-wrap pipeline.
String messageToHtml(String text) {
  final html = md.markdownToHtml(
    text,
    extensionSet: md.ExtensionSet.gitHubWeb,
  );
  final normalized =
      html.replaceAll(_curlyQuotes, '"').replaceAll('&quot;', '"');
  final quoted = normalized.replaceAllMapped(_quoteSpan, (m) {
    final quoted = m.group(1);
    if (quoted == null) return m.group(0)!;
    // Drop the surrounding quotes; <q> re-adds a single pair when rendered.
    return '<q>${quoted.substring(1, quoted.length - 1)}</q>';
  });
  return resolveFontFamilies(quoted);
}

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

class _MessageHtmlState extends State<MessageHtml> {
  Widget? _built;

  @override
  void didUpdateWidget(MessageHtml old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text || old.style != widget.style) _built = null;
  }

  @override
  Widget build(BuildContext context) =>
      _built ??= _html(widget.text, widget.style);
}

Widget _html(String text, HtmlMessageStyle s) {
  return Html(
    data: messageToHtml(text),
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

