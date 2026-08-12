import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/character.dart';
import '../models/chat_interface.dart';
import '../models/message.dart';
import 'character_avatar.dart';
import 'message_markdown.dart';

/// One chat turn, drawn per the current [ChatInterface]: each role's own avatar
/// (size/shape/fit/offset and which side it sits on), where the text sits
/// relative to the avatar, bubble-vs-document, an optional sender name, font
/// size and colour overrides.
///
/// The preview passes [interactive] with [onAvatarDrag]/[onAvatarResize] so the
/// mock chat can be tuned by dragging each avatar and its resize handle; the
/// callbacks are role-agnostic (the caller knows which role this turn is).
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.ui,
    this.character,
    this.pending = false,
    this.interactive = false,
    this.onAvatarDrag,
    this.onAvatarResize,
    this.onLongPress,
  });

  final ChatMessage message;
  final ChatInterface ui;

  /// The bot's character, when the chat has one; null for a plain chat or the
  /// user's own turns.
  final Character? character;

  final bool pending;

  final bool interactive;
  final ValueChanged<Offset>? onAvatarDrag;
  final ValueChanged<double>? onAvatarResize;

  /// Opens the per-message actions (edit/delete/fork/regenerate). Falls back to
  /// copy-on-long-press when not supplied (e.g. the preview).
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isUser = message.isUser;
    final style = ui.avatarFor(isUser);
    final side = style.side;

    final Color bubbleColor;
    final Color textColor;
    if (message.error) {
      bubbleColor = scheme.errorContainer;
      textColor = scheme.onErrorContainer;
    } else if (isUser) {
      bubbleColor = ui.userBubbleColor != null
          ? Color(ui.userBubbleColor!)
          : scheme.primaryContainer;
      textColor = ui.userTextColor != null
          ? Color(ui.userTextColor!)
          : scheme.onPrimaryContainer;
    } else {
      bubbleColor = ui.botBubbleColor != null
          ? Color(ui.botBubbleColor!)
          : scheme.surfaceContainerHighest;
      textColor =
          ui.botTextColor != null ? Color(ui.botTextColor!) : scheme.onSurface;
    }

    final showCaret = pending && message.content.isEmpty;
    final avatar = style.show ? _avatar(context, isUser, style) : null;
    final crossAxis =
        side.isLeft ? CrossAxisAlignment.start : CrossAxisAlignment.end;

    // Name + bubble stack for the text side.
    Widget contentColumn(Widget body) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: crossAxis,
          children: [
            if (ui.showNames) _nameLabel(context, isUser),
            body,
          ],
        );
