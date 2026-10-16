import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../../models/character.dart';
import '../../../models/conversation.dart';
import '../../../models/home_layout.dart';
import '../../../models/message.dart';
import '../../../services/chat_graph.dart';
import '../../../state/app_state.dart';
import '../../../widgets/avatar_image.dart';
import '../../../widgets/character_avatar.dart';
import '../../chat_screen.dart';
import '../../chats_screen.dart' show relativeTime;
import '../home_spec.dart';

/// The options recent-chat and pinned-chat share, so the two widgets' sheets
/// read the same and [ChatPreviewCard] draws them identically.
List<HomeOption> chatCardOptions() => [
      const HomeChoiceOption(
        key: 'avatar',
        label: 'Avatar',
        choices: {
          'topLeft': 'Top left',
          'left': 'Left',
          'topRight': 'Top right',
          'right': 'Right',
          'background': 'Background',
          'none': 'None',
        },
      ),
      HomeDependentOption(
        option: const HomeChoiceOption(
          key: 'bgStyle',
          label: 'Background style',
          choices: {'fade': 'Fade', 'blur': 'Blur', 'opaque': 'Opaque'},
          help: 'With opaque, a scrim sits behind the text for contrast.',
        ),
        whenKey: 'avatar',
        whenValues: const ['background'],
      ),
      HomeDependentOption(
        option: const HomeChoiceOption(
          key: 'fadeFrom',
          label: 'Fade from',
          choices: {
            'bottom': 'Bottom',
            'left': 'Left',
            'right': 'Right',
            'top': 'Top',
          },
        ),
        whenKey: 'bgStyle',
        whenValues: const ['fade'],
        whenDefault: 'fade',
      ),
      HomeDependentOption(
        option: const HomeToggleOption(
          key: 'fadeSide',
          label: 'Fade the picture into the card',
          help: 'A tall edge-to-edge picture on that side, instead of a circle.',
        ),
        whenKey: 'avatar',
        whenValues: const ['left', 'right', 'topLeft', 'topRight'],
      ),
      const HomeToggleOption(key: 'showName', label: 'Show name', fallback: true),
      HomeDependentOption(
        option: const HomeFontOption(key: 'nameFont', label: 'Name font'),
        whenKey: 'showName',
        whenValues: const ['true'],
        whenDefault: 'true',
      ),
      const HomeToggleOption(key: 'showTime', label: 'Show time', fallback: true),
      const HomeChoiceOption(
        key: 'lines',
        label: 'Message',
        choices: {
          'lastMessage': 'Last message',
          'lastLine': 'Last line',
          'firstLine': 'First line',
          'lastTwo': 'Last two turns',
          'none': 'Hidden',
        },
      ),
    ];

enum _AvatarPlacement { topLeft, left, topRight, right, background, none }

enum _BgStyle { fade, blur, opaque }

enum _FadeFrom { bottom, left, right, top }

enum _Lines { lastMessage, lastLine, firstLine, lastTwo, none }

/// What a tile's config says about how to draw the card, parsed once so the
/// rest of the widget reads plain enum values instead of strings.
class _CardConfig {
  _CardConfig(HomeTile tile)
      : avatar = _parse(tile.str('avatar'), _AvatarPlacement.values, _AvatarPlacement.topLeft),
        bgStyle = _parse(tile.str('bgStyle'), _BgStyle.values, _BgStyle.fade),
        fadeFrom = _parse(tile.str('fadeFrom'), _FadeFrom.values, _FadeFrom.bottom),
        fadeSide = tile.flag('fadeSide', false),
        showName = tile.flag('showName', true),
        nameFont = tile.str('nameFont'),
        showTime = tile.flag('showTime', true),
        lines = _parse(tile.str('lines'), _Lines.values, _Lines.lastMessage);

  final _AvatarPlacement avatar;
  final _BgStyle bgStyle;
  final _FadeFrom fadeFrom;
  final bool fadeSide;
  final bool showName;
  final String? nameFont;
  final bool showTime;
  final _Lines lines;

