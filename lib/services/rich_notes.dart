import 'package:markdown/markdown.dart' as md;

/// Turns a creator's notes into HTML `flutter_html` can actually draw, keeping
/// the design they wrote rather than flattening it.
///
/// This is deliberately **not** the chat's [tameRichCss]. A chat message that
/// arrives wrapped in a full-bleed dark `<div>` is a model padding its answer,
/// so there the wrapper's background is stripped. Creator notes are the opposite
/// case: the card *is* the content — sites like JannyAI ship a styled block and
/// the styling is what the creator wanted shown. So backgrounds, borders,
/// padding and colours are kept, and only what the renderer cannot draw (or
/// would draw destructively) is rewritten.
///
/// Everything here is a string pass over the source, run once per distinct notes
/// text and cached by the caller — no work on rebuild, no work on scroll.

/// Tags that are dropped outright rather than rendered.
///
/// `script`/`iframe`/`object`/`embed`/`link`/`meta` are the ones that would try
/// to run or fetch something; `video`/`audio`/`canvas`/`svg`/`form`/`input`/
/// `button` are simply not renderable here and leave debris (a stray control, a
/// blank gap) when left in. Handed to `Html(doNotRenderTheseTags:)` as well, so
/// anything that survives the string pass is still not built.
const Set<String> kDroppedNoteTags = {
  'script', 'iframe', 'object', 'embed', 'link', 'meta', 'base', 'noscript',
  'video', 'audio', 'canvas', 'svg', 'form', 'input', 'button', 'select',
  'textarea', 'applet', 'frame', 'frameset',
};

/// CSS properties `flutter_html` cannot draw. Left in they either do nothing
/// (a wasted parse per element) or actively break the layout — `position` and
/// the flex/grid family are the destructive ones, because an element laid out on
/// the assumption it will be positioned ends up stacked in the flow instead.
const Set<String> kDroppedNoteProps = {
  'box-shadow', 'filter', 'backdrop-filter', 'transform', 'transform-origin',
  'transition', 'animation', 'will-change', 'position', 'top', 'right',
  'bottom', 'left', 'z-index', 'float', 'clear', 'overflow', 'overflow-x',
  'overflow-y', 'justify-content', 'align-items', 'align-content', 'align-self',
  'flex', 'flex-direction', 'flex-wrap', 'flex-grow', 'flex-shrink',
  'flex-basis', 'order', 'gap', 'row-gap', 'column-gap', 'grid',
  'grid-template', 'grid-template-columns', 'grid-template-rows', 'grid-area',
  'grid-column', 'grid-row', 'grid-gap', 'columns', 'column-count',
  'cursor', 'user-select', 'pointer-events', 'content',
  'box-sizing', 'max-height', 'min-height', 'aspect-ratio', 'object-fit',
  'backface-visibility', 'perspective', 'mix-blend-mode', 'isolation',
  'clip-path', 'mask', 'resize', 'outline', 'outline-offset',
};

final _tagRun = RegExp(r'<\s*(/?)\s*([a-zA-Z][a-zA-Z0-9-]*)\b[^>]*>');
final _styleAttr =
    RegExp(r'''style\s*=\s*(["'])(.*?)\1''', caseSensitive: false, dotAll: true);
final _styleBlock = RegExp(r'(<style\b[^>]*>)([\s\S]*?)(</style\s*>)',
    caseSensitive: false);
final _declaration = RegExp(r'([-a-zA-Z]+)\s*:\s*([^;]+)');
final _remLength = RegExp(r'([\d.]+)\s*rem\b', caseSensitive: false);
final _firstHexOrRgb = RegExp(
    r'#[0-9a-fA-F]{3,8}|rgba?\([^)]*\)|hsla?\([^)]*\)',
    caseSensitive: false);

/// A colour keyword that can stand alone as a `background:` value, so the
/// shorthand can be narrowed to `background-color` without guessing.
final _bareColorWord = RegExp(r'^[a-zA-Z]+$');

/// Notes long enough that parsing and laying them out is worth deferring. Real
/// creator notes are a few kilobytes; a pathological card can carry a hundred,
/// and building that in one frame is a visible stall.
const int kNotesRenderCap = 8000;

/// Whether [notes] carry markup worth handing to the full HTML engine. Plain
/// prose (the common case) takes the cheap path instead and never pays for a
/// DOM.
bool notesLookRich(String notes) => _richMarkup.hasMatch(notes);

final _richMarkup = RegExp(
    r'<(div|span|p|br|h[1-6]|img|table|tr|td|th|ul|ol|li|b|i|u|s|em|strong|'
    r'style|center|font|hr|blockquote|code|pre|details|summary|small|mark|'
    r'sub|sup|a)\b',
    caseSensitive: false);

