import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/character.dart';
import '../models/chat_interface.dart';
import '../models/message.dart';
import 'character_avatar.dart';
import 'message_html.dart';
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
    this.userPersona,
    this.pending = false,
    this.interactive = false,
    this.onAvatarDrag,
    this.onAvatarResize,
    this.onLongPress,
    this.onAction,
    this.streaming = false,
  });

  final ChatMessage message;
  final ChatInterface ui;

  /// The bot's character, when the chat has one; null for a plain chat or the
  /// user's own turns.
  final Character? character;

  /// The character the user is impersonating, when any — drives the user turn's
  /// avatar picture and name label. Null when the user is speaking as themself.
  final Character? userPersona;

  final bool pending;

  final bool interactive;
  final ValueChanged<Offset>? onAvatarDrag;
  final ValueChanged<double>? onAvatarResize;

  /// Opens the per-message actions (edit/delete/fork/regenerate). Falls back to
  /// copy-on-long-press when not supplied (e.g. the preview).
  final VoidCallback? onLongPress;

  /// Dispatches an inline/overflow message action. Null in the settings preview
  /// (which passes [interactive]), where the action bar is suppressed.
  final void Function(MessageAction)? onAction;

  /// Whether a reply is currently streaming — disables mutating actions.
  final bool streaming;

  /// The message text with the identity macros resolved for display, so a
  /// greeting stored as "Hello {{user}}, I am {{char}}" shows the live names —
  /// and updates the instant the user starts impersonating. Mirrors the
  /// prompt-build resolution ([Character.resolveMacros] with the same names) so
  /// the screen and the model always agree on who "{{user}}" is.
  String get _displayContent => Character.resolveMacros(
        message.content,
        charName: character?.displayName ?? '',
        userName: userPersona?.displayName ?? 'User',
      );

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
    var avatar = style.show ? _avatar(context, isUser, style) : null;
    final crossAxis =
        side.isLeft ? CrossAxisAlignment.start : CrossAxisAlignment.end;

    // The action bar is suppressed for a still-streaming caret-only turn
    // (nothing to act on yet) and whenever no dispatcher is wired (the preview).
    final actionsBar = showCaret ? null : _actionsBar(context, isUser);
    var placement = ui.actionBarPlacement;
    // Fall back to below-message when the chosen anchor isn't available.
    if (placement == ActionBarPlacement.besideAvatar &&
        (avatar == null || ui.textPlacement == TextPlacement.around)) {
      placement = ActionBarPlacement.belowMessage;
    }
    // Beside-avatar: hang the bar under the avatar so it rides with it.
    if (actionsBar != null && placement == ActionBarPlacement.besideAvatar) {
      avatar = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: crossAxis,
        children: [avatar!, const SizedBox(height: 2), actionsBar],
      );
    }

    // Name label, optionally sharing its row with the action bar.
    Widget? nameW = ui.showNames ? _nameLabel(context, isUser) : null;
    if (actionsBar != null && placement == ActionBarPlacement.besideName) {
      nameW = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (nameW != null) ...[
            Flexible(child: nameW),
            const SizedBox(width: 4),
          ],
          actionsBar,
        ],
      );
    }
    final nameCross = _crossFor(isUser ? ui.userNameAlign : ui.botNameAlign);
    final namePosition = isUser ? ui.userNamePosition : ui.botNamePosition;

    // Stacks the sender name directly above/below [anchor] — the avatar when a
    // standalone one is shown, otherwise the bubble — aligned per the role's
    // setting.
    Widget stackName(Widget anchor) {
      if (nameW == null) return anchor;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: nameCross,
        children: namePosition == NamePosition.above
            ? [nameW, anchor]
            : [anchor, nameW],
      );
    }

    // The name rides with the avatar when there is a standalone one. With the
    // "around" placement the avatar is inline in the text, so the name falls
    // back to sitting with the bubble.
    final nameOnAvatar = avatar != null &&
        nameW != null &&
        ui.textPlacement != TextPlacement.around;
    final Widget? avatarUnit =
        avatar == null ? null : (nameOnAvatar ? stackName(avatar) : avatar);
    Widget bubbleUnit(Widget bubble) => nameOnAvatar ? bubble : stackName(bubble);