// APPEND-BUILD

    final Widget inner;
    switch (ui.textPlacement) {
      case TextPlacement.around:
        inner = contentColumn(
          _bubble(
              _text(scheme, textColor, showCaret, leading: avatar), bubbleColor),
        );
      case TextPlacement.below:
        inner = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: crossAxis,
          children: [
            if (avatar != null) ...[avatar, const SizedBox(height: 6)],
            contentColumn(
                _bubble(_text(scheme, textColor, showCaret), bubbleColor)),
          ],
        );
      case TextPlacement.beside:
        inner = Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          // Lay the avatar on this role's side; the text keeps the ambient
          // (LTR) direction.
          textDirection: side.isLeft ? TextDirection.ltr : TextDirection.rtl,
          children: [
            if (avatar != null) ...[avatar, const SizedBox(width: 8)],
            Flexible(
              child: contentColumn(
                _bubble(_text(scheme, textColor, showCaret), bubbleColor),
              ),
            ),
          ],
        );
    }

    return Align(
      alignment: side.isLeft ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.85,
        ),
        child: GestureDetector(
          onLongPress: onLongPress ??
              (message.content.isEmpty
                  ? null
                  : () => _copy(context, message.content)),
          child: inner,
        ),
      ),
    );
  }

  Widget _nameLabel(BuildContext context, bool isUser) {
    final name = isUser
        ? (ui.userName.trim().isEmpty ? 'You' : ui.userName.trim())
        : (character?.displayName ?? 'Assistant');
    return Padding(
      padding: const EdgeInsets.only(left: 2, right: 2, bottom: 2),
      child: Text(
        name,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
// APPEND-HELPERS

  /// This role's avatar: the character's picture for a bot turn that has one,
  /// otherwise a generic person/bot glyph. In [interactive] mode it wears a
  /// frame and a corner handle so the preview can drag and resize it.
  Widget _avatar(BuildContext context, bool isUser, AvatarStyle style) {
    final size = style.size;
    final Widget base;
    if (!isUser && character != null) {
      base = CharacterAvatar(
        character: character!,
        size: size,
        shape: style.shape,
        fit: style.fit,
      );
    } else {
      base = _GenericAvatar(
        size: size,
        shape: style.shape,
        icon: isUser ? Icons.person : Icons.smart_toy_outlined,
      );
    }

    if (!interactive) {
      return Transform.translate(offset: style.offset, child: base);
    }

    final scheme = Theme.of(context).colorScheme;
    return Transform.translate(
      offset: style.offset,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 22, bottom: 22),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (d) => onAvatarDrag?.call(d.delta),
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.primary, width: 2),
                  borderRadius:
                      BorderRadius.circular(style.shape.radiusFor(size)),
                ),
                child: base,
              ),
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (d) =>
                  onAvatarResize?.call((d.delta.dx + d.delta.dy) / 2),
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.onPrimary, width: 2),
                ),
                child: Icon(Icons.open_in_full,
                    size: 10, color: scheme.onPrimary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The message body: a spinner while a caret-only turn is still streaming,
  /// otherwise selectable text rendered as markdown (when enabled). When
  /// [leading] is set (the "around" placement) the avatar is dropped inline so
  /// the text wraps around it.
  Widget _text(ColorScheme scheme, Color color, bool showCaret,
      {Widget? leading}) {
    if (showCaret) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: SizedBox(
          height: 16,
          width: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: color),
        ),
      );
    }
    final style = TextStyle(color: color, fontSize: ui.fontSize, height: 1.35);
    final content = message.content;
    final List<InlineSpan> spans;
    if (ui.markdown && content.isNotEmpty) {
      spans = buildMessageSpans(
        content,
        MarkdownStyles(
          base: style,
          emphasis: ui.emphasisColor != null ? Color(ui.emphasisColor!) : color,
          quote: ui.quoteColor != null ? Color(ui.quoteColor!) : color,
          codeBackground: scheme.surfaceContainerHighest,
          codeForeground: color,
        ),
      );
    } else {
      spans = [TextSpan(text: content, style: style)];
    }
    return SelectableText.rich(
      TextSpan(
        style: style,
        children: [
          if (leading != null)
            WidgetSpan(
              alignment: PlaceholderAlignment.top,
              child: Padding(
                padding: const EdgeInsets.only(right: 10, bottom: 4),
                child: leading,
              ),
            ),
          ...spans,
        ],
      ),
    );
  }

  /// Wraps [child] in a tinted bubble, or leaves it flat ("document") when
  /// bubbles are off.
  Widget _bubble(Widget child, Color color) {
    if (!ui.bubbles) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
        child: child,
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: ui.bubbleOpacity.clamp(0, 1)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }

  void _copy(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)),
    );
  }
}

/// A stand-in avatar for the user's turns (and bot turns in a character-less
/// chat): a glyph on the same tinted, shape-matched frame the picture avatars
/// use, so both sides of the conversation read consistently.
class _GenericAvatar extends StatelessWidget {
  const _GenericAvatar({
    required this.size,
    required this.shape,
    required this.icon,
  });

  final double size;
  final AvatarShape shape;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(shape.radiusFor(size)),
      child: Container(
        width: size,
        height: size,
        color: scheme.secondaryContainer,
        alignment: Alignment.center,
        child: Icon(icon, size: size * 0.55, color: scheme.onSecondaryContainer),
      ),
    );
  }
}


