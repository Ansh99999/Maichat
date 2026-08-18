import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/character.dart';
import '../models/chat_interface.dart';
import '../models/message.dart';
import 'character_avatar.dart';
import 'message_html.dart';
import 'message_markdown.dart';
import 'thinking_block.dart';

/// One chat turn, drawn per the current [ChatInterface]: each role's own avatar
/// (size/shape/corner rounding/fit/offset and which side it sits on), where the
/// text sits relative to the avatar, bubble-vs-document, an optional sender name
/// (its own size, font, placement and nudge), font size and colour overrides.
///
/// The preview passes [interactive] with [onAvatarDrag]/[onAvatarResize]/
/// [onNameDrag] so the mock chat can be tuned by dragging each avatar, its
/// resize handle and each name label; the callbacks are role-agnostic (the
/// caller knows which role this turn is).
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
    this.onNameDrag,
    this.onLongPress,
    this.onAction,
    this.onSwipe,
    this.onAvatarTap,
    this.avatarOverride,
    this.userAvatarOverride,
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

  /// Reports a drag of this turn's name label (preview only), so the name can be
  /// pulled towards — or away from — the message body it labels.
  final ValueChanged<Offset>? onNameDrag;

  /// Opens the per-message actions (edit/delete/fork/regenerate). Falls back to
  /// copy-on-long-press when not supplied (e.g. the preview).
  final VoidCallback? onLongPress;

  /// Dispatches an inline/overflow message action. Null in the settings preview
  /// (which passes [interactive]), where the action bar is suppressed.
  final void Function(MessageAction)? onAction;

  /// Selects one of this turn's swipes by index — wired to the ‹ 1/2 › control,
  /// which is only drawn when the turn actually holds alternatives. Null leaves
  /// the control read-only (the preview).
  final void Function(int)? onSwipe;

  /// Opens the avatar that was tapped, full size. Called with true for the user's
  /// side and false for the character's, so the chat can decide whose pictures to
  /// show. Null (the preview, and a turn with nothing to show) leaves the avatar
  /// inert — a picture that cannot be opened must not look tappable.
  final void Function(bool isUser)? onAvatarTap;

  /// The picture this turn's character wears here, when the thread has a choice of
  /// its own. Resolved by `AppState.avatarRefFor` and passed in rather than read
  /// off the card, so the per-chat choice reaches the two places that draw a chat
  /// avatar and nowhere else has to know about it.
  final String? avatarOverride;

  /// The same, for the impersonated user's side.
  final String? userAvatarOverride;

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
    if (placement == ActionBarPlacement.besideName && !ui.showNames) {
      placement = ActionBarPlacement.belowMessage;
    }
    // Opposite-name needs a name to sit across from, too.
    if (placement == ActionBarPlacement.oppositeName && !ui.showNames) {
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
    if (nameW != null &&
        actionsBar != null &&
        placement == ActionBarPlacement.besideName) {
      nameW = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: nameW),
          const SizedBox(width: 4),
          actionsBar,
        ],
      );
    }
    final nameStyle = ui.nameFor(isUser);

    // The model's thinking, when this turn has any: a collapsed bar directly
    // above the reply, so it reads as belonging to this message and never
    // displaces the answer.
    final Widget? thinking = message.hasReasoning
        ? ThinkingBlock(
            reasoning: message.reasoning,
            thinkingMs: message.thinkingMs,
            // Still thinking while the turn is streaming and no duration has
            // been recorded — that only happens once the answer starts.
            inProgress: pending && message.thinkingMs == null,
            fontSize: ui.fontSize,
          )
        : null;

    Widget bubbleUnit(Widget bubble) => thinking == null
        ? bubble
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: crossAxis,
            children: [thinking, bubble],
          );

    // The turn's text, with the swipe control tucked under it when this turn
    // holds more than one alternative.
    Widget content({Widget? leading}) {
      final text = _text(scheme, textColor, showCaret, leading: leading);
      if (!message.hasSwipes) return text;
      return Column(
        mainAxisSize: MainAxisSize.min,
        // Centred under the message, per the spec — the bubble hugs whichever of
        // the two is wider.
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [text, _swipeBar(context, textColor)],
      );
    }