  bool get sidePlacement => avatar == _AvatarPlacement.left || avatar == _AvatarPlacement.right;

  static T _parse<T extends Enum>(String? stored, List<T> values, T fallback) {
    if (stored == null) return fallback;
    for (final v in values) {
      if (v.name == stored) return v;
    }
    return fallback;
  }
}

/// Applies [family] to [base] through Google Fonts, falling back to [base]
/// unchanged when the family is absent or the bundle can't resolve it.
TextStyle? _withFont(String? family, TextStyle? base) {
  if (family == null || family.isEmpty) return base;
  try {
    return GoogleFonts.getFont(family, textStyle: base);
  } catch (_) {
    return base;
  }
}

/// How wide one line of [text] in [style] lays out, with the user's font
/// scale — used to decide whether a fixed-width label (the relative time)
/// still fits beside a shrinkable one, rather than guessing from a flat
/// pixel breakpoint that a larger font scale would blow through.
double _textWidth(BuildContext context, String text, TextStyle? style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  return painter.width;
}

Character? _findById(List<Character> characters, String id) {
  for (final c in characters) {
    if (c.id == id) return c;
  }
  return null;
}

/// The last message's text per [_Lines], ignoring [_Lines.lastTwo]/[_Lines.none]
/// (handled by their own layouts) — used for `lastMessage`/`firstLine`/`lastLine`.
String _previewText(Conversation conversation, _Lines lines) {
  if (conversation.messages.isEmpty) return '';
  final text = conversation.messages.last.content.trim();
  if (text.isEmpty) return '';
  switch (lines) {
    case _Lines.firstLine:
      return text.split('\n').first.trim();
    case _Lines.lastLine:
      final nonEmpty = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
      return nonEmpty.isEmpty ? text : nonEmpty.last;
    case _Lines.lastMessage:
    case _Lines.lastTwo:
    case _Lines.none:
      return text;
  }
}

/// "Mira: hello there" / "You: hello there" — a group chat's per-message
/// speaker, falling back to the thread's own character, then the plain text.
String _speakerPrefixed(
  ChatMessage message,
  Conversation conversation,
  AppState state,
  List<Character> characters,
) {
  final text = message.content.trim();
  if (text.isEmpty) return '';
  if (message.isUser) return 'You: $text';
  Character? speaker;
  if (conversation.isGroup && message.speakerId != null) {
    speaker = state.characterFor(conversation, message.speakerId) ??
        _findById(characters, message.speakerId!);
  } else {
    final memberId = conversation.memberIds.isEmpty ? null : conversation.memberIds.first;
    speaker = memberId == null
        ? null
        : state.characterFor(conversation, memberId) ?? _findById(characters, memberId);
  }
  final name = (speaker?.displayName ?? message.speakerName)?.trim();
  return name == null || name.isEmpty ? text : '$name: $text';
}

/// The last two turns of [conversation], oldest first — empty when there are
/// fewer than two.
List<ChatMessage> _lastTwoTurns(Conversation conversation) {
  final messages = conversation.messages;
  return messages.length < 2 ? const [] : messages.sublist(messages.length - 2);
}

/// The shared look for one chat tree shown as a card: a customisable avatar
/// placement, name, time and message preview — filling the card at any size.
///
/// Used by both the recent-chat and pinned-chat widgets so the two read as
/// the same kind of thing on the grid, and so their settings sheets share
/// [chatCardOptions].
class ChatPreviewCard extends StatelessWidget {
  const ChatPreviewCard({
    super.key,
    required this.tree,
    required this.editing,
    required this.tile,
    this.compact = false,
  });

  final ChatTreeEntry tree;
  final bool editing;
  final HomeTile tile;

  /// A short tile (1 row tall, or otherwise cramped): the densest layout.
  final bool compact;

