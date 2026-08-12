import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/character.dart';
import '../models/chat_interface.dart';
import '../models/message.dart';
import 'character_avatar.dart';

/// One chat turn, drawn according to the current [ChatInterface] settings:
/// avatar size/shape/fit and offset, where the text sits relative to the avatar
/// (beside / below / around), bubble-vs-flat, font size and colour overrides.
///
/// The preview passes [interactive] with [onAvatarDrag]/[onAvatarResize] so the
/// mock chat can be tuned by dragging the avatar and its resize handle.
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
  });

  final ChatMessage message;
  final ChatInterface ui;

  /// The bot's character, when the chat has one; null for a plain chat or the
  /// user's own turns.
  final Character? character;

  /// True while this turn is still being streamed into.
  final bool pending;

  /// When set, the avatar shows a frame + resize handle and reports drags.
  final bool interactive;
  final ValueChanged<Offset>? onAvatarDrag;
  final ValueChanged<double>? onAvatarResize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isUser = message.isUser;

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
    final avatar = ui.showAvatars ? _avatar(context, isUser) : null;

    final Widget inner;
    switch (ui.textPlacement) {
      case TextPlacement.around:
        inner = _bubble(
          _text(textColor, showCaret, leading: avatar),
          bubbleColor,
        );
      case TextPlacement.below:
        inner = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment:
              isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (avatar != null) ...[avatar, const SizedBox(height: 6)],
            _bubble(_text(textColor, showCaret), bubbleColor),
          ],
        );
      case TextPlacement.beside:
        inner = Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          // Flip the row for the user so their avatar sits on the right; the
          // text itself keeps the ambient (LTR) direction.
          textDirection: isUser ? TextDirection.rtl : TextDirection.ltr,
          children: [
            if (avatar != null) ...[avatar, const SizedBox(width: 8)],
            Flexible(child: _bubble(_text(textColor, showCaret), bubbleColor)),
          ],
        );
    }

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.85,
        ),
        child: GestureDetector(
          onLongPress: message.content.isEmpty
              ? null
              : () => _copy(context, message.content),
          child: inner,
        ),
      ),
    );
  }

  /// The avatar for this turn: the character's picture for a bot turn that has
  /// one, otherwise a generic person/bot glyph. In [interactive] mode it wears
  /// a frame and a corner handle so the preview can be dragged and resized.
  Widget _avatar(BuildContext context, bool isUser) {
    final size = ui.avatarSize;
    final Widget base;
    if (!isUser && character != null) {
      base = CharacterAvatar(
        character: character!,
        size: size,
        shape: ui.avatarShape,
        fit: ui.avatarFit,
      );
    } else {
      base = _GenericAvatar(
        size: size,
        shape: ui.avatarShape,
        icon: isUser ? Icons.person : Icons.smart_toy_outlined,
      );
    }

    if (!interactive) {
      return Transform.translate(offset: ui.avatarOffset, child: base);
    }

    final scheme = Theme.of(context).colorScheme;
    return Transform.translate(
      offset: ui.avatarOffset,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Reserve room for the handle so it stays inside the Stack's bounds
          // (and hit-testable) without overlapping the drag-to-move area.
          Padding(
            padding: const EdgeInsets.only(right: 22, bottom: 22),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (d) => onAvatarDrag?.call(d.delta),
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.primary, width: 2),
                  borderRadius:
                      BorderRadius.circular(ui.avatarShape.radiusFor(size)),
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
  /// otherwise selectable text. When [leading] is set (the "around" placement)
  /// the avatar is dropped inline so the text wraps around it.
  Widget _text(Color color, bool showCaret, {Widget? leading}) {
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
    if (leading != null) {
      return SelectableText.rich(
        TextSpan(
          style: style,
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.top,
              child: Padding(
                padding: const EdgeInsets.only(right: 10, bottom: 4),
                child: leading,
              ),
            ),
            TextSpan(text: message.content),
          ],
        ),
      );
    }
    return SelectableText(message.content, style: style);
  }

  /// Wraps [child] in a tinted bubble, or leaves it flat when bubbles are off.
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