// APPEND-BUILD

    // The name is drawn in a band spanning the whole row, so its alignment reads
    // against the *screen* ("Right" = the right edge of the chat) rather than
    // against the width of the bubble it happens to sit over. In the
    // opposite-name placement the band also carries the action bar, pinned to
    // the edge *away* from the name (name left → actions right, and vice versa).
    final Widget? band = nameW == null
        ? null
        : (actionsBar != null && placement == ActionBarPlacement.oppositeName)
            ? _oppositeNameBand(nameW, actionsBar, nameStyle.align)
            : Align(alignment: nameStyle.align.alignment, child: nameW);

    // Keeps a band's slot in the layout without drawing it, so an overlaid or
    // nudged label never makes the turn jump or run into its neighbour.
    Widget reserved(Widget child) => Visibility(
          visible: false,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: child,
        );

    final nameAbove = nameStyle.position == NamePosition.above;

    // "Below" means below the *avatar*. Where that is depends on how this turn
    // is laid out:
    //  - text beside the avatar: the space under the avatar is empty, so the
    //    label is laid over the turn at the avatar's measured bottom.
    //  - text below the avatar: the label goes straight into the column between
    //    the two, no measuring needed — until it is nudged, when it has to be
    //    lifted out into the overlay so its hit box travels with it.
    //  - text wrapped around an inline avatar, or no avatar at all: there is no
    //    avatar bottom to speak of, so the label sits under the message.
    final hasAvatar = band != null && avatar != null;
    final belowAvatar = hasAvatar && !nameAbove;
    final inColumn = belowAvatar && ui.textPlacement == TextPlacement.below;
    final anchorToAvatar = belowAvatar &&
        (ui.textPlacement == TextPlacement.beside ||
            (inColumn && nameStyle.isNudged));

    // Assembles the turn around whichever avatar widget it is handed — so the
    // anchored case can pass in a measured one without duplicating any of this.
    Widget buildBody(Widget? avatarUnit) {
      final Widget inner;
      switch (ui.textPlacement) {
        case TextPlacement.around:
          inner = bubbleUnit(_bubble(content(leading: avatarUnit), bubbleColor));
        case TextPlacement.below:
          inner = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: crossAxis,
            children: [
              if (avatarUnit != null) ...[
                avatarUnit,
                const SizedBox(height: 6),
              ],
              // Between the avatar and the text is literally below the avatar.
              // Once nudged the slot stays but the label moves to the overlay.
              if (inColumn) ...[
                nameStyle.isNudged ? reserved(band) : band,
                const SizedBox(height: 2),
              ],
              bubbleUnit(_bubble(content(), bubbleColor)),
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
              Flexible(child: bubbleUnit(_bubble(content(), bubbleColor))),
            ],
          );
      }

      // Below / right placements wrap the assembled message; beside-name and
      // beside-avatar have already folded the bar into the name/avatar above.
      if (actionsBar != null && placement == ActionBarPlacement.belowMessage) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: crossAxis,
          children: [inner, actionsBar],
        );
      }
      if (actionsBar != null && placement == ActionBarPlacement.messageRight) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Flexible(child: inner),
            const SizedBox(width: 4),
            actionsBar,
          ],
        );
      }
      return inner;
    }

    final sideAlignment =
        side.isLeft ? Alignment.centerLeft : Alignment.centerRight;

    // Place the name band. A label already sitting in the message column is done;
    // everything else is laid out around the assembled turn.
    final Widget outer;
    if (anchorToAvatar) {
      // The avatar's bottom edge is *measured*, never computed: a "free"-fit
      // picture is shorter than its nominal size, an action bar hanging under it
      // makes it taller, and the preview's frame adds room for its resize
      // handle. Every one of those guesses has been wrong at least once, and each
      // time the label jumped the moment it was nudged.
      outer = _NameUnderAvatar(
        avatar: avatar,
        band: band,
        reservedBand: reserved(band),
        // The column layout already keeps the label's slot; the beside layout has
        // to reserve one so a long name never reaches the next turn.
        reserveInStack: !inColumn,
        gap: inColumn ? 6 : 2,
        avatarOffsetY: style.offsetY,
        fallbackHeight: style.size,
        nudge: nameStyle.offset,
        sideAlignment: sideAlignment,
        buildBody: buildBody,
      );
    } else {
      final body = buildBody(avatar);
      if (band == null || (inColumn && !nameStyle.isNudged)) {
        outer = body;
      } else {
        final messageRow = Align(alignment: sideAlignment, child: body);

        // The band is the *last* child so it paints over the message;
        // [verticalDirection] is what puts it above or below.
        Column stacked(Widget bandSlot) => Column(
              mainAxisSize: MainAxisSize.min,
              // Stretch so both the band and the message get the full row width
              // to align themselves within.
              crossAxisAlignment: CrossAxisAlignment.stretch,
              verticalDirection:
                  nameAbove ? VerticalDirection.up : VerticalDirection.down,
              children: [messageRow, bandSlot],
            );

        if (!nameStyle.isNudged) {
          outer = stacked(band);
        } else {
          // A nudged label has to keep a hit box where it is *drawn*, not where
          // it was laid out — a `Transform` would paint it over the message but
          // leave it ungrabbable, so a name could be dragged once and never
          // again.
          outer = Stack(
            clipBehavior: Clip.none,
            children: [
              stacked(reserved(band)),
              Positioned(
                left: nameStyle.offsetX,
                right: -nameStyle.offsetX,
                top: nameAbove ? nameStyle.offsetY : null,
                bottom: nameAbove ? null : -nameStyle.offsetY,
                child: band,
              ),
            ],
          );
        }
      }
    }

    return Align(
      alignment: side.isLeft ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        // Half the configured gap above and below, so consecutive turns (and
        // their avatars) sit [ChatInterface.messageSpacing] apart.
        margin: EdgeInsets.symmetric(
          vertical: (ui.messageSpacing / 2).clamp(0.0, kMaxMessageSpacing),
          horizontal: 12,
        ),
        constraints: BoxConstraints(
          maxWidth: ui.contentWidth.maxWidthFor(MediaQuery.sizeOf(context).width),
        ),
        child: GestureDetector(
          onLongPress: onLongPress ??
              (message.content.isEmpty
                  ? null
                  : () => _copy(context, _displayContent)),
          child: outer,
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

  /// The name band for [ActionBarPlacement.oppositeName]: the label at its own
  /// aligned edge and the action bar hard against the *opposite* edge of the
  /// full-width row. A left name puts the bar on the right and a right name puts
  /// it on the left; a centred name keeps its centre and the bar sits at the
  /// right. The name is [Flexible] so a long one never shoves the bar off-screen.
  Widget _oppositeNameBand(Widget name, Widget actions, NameAlign align) {
    final nameOnRight = align == NameAlign.end;
    return Row(
      mainAxisSize: MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: nameOnRight
          ? [
              actions,
              Expanded(
                child: Align(alignment: Alignment.centerRight, child: name),
              ),
            ]
          : [
              Expanded(
                child: Align(alignment: align.alignment, child: name),
              ),
              actions,
            ],
    );
  }

  /// The swipe selector: `‹ 1 / 2 ›`, centred at the bottom of the message.
  ///
  /// Only reached when the turn holds more than one alternative — a turn with a
  /// single reply shows nothing at all, so the chat stays clean. The arrow at
  /// each end is disabled rather than wrapping, and both are disabled while a
  /// reply is streaming (the incoming swipe is still being written).
  Widget _swipeBar(BuildContext context, Color color) {
    final index = message.swipeIndex;
    final count = message.swipeCount;
    final live = onSwipe != null && !streaming;
    final faded = color.withValues(alpha: 0.75);
    final size = (ui.fontSize * 0.82).clamp(10.0, 18.0);

    Widget arrow(IconData icon, String tooltip, int? target) => IconButton(
          tooltip: tooltip,
          iconSize: size + 6,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 24),
          color: faded,
          onPressed:
              live && target != null ? () => onSwipe!(target) : null,
          icon: Icon(icon),
        );

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          arrow(Icons.chevron_left, 'Previous', index > 0 ? index - 1 : null),
          Text(
            '${index + 1} / $count',
            style: TextStyle(
              fontSize: size,
              color: faded,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          arrow(Icons.chevron_right, 'Next',
              index < count - 1 ? index + 1 : null),
        ],
      ),
    );
  }

  /// This turn's sender name, as the label that fills the name band: its own
  /// size, Google font and colour. In the preview it is also the drag handle for
  /// the role's nudge, framed and given a comfortable touch target (a 12 px
  /// caption is far too small to grab with a finger). The nudge itself is applied
  /// by the caller, which owns the layout the label has to stay hittable in.
  Widget _nameLabel(BuildContext context, bool isUser) {
    final name = isUser
        ? (userPersona?.displayName ??
            (ui.userName.trim().isEmpty ? 'You' : ui.userName.trim()))
        : (character?.displayName ?? 'Assistant');
    final ns = ui.nameFor(isUser);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Per-role Google font, when one is chosen; a family the bundle can't
    // resolve must never take the whole turn down with it.
    TextStyle? base = theme.textTheme.labelSmall;
    final family = ns.fontFamily;
    if (family != null && family.isNotEmpty) {
      try {
        base = GoogleFonts.getFont(family, textStyle: base);
      } catch (_) {
        base = theme.textTheme.labelSmall;
      }
    }

    // Only a hair of padding: the label should read as part of the message, not
    // as a floating caption. Anything further is the user's own nudge.
    Widget label = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Text(
        name,
        textAlign: ns.align.textAlign,
        style: (base ?? const TextStyle()).copyWith(
          fontSize: ns.size,
          color: ns.color != null ? Color(ns.color!) : scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );

    if (interactive && onNameDrag != null) {
      label = _NudgeHandle(
        onDrag: onNameDrag!,
        child: Container(
          // Padding first, so the grab area is a finger wide even around a
          // small name.
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(
                color: scheme.primary.withValues(alpha: 0.7), width: 1),
            borderRadius: BorderRadius.circular(6),
            color: scheme.primary.withValues(alpha: 0.06),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.drag_indicator, size: 16, color: scheme.primary),
              const SizedBox(width: 2),
              Flexible(child: label),
            ],
          ),
        ),
      );
    }

    return label;
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
        avatarOverride: avatarOverride,
        size: size,
        shape: style.shape,
        corner: style.corner,
        fit: style.fit,
      );
    } else if (isUser && userPersona != null) {
      // The user is impersonating a character: wear that persona's picture.
      base = CharacterAvatar(
        character: userPersona!,
        avatarOverride: userAvatarOverride,
        size: size,
        shape: style.shape,
        corner: style.corner,
        fit: style.fit,
      );
    } else {
      base = _GenericAvatar(
        size: size,
        radius: style.radiusFor(size),
        icon: isUser ? Icons.person : Icons.smart_toy_outlined,
      );
    }

    if (!interactive) {
      final tap = onAvatarTap;
      return Transform.translate(
        offset: style.offset,
        // The whole avatar is the target, and only when there is something behind
        // it to open. A hit test on the picture itself would miss the monogram.
        child: tap == null
            ? base
            : GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => tap(isUser),
                child: base,
              ),
      );
    }

    final scheme = Theme.of(context).colorScheme;
    return Transform.translate(
      offset: style.offset,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 22, bottom: 22),
            child: _NudgeHandle(
              onDrag: (d) => onAvatarDrag?.call(d),
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.primary, width: 2),
                  borderRadius: BorderRadius.circular(style.radiusFor(size)),
                ),
                child: base,
              ),
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: _NudgeHandle(
              onDrag: (d) => onAvatarResize?.call((d.dx + d.dy) / 2),
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
            wraps: ui.activeTextWrapRules,
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
          wraps: ui.activeTextWrapRules,
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

/// A turn whose sender name hangs under the avatar, anchored to the avatar's
/// **measured** height.
///
/// Every attempt to compute that height from the settings has been wrong in some
/// configuration — a `free`-fit picture is shorter than its nominal size, an
/// action bar hanging under the avatar makes it taller, the preview's frame adds
/// room for a resize handle — and each time the label jumped somewhere else the
/// moment it was nudged. So the avatar is measured instead: [buildBody] is handed
/// the avatar wrapped in a reporter, and the label is placed at whatever bottom
/// edge comes back.
class _NameUnderAvatar extends StatefulWidget {
  const _NameUnderAvatar({
    required this.avatar,
    required this.band,
    required this.reservedBand,
    required this.reserveInStack,
    required this.gap,
    required this.avatarOffsetY,
    required this.fallbackHeight,
    required this.nudge,
    required this.sideAlignment,
    required this.buildBody,
  });

  /// The avatar unit to measure and lay out (bar and frame included).
  final Widget avatar;

  /// The full-width, aligned name label, and an invisible copy of it that holds
  /// its slot in the layout.
  final Widget band;
  final Widget reservedBand;

  /// Whether this layout still needs a slot reserved for the label; the column
  /// layout keeps one of its own.
  final bool reserveInStack;

  /// Space between the avatar's bottom and the label.
  final double gap;

  /// The avatar's own visual nudge, so the label follows where it was dragged to.
  final double avatarOffsetY;

  /// Anchor to use for the one frame before the first measurement lands.
  final double fallbackHeight;

  final Offset nudge;
  final Alignment sideAlignment;
  final Widget Function(Widget avatar) buildBody;

  @override
  State<_NameUnderAvatar> createState() => _NameUnderAvatarState();
}

class _NameUnderAvatarState extends State<_NameUnderAvatar> {
  double? _avatarHeight;

  void _onSize(Size size) {
    if (!mounted || size.height == _avatarHeight) return;
    setState(() => _avatarHeight = size.height);
  }

  @override
  Widget build(BuildContext context) {
    final body = widget.buildBody(
      _MeasureSize(onChange: _onSize, child: widget.avatar),
    );
    final anchor = (_avatarHeight ?? widget.fallbackHeight) +
        widget.avatarOffsetY +
        widget.gap;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Align(alignment: widget.sideAlignment, child: body),
        if (widget.reserveInStack)
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [SizedBox(height: anchor), widget.reservedBand],
          ),
        Positioned(
          top: anchor + widget.nudge.dy,
          left: widget.nudge.dx,
          right: -widget.nudge.dx,
          child: widget.band,
        ),
      ],
    );
  }
}