  void _open(BuildContext context) {
    if (editing) return;
    final state = context.read<AppState>();
    state.selectConversation(tree.latest.id);
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ChatScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final latest = tree.latest;
    final memberId = latest.memberIds.isEmpty ? null : latest.memberIds.first;
    final state = homeWatch(context, (s) {
      final character = memberId == null
          ? null
          : s.characterFor(latest, memberId) ?? _findById(s.characters, memberId);
      final avatarRef = character == null ? null : s.avatarRefFor(latest, character);
      return (
        latest.id,
        latest.updatedAt,
        latest.messages.length,
        latest.messages.isEmpty ? 0 : latest.messages.last.content.length,
        tree.root.title,
        character?.displayName,
        avatarRef,
      );
    });
    final characters = state.characters;
    final cfg = _CardConfig(tile);
    final theme = Theme.of(context);
    final character = memberId == null
        ? null
        : state.characterFor(latest, memberId) ?? _findById(characters, memberId);
    final avatarRef = character == null ? null : state.avatarRefFor(latest, character);
    final title = tree.root.title.trim().isEmpty
        ? (character?.displayName ?? 'New chat')
        : tree.root.title.trim();
    final ago = relativeTime(latest.updatedAt);
    final preview = cfg.lines == _Lines.none
        ? ''
        : cfg.lines == _Lines.firstLine || cfg.lines == _Lines.lastLine
            ? _previewText(latest, cfg.lines)
            : (latest.messages.isEmpty
                ? ''
                : _speakerPrefixed(latest.messages.last, latest, state, characters));

    final semanticParts = [
      title,
      if (preview.isNotEmpty) preview,
      if (cfg.showTime) ago,
    ];

    final isBackground = cfg.avatar == _AvatarPlacement.background;
    return HomeCard(
      semanticLabel: semanticParts.join(', '),
      onTap: editing ? null : () => _open(context),
      padding: isBackground ? EdgeInsets.zero : const EdgeInsets.all(14),
      fit: !isBackground,
      clip: isBackground,
      builder: (context, inner) => isBackground
          ? _BackgroundCard(
              tree: tree,
              character: character,
              avatarRef: avatarRef,
              title: title,
              ago: ago,
              preview: preview,
              cfg: cfg,
              theme: theme,
              inner: inner,
              compact: compact,
            )
          : _ForegroundCard(
              tree: tree,
              character: character,
              avatarRef: avatarRef,
              title: title,
              ago: ago,
              cfg: cfg,
              theme: theme,
              inner: inner,
              compact: compact,
              state: state,
              characters: characters,
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Foreground layout (avatar at a corner/side, text beside/below it).
// ---------------------------------------------------------------------------

class _ForegroundCard extends StatelessWidget {
  const _ForegroundCard({
    required this.tree,
    required this.character,
    required this.avatarRef,
    required this.title,
    required this.ago,
    required this.cfg,
    required this.theme,
    required this.inner,
    required this.compact,
    required this.state,
    required this.characters,
  });

  final ChatTreeEntry tree;
  final Character? character;
  final String? avatarRef;
  final String title;
  final String ago;
  final _CardConfig cfg;
  final ThemeData theme;
  final Size inner;
  final bool compact;
  final AppState state;
  final List<Character> characters;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;

    // Text sizes step up with room, per the design brief.
    final roomy = inner.height >= 150 && inner.width >= 150;
    final nameBaseStyle = (roomy
            ? (inner.height >= 220 ? theme.textTheme.headlineSmall : theme.textTheme.titleLarge)
            : theme.textTheme.titleSmall)
        ?.copyWith(fontWeight: FontWeight.w700);
    final nameStyle = _withFont(cfg.nameFont, nameBaseStyle);
    final previewStyle = (roomy ? theme.textTheme.bodyLarge : theme.textTheme.bodyMedium)
        ?.copyWith(color: scheme.onSurfaceVariant);
    final agoStyle = theme.textTheme.labelSmall?.copyWith(color: scheme.outline);

    final avatarSize = (inner.height > inner.width ? inner.height : inner.width) * 0.22;
    final clampedAvatarSize = avatarSize.clamp(18.0, 72.0);
    final showHeader = cfg.showName || cfg.showTime;
    final headerH = showHeader
        ? (homeLineHeight(context, nameStyle) > clampedAvatarSize
            ? homeLineHeight(context, nameStyle)
            : clampedAvatarSize)
        : 0.0;
    final headerHasAvatar =
        cfg.avatar == _AvatarPlacement.topLeft || cfg.avatar == _AvatarPlacement.topRight;
    // The header row's name is `Expanded`, so it can always shrink to 0 —
    // but the avatar beside it and the time text are both fixed width, and
    // at a large text scale their *measured* width (not a flat px guess)
    // can be more than the row has. Drop the time rather than overflow.
    final agoWidth = _textWidth(context, ago, agoStyle);
    final headerAvatarBudget = headerHasAvatar ? clampedAvatarSize + 10 : 0.0;
    final roomForInlineTime = inner.width - headerAvatarBudget - 8 - agoWidth >= 0;

    final latest = tree.latest;
    final lastTwo = cfg.lines == _Lines.lastTwo ? _lastTwoTurns(latest) : const <ChatMessage>[];
    final showBubbles = lastTwo.length == 2 && inner.height >= 150;
    final previewText = showBubbles || cfg.lines == _Lines.none || latest.messages.isEmpty
        ? ''
        : (cfg.lines == _Lines.firstLine || cfg.lines == _Lines.lastLine
            ? _previewText(latest, cfg.lines)
            : _speakerPrefixed(latest.messages.last, latest, state, characters));
    final previewH = homeLineHeight(context, previewStyle);

    Widget avatarWidget() {
      if (character == null) {
        return CircleAvatar(
          radius: clampedAvatarSize / 2,
          backgroundColor: scheme.secondaryContainer,
          child: Icon(
            Icons.chat_bubble_outline_rounded,
            size: clampedAvatarSize * 0.6,
            color: scheme.onSecondaryContainer,
          ),
        );
      }
      return CharacterAvatar(character: character!, avatarOverride: avatarRef, size: clampedAvatarSize);
    }

    final showInlineTimeInHeader = cfg.showTime && roomForInlineTime;

    Widget headerRow({bool withAvatarLeft = false, bool withAvatarRight = false}) => Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (withAvatarLeft) ...[avatarWidget(), const SizedBox(width: 10)],
            if (cfg.showName)
              Expanded(
                child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: nameStyle),
              )
            else
              const Spacer(),
            if (showInlineTimeInHeader && !withAvatarRight) ...[
              const SizedBox(width: 8),
              Text(ago, maxLines: 1, style: agoStyle),
            ],
            if (withAvatarRight) ...[const SizedBox(width: 10), avatarWidget()],
          ],
        );

    Widget previewWidget(double room, double maxWidth) {
      if (showBubbles) {
        return _TurnBubbles(
          turns: lastTwo,
          conversation: latest,
          state: state,
          characters: characters,
          maxWidth: maxWidth,
          availableHeight: room,
          style: previewStyle,
        );
      }
      if (previewText.isEmpty) return const SizedBox.shrink();
      final maxLines = (room / previewH).floor().clamp(0, compact ? 1 : 6);
      if (maxLines <= 0) return const SizedBox.shrink();
      return Text(previewText, maxLines: maxLines, overflow: TextOverflow.ellipsis, style: previewStyle);
    }

    // Side placements: avatar as a column beside the text (optionally an
    // edge-to-edge faded picture instead of a circle).
    if (cfg.sidePlacement) {
      final fadeWidth = (inner.width * 0.4).clamp(32.0, 140.0);
      final useFade = cfg.fadeSide && character != null && avatarRef != null && avatarRef!.isNotEmpty;
      final avatarColumnWidth = useFade ? fadeWidth : clampedAvatarSize;
      final avatarColumn = useFade
          ? _EdgeFadeAvatar(
              avatarRef: avatarRef!,
              fromRight: cfg.avatar == _AvatarPlacement.right,
              height: inner.height,
              width: fadeWidth,
              cardColor: scheme.surfaceContainerHigh,
            )
          : Align(alignment: Alignment.topCenter, child: avatarWidget());
      final textWidth = (inner.width - avatarColumnWidth - 12).clamp(0.0, inner.width);
      final room = (inner.height - headerH - 6).clamp(0.0, inner.height);
      final showSideTime = cfg.showTime && textWidth - 8 - agoWidth >= 0;
      final text = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showHeader)
            Row(
              children: [
                if (cfg.showName)
                  Expanded(
                    child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: nameStyle),
                  )
                else
                  const Spacer(),
                if (showSideTime) ...[
                  const SizedBox(width: 8),
                  Text(ago, maxLines: 1, style: agoStyle),
                ],
              ],
            ),
          if (showHeader) const SizedBox(height: 6),
          previewWidget(room, textWidth),
        ],
      );
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: cfg.avatar == _AvatarPlacement.left
            ? [
                SizedBox(width: avatarColumnWidth, height: inner.height, child: avatarColumn),
                const SizedBox(width: 12),
                Expanded(child: text),
              ]
            : [
                Expanded(child: text),
                const SizedBox(width: 12),
                SizedBox(width: avatarColumnWidth, height: inner.height, child: avatarColumn),
              ],
      );
    }

    if (cfg.avatar == _AvatarPlacement.none) {
      final room = (inner.height - headerH - 6).clamp(0.0, inner.height);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showHeader) headerRow(),
          if (showHeader) const SizedBox(height: 6),
          previewWidget(room, inner.width),
        ],
      );
    }

    // topLeft / topRight: avatar sits inline with the name row.
    final room = (inner.height - headerH - 6).clamp(0.0, inner.height);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        headerRow(
          withAvatarLeft: cfg.avatar == _AvatarPlacement.topLeft,
          withAvatarRight: cfg.avatar == _AvatarPlacement.topRight,
        ),
        const SizedBox(height: 6),
        previewWidget(room, inner.width),
      ],
    );
  }
}