/// Converts creator notes to the HTML the notes view renders.
///
/// Markdown is honoured first (many cards are written in it), then the tag and
/// CSS passes run over the result. Pure and deterministic, so the caller can
/// cache by input.
String creatorNotesToHtml(String notes) {
  final source = notes.trim();
  if (source.isEmpty) return '';
  final html = md.markdownToHtml(
    source,
    extensionSet: md.ExtensionSet.gitHubWeb,
  );
  return tameNoteCss(dropUnrenderableTags(html));
}

/// Removes every [kDroppedNoteTags] element's tags, and the whole body of the
/// ones whose content would otherwise be dumped as text (a `<script>`'s source,
/// a `<style>`'s CSS is kept — the renderer reads it).
String dropUnrenderableTags(String html) {
  if (!html.contains('<')) return html;
  // Paired content-bearing tags go first, body and all.
  var out = html;
  for (final tag in const ['script', 'noscript', 'iframe', 'object', 'form']) {
    out = out.replaceAll(
      RegExp('<$tag\\b[^>]*>[\\s\\S]*?</$tag\\s*>', caseSensitive: false),
      '',
    );
  }
  // Then any remaining opening/closing/self-closing tag from the set.
  return out.replaceAllMapped(_tagRun, (m) {
    final name = m.group(2)!.toLowerCase();
    return kDroppedNoteTags.contains(name) ? '' : m.group(0)!;
  });
}

/// Rewrites the CSS in [html] — both `style=` attributes and `<style>` blocks —
/// into declarations `flutter_html` can draw.
String tameNoteCss(String html) {
  if (!html.contains('style') && !html.contains('=')) return html;
  var out = html.replaceAllMapped(_styleBlock, (m) {
    return '${m.group(1)}${_tameStyleSheet(m.group(2)!)}${m.group(3)}';
  });
  out = out.replaceAllMapped(_styleAttr, (m) {
    final quote = m.group(1)!;
    final tamed = tameDeclarations(m.group(2)!);
    return tamed.isEmpty ? '' : 'style=$quote$tamed$quote';
  });
  return out;
}

/// Runs [tameDeclarations] over every rule body in a stylesheet, leaving the
/// selectors and at-rule structure alone.
String _tameStyleSheet(String css) {
  final out = StringBuffer();
  var i = 0;
  while (i < css.length) {
    final open = css.indexOf('{', i);
    if (open < 0) {
      out.write(css.substring(i));
      break;
    }
    final close = css.indexOf('}', open);
    if (close < 0) {
      out.write(css.substring(i));
      break;
    }
    out
      ..write(css.substring(i, open + 1))
      ..write(tameDeclarations(css.substring(open + 1, close)))
      ..write('}');
    i = close + 1;
  }
  return out.toString();
}

/// The declaration-level rewrite: drop what cannot be drawn, narrow the
/// shorthands that can, and convert the units the parser does not read.
String tameDeclarations(String body) {
  final kept = <String>[];
  for (final match in _declaration.allMatches(body)) {
    final prop = match.group(1)!.toLowerCase();
    var value = match.group(2)!.trim();
    if (value.isEmpty) continue;
    if (kDroppedNoteProps.contains(prop)) continue;

    // `display: flex|grid|inline-flex` would fall through to `inline` and stack
    // the children into a paragraph. Block is what the author actually meant
    // visually in almost every card: a stacked group of rows.
    if (prop == 'display') {
      final v = value.toLowerCase();
      if (v.contains('flex') || v.contains('grid') || v.contains('table')) {
        kept.add('display: block');
        continue;
      }
    }

    // Only `background-color` is read, so narrow the shorthand. A gradient or an
    // image keeps its first colour rather than vanishing to the page default.
    if (prop == 'background') {
      final colour = _firstHexOrRgb.firstMatch(value)?.group(0) ??
          (_bareColorWord.hasMatch(value) ? value : null);
      if (colour == null) continue;
      kept.add('background-color: $colour');
      continue;
    }

    // `rem` is not parsed at all (it reads as null and the declaration is
    // discarded), so a card sized entirely in rem came out at default size.
    // 16px per rem is the browser default the authors were looking at.
    if (value.toLowerCase().contains('rem')) {
      value = value.replaceAllMapped(_remLength, (m) {
        final n = double.tryParse(m.group(1)!) ?? 1;
        return '${(n * 16).round()}px';
      });
    }

    kept.add('$prop: $value');
  }
  return kept.join('; ');
}