// APPEND-BUILD

    final Widget inner;
    switch (ui.textPlacement) {
      case TextPlacement.around:
        inner = bubbleUnit(_bubble(
            _text(scheme, textColor, showCaret, leading: avatar), bubbleColor));
      case TextPlacement.below:
        inner = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: crossAxis,
          children: [
            if (avatarUnit != null) ...[avatarUnit, const SizedBox(height: 6)],
            bubbleUnit(_bubble(_text(scheme, textColor, showCaret), bubbleColor)),
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
            if (avatarUnit != null) ...[avatarUnit, const SizedBox(width: 8)],
            Flexible(
              child: bubbleUnit(
                  _bubble(_text(scheme, textColor, showCaret), bubbleColor)),
            ),
          ],
        );
    }

    // Below / right placements wrap the assembled message; beside-name and
    // beside-avatar have already folded the bar into the name/avatar above.
    Widget body = inner;
    if (actionsBar != null && placement == ActionBarPlacement.belowMessage) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: crossAxis,
        children: [inner, actionsBar],
      );
    } else if (actionsBar != null &&
        placement == ActionBarPlacement.messageRight) {
      body = Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Flexible(child: inner),
          const SizedBox(width: 4),
          actionsBar,
        ],
      );
    }

    return Align(
      alignment: side.isLeft ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        constraints: BoxConstraints(
          maxWidth: ui.contentWidth.maxWidthFor(MediaQuery.sizeOf(context).width),
        ),
        child: GestureDetector(
          onLongPress: onLongPress ??
              (message.content.isEmpty
                  ? null
                  : () => _copy(context, _displayContent)),
          child: body,
        ),
      ),
    );
  }

  /// The inline/overflow action bar for this turn, or null when actions are
  /// disabled, undispatched (preview), or none apply to this role. Inline
  /// actions render as small icon buttons; the rest live behind a three-dot
  /// overflow menu — the split is configured in Chat Interface settings.
  Widget? _actionsBar(BuildContext context, bool isUser) {
    if (onAction == null || !ui.messageActionsEnabled) return null;
    final inline =
        ui.inlineActions.where((a) => a.appliesTo(isUser)).toList();
    final overflow =
        ui.overflowActions.where((a) => a.appliesTo(isUser)).toList();
    if (inline.isEmpty && overflow.isEmpty) return null;

    final scheme = Theme.of(context).colorScheme;
    final color = scheme.onSurfaceVariant;
    bool disabled(MessageAction a) => a.blockedWhileStreaming && streaming;

    return Padding(
      padding: const EdgeInsets.only(top: 1, left: 2, right: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final a in inline)
            IconButton(
              tooltip: a.label,
              iconSize: 17,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints:
                  const BoxConstraints(minWidth: 32, minHeight: 32),
              color: a == MessageAction.delete ? scheme.error : color,
              onPressed: disabled(a) ? null : () => onAction!(a),
              icon: Icon(a.icon),
            ),
          if (overflow.isNotEmpty)
            PopupMenuButton<MessageAction>(
              tooltip: 'More',
              icon: Icon(Icons.more_vert, size: 17, color: color),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              position: PopupMenuPosition.under,
              onSelected: (a) => onAction!(a),
              itemBuilder: (context) => [
                for (final a in overflow)
                  PopupMenuItem<MessageAction>(
                    value: a,
                    enabled: !disabled(a),
                    child: Row(
                      children: [
                        Icon(a.icon,
                            size: 18,
                            color:
                                a == MessageAction.delete ? scheme.error : null),
                        const SizedBox(width: 12),
                        Text(a.label),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// Maps a name's horizontal alignment onto the cross-axis of the column that
  /// stacks it with its anchor (avatar or bubble).
  static CrossAxisAlignment _crossFor(NameAlign a) => switch (a) {
        NameAlign.start => CrossAxisAlignment.start,
        NameAlign.center => CrossAxisAlignment.center,
        NameAlign.end => CrossAxisAlignment.end,
      };

  Widget _nameLabel(BuildContext context, bool isUser) {
    final name = isUser
        ? (userPersona?.displayName ??
            (ui.userName.trim().isEmpty ? 'You' : ui.userName.trim()))
        : (character?.displayName ?? 'Assistant');
    final size = isUser ? ui.userNameSize : ui.botNameSize;
    final align = isUser ? ui.userNameAlign : ui.botNameAlign;
    return Padding(
      padding: const EdgeInsets.only(left: 2, right: 2, bottom: 2),
      child: Text(
        name,
        textAlign: align.textAlign,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontSize: size,
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
    } else if (isUser && userPersona != null) {
      // The user is impersonating a character: wear that persona's picture.
      base = CharacterAvatar(
        character: userPersona!,
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
      final spinner = SizedBox(
        height: 16,
        width: 16,
        child: CircularProgressIndicator(strokeWidth: 2, color: color),
      );
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        // Keep the avatar visible while streaming in the "around" placement.
        child: leading == null
            ? spinner
            : Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  leading,
                  const SizedBox(width: 10),
                  spinner,
                ],
              ),
      );
    }
    final style = TextStyle(color: color, fontSize: ui.fontSize, height: 1.35);
    final content = _displayContent;

    // Full HTML + CSS engine for any message that actually contains HTML.
    if (ui.markdown && content.isNotEmpty && looksLikeHtml(content)) {
      final html = SelectionArea(
        child: buildMessageHtml(
          content,
          HtmlMessageStyle(
            base: color,
            emphasis:
                ui.emphasisColor != null ? Color(ui.emphasisColor!) : color,
            quote: ui.quoteColor != null ? Color(ui.quoteColor!) : color,
            codeBackground: scheme.surfaceContainerLowest,
            codeForeground: scheme.onSurface,
            link: scheme.primary,
            fontSize: ui.fontSize,
          ),
        ),
      );
      // The "around" float isn't possible with block HTML; sit the avatar
      // beside it instead.
      if (leading == null) return html;
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [leading, const SizedBox(width: 10), Flexible(child: html)],
      );
    }

    // Lightweight, selectable inline renderer (markdown/quotes/emphasis).
    final List<InlineSpan> spans;
    if (ui.markdown && content.isNotEmpty) {
      spans = buildMessageSpans(
        content,
        MarkdownStyles(
          base: style,
          emphasis: ui.emphasisColor != null ? Color(ui.emphasisColor!) : color,
          quote: ui.quoteColor != null ? Color(ui.quoteColor!) : color,
          // A neutral inset so code stands out from any bubble/background
          // (the default bot bubble is itself surfaceContainerHighest).
          codeBackground: scheme.surfaceContainerLowest,
          codeForeground: scheme.onSurface,
          link: scheme.primary,
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