/// A side avatar laid edge to edge, fading into the card colour — the
/// "fade the picture into the card" option for left/right placements.
class _EdgeFadeAvatar extends StatelessWidget {
  const _EdgeFadeAvatar({
    required this.avatarRef,
    required this.fromRight,
    required this.height,
    required this.width,
    required this.cardColor,
  });

  final String avatarRef;
  final bool fromRight;
  final double height;
  final double width;
  final Color cardColor;

  @override
  Widget build(BuildContext context) {
    final provider = avatarImage(
      avatarRef,
      displaySize: width > height ? width : height,
      devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
    );
    if (provider == null) return SizedBox(width: width, height: height);
    return RepaintBoundary(
      child: SizedBox(
        width: width,
        height: height,
        child: ShaderMask(
          shaderCallback: (rect) => LinearGradient(
            begin: fromRight ? Alignment.centerRight : Alignment.centerLeft,
            end: fromRight ? Alignment.centerLeft : Alignment.centerRight,
            colors: const [Color(0xFFFFFFFF), Color(0x00FFFFFF)],
          ).createShader(rect),
          blendMode: BlendMode.dstIn,
          child: Image(image: provider, fit: BoxFit.cover, width: width, height: height),
        ),
      ),
    );
  }
}

/// Up to two soft speech-bubble blocks for the last two turns, as many lines
/// as fit the given height — user right-aligned, character left-aligned.
class _TurnBubbles extends StatelessWidget {
  const _TurnBubbles({
    required this.turns,
    required this.conversation,
    required this.state,
    required this.characters,
    required this.maxWidth,
    required this.availableHeight,
    required this.style,
  });