/// Reports its child's laid-out size, once per change, after the frame that
/// produced it — the cheapest honest way to learn a sibling's height.
class _MeasureSize extends SingleChildRenderObjectWidget {
  const _MeasureSize({required this.onChange, required Widget super.child});

  final ValueChanged<Size> onChange;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasureSize(onChange);

  @override
  void updateRenderObject(
      BuildContext context, _RenderMeasureSize renderObject) {
    renderObject.onChange = onChange;
  }
}

class _RenderMeasureSize extends RenderProxyBox {
  _RenderMeasureSize(this.onChange);

  ValueChanged<Size> onChange;
  Size? _reported;

  @override
  void performLayout() {
    super.performLayout();
    final next = child?.size ?? Size.zero;
    if (_reported == next) return;
    _reported = next;
    // Never call back during layout: the listener rebuilds.
    WidgetsBinding.instance.addPostFrameCallback((_) => onChange(next));
  }
}

/// A drag handle for the settings preview.
///
/// A plain pan is deliberate: it is what worked on real hardware. The clever
/// alternative — an immediate multi-drag recogniser, to beat an enclosing
/// scrollable to the gesture — turned out not to fire on a physical touch screen
/// at all, so both the avatar and the name went dead. The preview's mock chat is
/// non-scrolling instead ([ChatInterfacePreviewPage]), which leaves nothing to
/// compete with and lets the simple thing work.
class _NudgeHandle extends StatelessWidget {
  const _NudgeHandle({required this.onDrag, required this.child});

  final ValueChanged<Offset> onDrag;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Pan and (vertical/horizontal) drag callbacks are mutually exclusive on
      // one detector, so pan alone covers every direction.
      onPanUpdate: (d) => onDrag(d.delta),
      child: child,
    );
  }
}

/// A stand-in avatar for the user's turns (and bot turns in a character-less
/// chat): a glyph on the same tinted, shape-matched frame the picture avatars
/// use, so both sides of the conversation read consistently.
class _GenericAvatar extends StatelessWidget {
  const _GenericAvatar({
    required this.size,
    required this.radius,
    required this.icon,
  });

  final double size;

  /// Corner radius, already resolved from the role's shape + rounding level.
  final double radius;

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
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


