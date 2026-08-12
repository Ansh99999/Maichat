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
  return normalized.replaceAllMapped(_quoteSpan, (m) {
    final quoted = m.group(1);
    if (quoted == null) return m.group(0)!;
    // Drop the surrounding quotes; <q> re-adds a single pair when rendered.
    return '<q>${quoted.substring(1, quoted.length - 1)}</q>';
  });
}
// APPEND-HTMLWIDGET

/// Renders [text] as HTML/CSS with the full engine. Honours inline `style=`,
/// tables, images, lists, links, etc., while base/emphasis/quote/code colours
/// and font size follow the Chat Interface settings.
Widget buildMessageHtml(String text, HtmlMessageStyle s) {
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