  final List<ChatMessage> turns;
  final Conversation conversation;
  final AppState state;
  final List<Character> characters;
  final double maxWidth;
  final double availableHeight;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lineH = homeLineHeight(context, style);
    final perBubble = (availableHeight / 2 - 8).clamp(0.0, double.infinity);
    final maxLines = (perBubble / lineH).floor().clamp(1, 3);
    final widgets = <Widget>[];
    for (var i = 0; i < turns.length; i++) {
      final m = turns[i];
      final text = _speakerPrefixed(m, conversation, state, characters);
      if (text.isEmpty) continue;
      final isUser = m.isUser;
      if (widgets.isNotEmpty) widgets.add(const SizedBox(height: 6));
      widgets.add(
        Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth * 0.85),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: isUser ? scheme.primaryContainer : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Text(
                  text,
                  maxLines: maxLines,
                  overflow: TextOverflow.ellipsis,
                  style: style?.copyWith(
                    color: isUser ? scheme.onPrimaryContainer : scheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: widgets,
    );
  }
}

// ---------------------------------------------------------------------------
// Background layout (the avatar fills the card; text sits over it).
// ---------------------------------------------------------------------------

class _BackgroundCard extends StatelessWidget {
  const _BackgroundCard({
    required this.tree,
    required this.character,
    required this.avatarRef,
    required this.title,
    required this.ago,
    required this.preview,
    required this.cfg,
    required this.theme,
    required this.inner,
    required this.compact,
  });

