import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/rich_notes.dart';
import 'avatar_image.dart';

/// Renders a creator's notes: their HTML and CSS as they designed it, images
/// included, without letting a hostile or careless card stall the page.
///
/// Four things keep this cheap, which matters because notes sit in a scrolling
/// page and a rebuild must cost nothing:
///
/// * the HTML string is produced once per distinct notes text and memoised;
/// * the built widget subtree is held and returned unchanged on rebuild, so the
///   DOM is parsed once per mount and never on scroll;
/// * the first build is deferred by a frame when the notes are large, so pushing
///   the page animates at full rate and the notes appear immediately after;
/// * remote images decode at the width they are drawn at through the shared
///   avatar-image cache, so the same picture is fetched and decoded once.
class RichNotes extends StatefulWidget {
  const RichNotes({
    super.key,
    required this.notes,
    required this.baseColor,
    required this.linkColor,
    required this.fontSize,
  });

  final String notes;
  final Color baseColor;
  final Color linkColor;
  final double fontSize;

  @override
  State<RichNotes> createState() => _RichNotesState();
}

class _RichNotesState extends State<RichNotes> {
  /// Converted HTML by source text — shared across every instance, because the
  /// same card is opened over and over.
  static final Map<String, String> _htmlCache = <String, String>{};

  /// Cap on [_htmlCache]; notes are small, but a long session sees many cards.
  static const int _htmlCacheMax = 24;

  String? _html;
  Widget? _built;
  String? _builtFor;
  bool _deferred = false;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(RichNotes old) {
    super.didUpdateWidget(old);
    if (old.notes != widget.notes) {
      _html = null;
      _built = null;
      _builtFor = null;
      _deferred = false;
      _prepare();
    }
  }

  void _prepare() {
    final source = widget.notes;
    final cached = _htmlCache[source];
    if (cached != null) {
      _html = cached;
      return;
    }
    // Large notes: convert after this frame so the page's own push animation is
    // never the thing that drops frames. Small ones convert inline — deferring
    // them would only add a flash.
    if (source.length > kNotesRenderCap) {
      _deferred = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _html = _convert(source);
          _deferred = false;
        });
      });
      return;
    }
    _html = _convert(source);
  }

  static String _convert(String source) {
    final html = creatorNotesToHtml(source);
    if (_htmlCache.length >= _htmlCacheMax) {
      _htmlCache.remove(_htmlCache.keys.first);
    }
    _htmlCache[source] = html;
    return html;
  }

  @override
  Widget build(BuildContext context) {
    final html = _html;
    if (html == null) {
      // Still converting: hold the space with the raw text so the page does not
      // jump when the rich version lands.
      return Opacity(
        opacity: _deferred ? 0.6 : 1,
        child: Text(
          widget.notes,
          maxLines: 12,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: widget.baseColor, fontSize: widget.fontSize),
        ),
      );
    }
    if (_built != null && _builtFor == html) return _built!;
    _builtFor = html;
    _built = _render(html);
    return _built!;
  }

  Widget _render(String html) => Html(
        data: html,
        onLinkTap: (url, _, _) => _open(url),
        // Belt and braces: the string pass already removed these, but a tag
        // reconstructed by the HTML parser's error recovery must not build.
        doNotRenderTheseTags: kDroppedNoteTags,
        extensions: [
          ImageExtension(
            builder: (context) => _NoteImage(
              src: context.attributes['src'] ?? '',
              alt: context.attributes['alt'] ?? '',
              declaredWidth:
                  double.tryParse(context.attributes['width'] ?? ''),
              color: widget.baseColor,
            ),
          ),
        ],
        style: {
          'body': Style(
            margin: Margins.zero,
            padding: HtmlPaddings.zero,
            color: widget.baseColor,
            fontSize: FontSize(widget.fontSize),
            lineHeight: LineHeight(1.4),
          ),
          'p': Style(margin: Margins.only(top: 0, bottom: 8)),
          'a': Style(color: widget.linkColor),
          'hr': Style(
            margin: Margins.symmetric(vertical: 10),
            border: Border(
              bottom: BorderSide(
                color: widget.baseColor.withValues(alpha: 0.2),
              ),
            ),
          ),
          // A creator's table is usually a stat block; give it visible cells
          // without overriding any colour they set.
          'table': Style(
            border: Border.all(color: widget.baseColor.withValues(alpha: 0.25)),
          ),
          'th': Style(padding: HtmlPaddings.all(6)),
          'td': Style(padding: HtmlPaddings.all(6)),
        },
      );
}

/// One `<img>` from the notes, drawn through the shared cache and bounded.
///
/// The built-in renderer uses `Image.network` at source resolution with
/// `BoxFit.fill`: a 3000px banner then decodes to ~36 MB and is squashed to
/// whatever box CSS asked for. Here the picture goes through [avatarImage], so it
/// decodes near the width it is drawn at and the same URL anywhere in the app is
/// one cache entry, and it keeps its aspect ratio.
class _NoteImage extends StatelessWidget {
  const _NoteImage({
    required this.src,
    required this.alt,
    required this.declaredWidth,
    required this.color,
  });

  final String src;
  final String alt;

  /// The `width=` attribute, when the card gave one.
  final double? declaredWidth;

  final Color color;

  /// Cap on a note image's height, so one tall picture cannot push the rest of
  /// the sheet off the screen.
  static const double _maxHeight = 420;

  @override
  Widget build(BuildContext context) {
    if (src.trim().isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final available =
            constraints.maxWidth.isFinite && constraints.maxWidth > 0
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width;
        final width = declaredWidth == null
            ? available
            : (declaredWidth! < available ? declaredWidth! : available);
        final provider = avatarImage(
          src,
          displaySize: width,
          devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
        );
        if (provider == null) return _altText();
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width, maxHeight: _maxHeight),
          child: Image(
            image: provider,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _altText(),
            // A picture that never arrives must not leave a collapsed line: hold
            // a slim band until it does.
            frameBuilder: (_, child, frame, wasSync) => frame == null && !wasSync
                ? SizedBox(width: width, height: 2)
                : child,
          ),
        );
      },
    );
  }

  Widget _altText() => alt.trim().isEmpty
      ? const SizedBox.shrink()
      : Text(alt, style: TextStyle(color: color.withValues(alpha: 0.7)));
}

Future<void> _open(String? url) async {
  if (url == null) return;
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