  final ChatTreeEntry tree;
  final Character? character;
  final String? avatarRef;
  final String title;
  final String ago;
  final String preview;
  final _CardConfig cfg;
  final ThemeData theme;
  final Size inner;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    final opaque = cfg.bgStyle == _BgStyle.opaque;
    // Legible text: onSurface on the faded side, white + scrim on opaque.
    final onPicture = opaque ? Colors.white : scheme.onSurface;
    final nameBaseStyle = (inner.height >= 150 ? theme.textTheme.titleLarge : theme.textTheme.titleSmall)
        ?.copyWith(fontWeight: FontWeight.w700, color: onPicture);
    final nameStyle = _withFont(cfg.nameFont, nameBaseStyle);
    final previewStyle = (inner.height >= 150 ? theme.textTheme.bodyLarge : theme.textTheme.bodyMedium)
        ?.copyWith(color: onPicture.withValues(alpha: opaque ? 0.92 : 0.85));
    final agoStyle = theme.textTheme.labelSmall?.copyWith(color: onPicture.withValues(alpha: 0.75));

    final previewH = homeLineHeight(context, previewStyle);
    final titleH = cfg.showName ? homeLineHeight(context, nameStyle) : 0.0;
    final agoH = cfg.showTime ? homeLineHeight(context, agoStyle) : 0.0;
    // Matches textBlock's own padding (14 top+bottom = 28) and inter-line
    // gaps exactly, rather than a flat guess that a larger text scale (taller
    // lines, same gaps) could run past. Reserving the preview's gap whenever
    // there is a preview to show (rather than only once maxLines is known
    // positive) sidesteps the circularity — worst case it undercounts room
    // by 4px, which only ever makes maxLines smaller, never overflows.
    final previewGap = preview.isNotEmpty ? 4.0 : 0.0;
    final agoGap = cfg.showTime ? 2.0 : 0.0;
    final room = (inner.height - titleH - agoH - 28 - previewGap - agoGap)
        .clamp(0.0, inner.height);
    final maxLines = (room / previewH).floor().clamp(0, compact ? 1 : 4);

    final textBlock = Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (cfg.showName)
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: nameStyle),
          if (maxLines > 0 && preview.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(preview, maxLines: maxLines, overflow: TextOverflow.ellipsis, style: previewStyle),
          ],
          if (cfg.showTime) ...[
            const SizedBox(height: 2),
            Text(ago, maxLines: 1, style: agoStyle),
          ],
        ],
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        _background(context),
        if (opaque)
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.0),
                  Colors.black.withValues(alpha: 0.55),
                ],
                stops: const [0.4, 1.0],
              ),
            ),
          ),
        textBlock,
      ],
    );
  }

  Widget _background(BuildContext context) {
    if (avatarRef == null || avatarRef!.isEmpty) {
      return ColoredBox(color: theme.colorScheme.secondaryContainer);
    }
    final cardColor = theme.colorScheme.surfaceContainerHigh;
    final longestSide = inner.height > inner.width ? inner.height : inner.width;
    switch (cfg.bgStyle) {
      case _BgStyle.opaque:
        final provider = avatarImage(
          avatarRef!,
          displaySize: longestSide,
          devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
        );
        if (provider == null) return ColoredBox(color: theme.colorScheme.secondaryContainer);
        return Image(image: provider, fit: BoxFit.cover);
      case _BgStyle.blur:
        // Decoded small on purpose — blur hides the resolution, and a small
        // bitmap keeps this ImageFiltered's one-time raster cheap.
        final small = (longestSide / 4).clamp(32.0, 512.0);
        final provider = avatarImage(
          avatarRef!,
          displaySize: small,
          devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
        );
        if (provider == null) return ColoredBox(color: theme.colorScheme.secondaryContainer);
        return RepaintBoundary(
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 16, sigmaY: 16, tileMode: TileMode.decal),
            child: Image(image: provider, fit: BoxFit.cover),
          ),
        );
      case _BgStyle.fade:
        final provider = avatarImage(
          avatarRef!,
          displaySize: longestSide,
          devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
        );
        if (provider == null) return ColoredBox(color: theme.colorScheme.secondaryContainer);
        final begin = switch (cfg.fadeFrom) {
          _FadeFrom.bottom => Alignment.topCenter,
          _FadeFrom.top => Alignment.bottomCenter,
          _FadeFrom.left => Alignment.centerRight,
          _FadeFrom.right => Alignment.centerLeft,
        };
        final end = switch (cfg.fadeFrom) {
          _FadeFrom.bottom => Alignment.bottomCenter,
          _FadeFrom.top => Alignment.topCenter,
          _FadeFrom.left => Alignment.centerLeft,
          _FadeFrom.right => Alignment.centerRight,
        };
        return Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: cardColor),
            ShaderMask(
              shaderCallback: (rect) => LinearGradient(
                begin: begin,
                end: end,
                colors: const [Color(0xFFFFFFFF), Color(0x00FFFFFF)],
              ).createShader(rect),
              blendMode: BlendMode.dstIn,
              child: Image(image: provider, fit: BoxFit.cover),
            ),
          ],
        );
    }
  }
}

/// A gentle empty-state card, for a widget with nothing to show yet.
class HomeEmptyCard extends StatelessWidget {
  const HomeEmptyCard({
    super.key,
    required this.icon,
    required this.message,
    this.compact = false,
  });

  final IconData icon;
  final String message;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return HomeCard(
      semanticLabel: message,
      alignment: Alignment.center,
      builder: (context, inner) {
        final iconSize = inner.height >= 80 ? 28.0 : 20.0;
        final lineH = homeLineHeight(context, style);
        final wide = inner.width > inner.height * 1.6;
        final showMessage = !compact || wide;
        // A short, wide card reads best as one line: icon then words.
        // (Two lines under the icon need more height than this card has.)
        if (wide && inner.height < iconSize + 8 + lineH * 2 + 8) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: iconSize, color: theme.colorScheme.outline),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              ),
            ],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: iconSize, color: theme.colorScheme.outline),
            if (showMessage && inner.height >= iconSize + 8 + lineH) ...[
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ],
          ],
        );
      },
    );
  }
}
