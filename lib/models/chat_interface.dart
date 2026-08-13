import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Bounds the avatar-size slider (and the drag-to-resize handle) honour, in
/// logical pixels. For [AvatarFit.free] this is the longest side of the frame.
///
/// [kMaxAvatarSize] is only the slider *track* maximum — a comfortable ceiling
/// for dragging — not a hard limit. The numeric field beside the slider lets a
/// value be typed past it (up to [kAvatarHardMax], a sanity bound that just
/// keeps a fat-fingered entry from blowing up the layout).
const double kMinAvatarSize = 24;
const double kMaxAvatarSize = 320;
const double kAvatarHardMax = 2000;

/// Bounds for the message font-size slider, in logical pixels.
const double kMinFontSize = 11;
const double kMaxFontSize = 26;

/// Bounds for the sender-name font-size sliders, in logical pixels.
const double kMinNameSize = 8;
const double kMaxNameSize = 28;

/// Where a sender's name label sits across the message row.
enum NameAlign {
  start('Start'),
  center('Center'),
  end('End');

  const NameAlign(this.label);

  final String label;

  TextAlign get textAlign => switch (this) {
        NameAlign.start => TextAlign.left,
        NameAlign.center => TextAlign.center,
        NameAlign.end => TextAlign.right,
      };

  static NameAlign byName(String? name) {
    for (final a in values) {
      if (a.name == name) return a;
    }
    return NameAlign.start;
  }
}

/// Whether a sender's name label sits above or below its message (the avatar +
/// bubble group).
enum NamePosition {
  above('Above'),
  below('Below');

  const NamePosition(this.label);

  final String label;

  static NamePosition byName(String? name) {
    for (final p in values) {
      if (p.name == name) return p;
    }
    return NamePosition.above;
  }
}

/// The shape an avatar is clipped to.
enum AvatarShape {
  circle('Circle'),
  rounded('Rounded'),
  square('Square');

  const AvatarShape(this.label);

  final String label;

  static AvatarShape byName(String? name) {
    for (final s in values) {
      if (s.name == name) return s;
    }
    return AvatarShape.circle;
  }

  /// The corner radius to clip a frame [shortSide] pixels across with.
  double radiusFor(double shortSide) => switch (this) {
        AvatarShape.circle => shortSide / 2,
        AvatarShape.rounded => shortSide * 0.24,
        AvatarShape.square => 0,
      };
}

/// How an avatar image fills its frame.
///
/// [cover] crops to a square, [contain] letterboxes inside a square, and [free]
/// keeps the picture's own aspect ratio (the frame becomes non-square, bounded
/// so its longest side matches the chosen size) — so a 16:9 and a 3:4 avatar
/// each keep their real proportions.
enum AvatarFit {
  cover('Fill'),
  contain('Fit'),
  free('Free');

  const AvatarFit(this.label);

  final String label;

  static AvatarFit byName(String? name) {
    for (final f in values) {
      if (f.name == name) return f;
    }
    return AvatarFit.cover;
  }

  BoxFit get boxFit => this == AvatarFit.contain ? BoxFit.contain : BoxFit.cover;
}

/// Which side of the thread a role's turns sit on. Independent per role, so the
/// bot and the user can be on the same side (a document/log look) or opposite
/// sides (classic messenger).
enum ChatSide {
  left('Left'),
  right('Right');

  const ChatSide(this.label);

  final String label;

  bool get isLeft => this == ChatSide.left;

  static ChatSide byName(String? name, {ChatSide fallback = ChatSide.left}) {
    for (final s in values) {
      if (s.name == name) return s;
    }
    return fallback;
  }
}

/// Where a turn's text sits relative to its avatar.
enum TextPlacement {
  beside('Beside'),
  below('Below'),
  around('Around');

  const TextPlacement(this.label);

  final String label;

  static TextPlacement byName(String? name) {
    for (final p in values) {
      if (p.name == name) return p;
    }
    return TextPlacement.beside;
  }
}

/// How wide a message may grow. Matters most in "document" mode (bubbles off),
/// where without this the text keeps the bubble width and reads no differently.
/// [full] fills the row; the others cap at a readable measure.
enum ContentWidth {
  narrow('Narrow'),
  medium('Medium'),
  wide('Wide'),
  full('Full');

  const ContentWidth(this.label);

  final String label;

  /// The max message width for a row [screenWidth] wide. Fixed readable caps for
  /// the bounded modes; [full] uses the whole row (minus the bubble's own
  /// horizontal margin).
  double maxWidthFor(double screenWidth) {
    final cap = switch (this) {
      ContentWidth.narrow => 560.0,
      ContentWidth.medium => 720.0,
      ContentWidth.wide => 920.0,
      ContentWidth.full => double.infinity,
    };
    final avail = (screenWidth - 24).clamp(0.0, double.infinity);
    return cap > avail ? avail : cap;
  }

  static ContentWidth byName(String? name) {
    for (final w in values) {
      if (w.name == name) return w;
    }
    return ContentWidth.medium;
  }
}

/// Where the per-message action bar sits relative to a message.
enum ActionBarPlacement {
  belowMessage('Below message'),
  besideName('Beside name'),
  besideAvatar('Beside avatar'),
  messageRight('Right of message');

  const ActionBarPlacement(this.label);

  final String label;

  static ActionBarPlacement byName(String? name) {
    for (final p in values) {
      if (p.name == name) return p;
    }
    return ActionBarPlacement.belowMessage;
  }
}
// APPEND-AVATARSTYLE

/// A per-message action, offered either inline (as an icon beside the message)
/// or tucked into the three-dot overflow — configured per action in Chat
/// Interface settings, mirroring Agnai's `msgOptsInline` model.
enum MessageAction {
  regenerate('Regenerate', Icons.refresh),
  edit('Edit', Icons.edit_outlined),
  delete('Delete', Icons.delete_outline),
  copy('Copy', Icons.copy_outlined),
  fork('Fork', Icons.call_split),
  prompt('View prompt', Icons.terminal),
  info('Info', Icons.info_outline);

  const MessageAction(this.label, this.icon);

  final String label;
  final IconData icon;

  /// Regenerate and prompt inspection only make sense on a model turn.
  bool get assistantOnly =>
      this == MessageAction.regenerate || this == MessageAction.prompt;

  /// Whether this action is offered on a turn sent by [isUser].
  bool appliesTo(bool isUser) => !(isUser && assistantOnly);

  /// Mutating actions are disabled while a reply is still streaming.
  bool get blockedWhileStreaming =>
      this == MessageAction.regenerate ||
      this == MessageAction.edit ||
      this == MessageAction.delete ||
      this == MessageAction.fork;

  static MessageAction? byName(String? name) {
    for (final a in values) {
      if (a.name == name) return a;
    }
    return null;
  }
}

/// One action's placement: [inline] true → an icon beside the message; false →
/// inside the three-dot overflow. The list order is the display order.
class MessageActionPref {
  const MessageActionPref(this.action, {this.inline = false});

  final MessageAction action;
  final bool inline;

  MessageActionPref copyWith({bool? inline}) =>
      MessageActionPref(action, inline: inline ?? this.inline);

  Map<String, dynamic> toJson() => {'action': action.name, 'inline': inline};

  static MessageActionPref? fromJson(Map<String, dynamic> json) {
    final action = MessageAction.byName(json['action'] as String?);
    if (action == null) return null;
    return MessageActionPref(action, inline: json['inline'] as bool? ?? false);
  }

  @override
  bool operator ==(Object other) =>
      other is MessageActionPref &&
      other.action == action &&
      other.inline == inline;

  @override
  int get hashCode => Object.hash(action, inline);
}

/// The out-of-the-box placement: regenerate / edit / delete inline, the rest
/// behind the overflow — uncluttered, and freely reorderable by the user.
const List<MessageActionPref> kDefaultMessageActions = [
  MessageActionPref(MessageAction.regenerate, inline: true),
  MessageActionPref(MessageAction.edit, inline: true),
  MessageActionPref(MessageAction.delete, inline: true),
  MessageActionPref(MessageAction.copy),
  MessageActionPref(MessageAction.fork),
  MessageActionPref(MessageAction.prompt),
  MessageActionPref(MessageAction.info),
];

/// Normalises a loaded list: drops unknown/duplicate actions and appends any
/// action missing from it (e.g. one introduced in a later version) as a menu
/// item, so the set is always complete and stable across upgrades.
List<MessageActionPref> normalizeMessageActions(
    List<MessageActionPref> loaded) {
  final seen = <MessageAction>{};
  final out = <MessageActionPref>[];
  for (final pref in loaded) {
    if (seen.add(pref.action)) out.add(pref);
  }
  for (final a in MessageAction.values) {
    if (!seen.contains(a)) out.add(MessageActionPref(a));
  }
  return out;
}

/// One role's avatar settings. The user's and the character's are held
/// separately on [ChatInterface] so each can be tuned independently (or kept in
/// step via [ChatInterface.syncAvatars]).
///
/// [offsetX]/[offsetY] are a free-form nudge from the anchored spot — what the
/// preview's drag-to-move writes back.
class AvatarStyle {
  const AvatarStyle({
    this.show = true,
    this.size = 44,
    this.shape = AvatarShape.circle,
    this.fit = AvatarFit.cover,
    this.side = ChatSide.left,
    this.offsetX = 0,
    this.offsetY = 0,
  });

  final bool show;
  final double size;
  final AvatarShape shape;
  final AvatarFit fit;
  final ChatSide side;
  final double offsetX;
  final double offsetY;

  Offset get offset => Offset(offsetX, offsetY);

  AvatarStyle copyWith({
    bool? show,
    double? size,
    AvatarShape? shape,
    AvatarFit? fit,
    ChatSide? side,
    double? offsetX,
    double? offsetY,
  }) =>
      AvatarStyle(
        show: show ?? this.show,
        size: size ?? this.size,
        shape: shape ?? this.shape,
        fit: fit ?? this.fit,
        side: side ?? this.side,
        offsetX: offsetX ?? this.offsetX,
        offsetY: offsetY ?? this.offsetY,
      );

  /// Copies everything about [other] except which [side] this role sits on, so
  /// "sync" can share look-and-feel while each role keeps its own side.
  AvatarStyle matchLook(AvatarStyle other) => other.copyWith(side: side);

  Map<String, dynamic> toJson() => {
        'show': show,
        'size': size,
        'shape': shape.name,
        'fit': fit.name,
        'side': side.name,
        'offsetX': offsetX,
        'offsetY': offsetY,
      };

  factory AvatarStyle.fromJson(
    Map<String, dynamic> json, {
    ChatSide defaultSide = ChatSide.left,
  }) =>
      AvatarStyle(
        show: json['show'] as bool? ?? true,
        size: (json['size'] as num?)?.toDouble() ?? 44,
        shape: AvatarShape.byName(json['shape'] as String?),
        fit: AvatarFit.byName(json['fit'] as String?),
        side: ChatSide.byName(json['side'] as String?, fallback: defaultSide),
        offsetX: (json['offsetX'] as num?)?.toDouble() ?? 0,
        offsetY: (json['offsetY'] as num?)?.toDouble() ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      other is AvatarStyle &&
      other.show == show &&
      other.size == size &&
      other.shape == shape &&
      other.fit == fit &&
      other.side == side &&
      other.offsetX == offsetX &&
      other.offsetY == offsetY;

  @override
  int get hashCode =>
      Object.hash(show, size, shape, fit, side, offsetX, offsetY);
}
// APPEND-CHATINTERFACE

/// Everything the "Chat Interface" section controls. Avatars are configured per
/// role ([botAvatar]/[userAvatar]); [syncAvatars] keeps their look in step.
/// Turns can be drawn as tinted bubbles or flat ("document" style), with each
/// role free to sit on either side. Names, font size, and per-role colour
/// overrides round it out; a null colour follows the app theme.
class ChatInterface {
  const ChatInterface({
    this.botAvatar = const AvatarStyle(side: ChatSide.left),
    this.userAvatar = const AvatarStyle(side: ChatSide.right),
    this.syncAvatars = false,
    this.textPlacement = TextPlacement.beside,
    this.bubbles = true,
    this.contentWidth = ContentWidth.medium,
    this.fontSize = 16,
    this.bubbleOpacity = 1,
    this.showNames = false,
    this.userName = 'You',
    this.botNameSize = 12,
    this.userNameSize = 12,
    this.botNameAlign = NameAlign.start,
    this.userNameAlign = NameAlign.start,
    this.botNamePosition = NamePosition.above,
    this.userNamePosition = NamePosition.above,
    this.markdown = true,
    this.userTextColor,
    this.botTextColor,
    this.userBubbleColor,
    this.botBubbleColor,
    this.backgroundColor,
    this.emphasisColor,
    this.quoteColor,
    this.messageActionsEnabled = true,
    this.messageActions = kDefaultMessageActions,
    this.actionBarPlacement = ActionBarPlacement.belowMessage,
  });

  final AvatarStyle botAvatar;
  final AvatarStyle userAvatar;

  /// When true, the two avatar styles share a look (the settings UI edits one
  /// and mirrors it to both, keeping each role's own [ChatSide.side]).
  final bool syncAvatars;

  final TextPlacement textPlacement;

  /// Bubbles vs flat "document" turns.
  final bool bubbles;

  /// How wide a message may grow (esp. in document mode).
  final ContentWidth contentWidth;

  final double fontSize;

  /// 0..1 opacity for the bubble fill.
  final double bubbleOpacity;

  /// Whether to label each turn with its sender's name.
  final bool showNames;

  /// The user's display name (the character's own name labels its turns). Used
  /// as the fallback label when the user is not impersonating a character.
  final String userName;

  /// Font size (logical px) for each role's sender-name label, and where that
  /// label sits across the message row.
  final double botNameSize;
  final double userNameSize;
  final NameAlign botNameAlign;
  final NameAlign userNameAlign;

  /// Whether each role's name sits above or below its message.
  final NamePosition botNamePosition;
  final NamePosition userNamePosition;

  /// Whether message text is rendered as markdown (bold/italic/quotes/code…).
  final bool markdown;

  /// ARGB overrides; null defers to the theme.
  final int? userTextColor;
  final int? botTextColor;
  final int? userBubbleColor;
  final int? botBubbleColor;
  final int? backgroundColor;

  /// Colour for emphasised (*italic* / **bold**) text; null follows the text.
  final int? emphasisColor;

  /// Colour for text inside "quotes"; null follows the text.
  final int? quoteColor;

  /// Whether the inline per-message action bar is shown at all. When off, only
  /// the long-press action sheet remains.
  final bool messageActionsEnabled;

  /// Per-action placement (inline icon vs three-dot overflow), in display order.
  /// Always the full set of [MessageAction]s once normalised.
  final List<MessageActionPref> messageActions;

  /// Where the action bar sits relative to a message.
  final ActionBarPlacement actionBarPlacement;

  /// The inline actions, in order.
  List<MessageAction> get inlineActions => [
        for (final p in messageActions)
          if (p.inline) p.action,
      ];

  /// The overflow ("three-dot") actions, in order.
  List<MessageAction> get overflowActions => [
        for (final p in messageActions)
          if (!p.inline) p.action,
      ];

  AvatarStyle avatarFor(bool isUser) => isUser ? userAvatar : botAvatar;
// APPEND-CI-2

  ChatInterface copyWith({
    AvatarStyle? botAvatar,
    AvatarStyle? userAvatar,
    bool? syncAvatars,
    TextPlacement? textPlacement,
    bool? bubbles,
    ContentWidth? contentWidth,
    double? fontSize,
    double? bubbleOpacity,
    bool? showNames,
    String? userName,
    double? botNameSize,
    double? userNameSize,
    NameAlign? botNameAlign,
    NameAlign? userNameAlign,
    NamePosition? botNamePosition,
    NamePosition? userNamePosition,
    bool? markdown,
    Object? userTextColor = _unset,
    Object? botTextColor = _unset,
    Object? userBubbleColor = _unset,
    Object? botBubbleColor = _unset,
    Object? backgroundColor = _unset,
    Object? emphasisColor = _unset,
    Object? quoteColor = _unset,
    bool? messageActionsEnabled,
    List<MessageActionPref>? messageActions,
    ActionBarPlacement? actionBarPlacement,
  }) =>
      ChatInterface(
        botAvatar: botAvatar ?? this.botAvatar,
        userAvatar: userAvatar ?? this.userAvatar,
        syncAvatars: syncAvatars ?? this.syncAvatars,
        textPlacement: textPlacement ?? this.textPlacement,
        bubbles: bubbles ?? this.bubbles,
        contentWidth: contentWidth ?? this.contentWidth,
        fontSize: fontSize ?? this.fontSize,
        bubbleOpacity: bubbleOpacity ?? this.bubbleOpacity,
        showNames: showNames ?? this.showNames,
        userName: userName ?? this.userName,
        botNameSize: botNameSize ?? this.botNameSize,
        userNameSize: userNameSize ?? this.userNameSize,
        botNameAlign: botNameAlign ?? this.botNameAlign,
        userNameAlign: userNameAlign ?? this.userNameAlign,
        botNamePosition: botNamePosition ?? this.botNamePosition,
        userNamePosition: userNamePosition ?? this.userNamePosition,
        markdown: markdown ?? this.markdown,
        userTextColor: _pick(userTextColor, this.userTextColor),
        botTextColor: _pick(botTextColor, this.botTextColor),
        userBubbleColor: _pick(userBubbleColor, this.userBubbleColor),
        botBubbleColor: _pick(botBubbleColor, this.botBubbleColor),
        backgroundColor: _pick(backgroundColor, this.backgroundColor),
        emphasisColor: _pick(emphasisColor, this.emphasisColor),
        quoteColor: _pick(quoteColor, this.quoteColor),
        messageActionsEnabled:
            messageActionsEnabled ?? this.messageActionsEnabled,
        messageActions: messageActions ?? this.messageActions,
        actionBarPlacement: actionBarPlacement ?? this.actionBarPlacement,
      );

  /// Writes [style] to one role and, when [syncAvatars] is on, mirrors its look
  /// to the other role (each keeps its own side).
  ChatInterface withAvatar(bool isUser, AvatarStyle style) {
    if (!syncAvatars) {
      return isUser ? copyWith(userAvatar: style) : copyWith(botAvatar: style);
    }
    return copyWith(
      userAvatar: isUser ? style : userAvatar.matchLook(style),
      botAvatar: isUser ? botAvatar.matchLook(style) : style,
    );
  }

  // Sentinel so copyWith can tell "leave the colour" from "clear it to null".
  static const Object _unset = Object();
  static int? _pick(Object? next, int? current) =>
      identical(next, _unset) ? current : next as int?;
// APPEND-CI-3

  Map<String, dynamic> toJson() => {
        'botAvatar': botAvatar.toJson(),
        'userAvatar': userAvatar.toJson(),
        'syncAvatars': syncAvatars,
        'textPlacement': textPlacement.name,
        'bubbles': bubbles,
        'contentWidth': contentWidth.name,
        'fontSize': fontSize,
        'bubbleOpacity': bubbleOpacity,
        'showNames': showNames,
        'userName': userName,
        'botNameSize': botNameSize,
        'userNameSize': userNameSize,
        'botNameAlign': botNameAlign.name,
        'userNameAlign': userNameAlign.name,
        'botNamePosition': botNamePosition.name,
        'userNamePosition': userNamePosition.name,
        'markdown': markdown,
        if (userTextColor != null) 'userTextColor': userTextColor,
        if (botTextColor != null) 'botTextColor': botTextColor,
        if (userBubbleColor != null) 'userBubbleColor': userBubbleColor,
        if (botBubbleColor != null) 'botBubbleColor': botBubbleColor,
        if (backgroundColor != null) 'backgroundColor': backgroundColor,
        if (emphasisColor != null) 'emphasisColor': emphasisColor,
        if (quoteColor != null) 'quoteColor': quoteColor,
        'messageActionsEnabled': messageActionsEnabled,
        'messageActions': messageActions.map((p) => p.toJson()).toList(),
        'actionBarPlacement': actionBarPlacement.name,
      };

  factory ChatInterface.fromJson(Map<String, dynamic> json) {
    AvatarStyle bot;
    AvatarStyle user;
    if (json['botAvatar'] is Map || json['userAvatar'] is Map) {
      bot = AvatarStyle.fromJson(
        (json['botAvatar'] as Map?)?.cast<String, dynamic>() ?? const {},
        defaultSide: ChatSide.left,
      );
      user = AvatarStyle.fromJson(
        (json['userAvatar'] as Map?)?.cast<String, dynamic>() ?? const {},
        defaultSide: ChatSide.right,
      );
    } else {
      // Migrate the old single-avatar shape: apply the flat fields to both
      // roles, differing only in their default side.
      final flat = AvatarStyle(
        show: json['showAvatars'] as bool? ?? true,
        size: (json['avatarSize'] as num?)?.toDouble() ?? 44,
        shape: AvatarShape.byName(json['avatarShape'] as String?),
        fit: AvatarFit.byName(json['avatarFit'] as String?),
        offsetX: (json['avatarOffsetX'] as num?)?.toDouble() ?? 0,
        offsetY: (json['avatarOffsetY'] as num?)?.toDouble() ?? 0,
      );
      bot = flat.copyWith(side: ChatSide.left);
      user = flat.copyWith(side: ChatSide.right);
    }
    return ChatInterface(
      botAvatar: bot,
      userAvatar: user,
      syncAvatars: json['syncAvatars'] as bool? ?? false,
      textPlacement: TextPlacement.byName(json['textPlacement'] as String?),
      bubbles: json['bubbles'] as bool? ?? true,
      contentWidth: ContentWidth.byName(json['contentWidth'] as String?),
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 16,
      bubbleOpacity: (json['bubbleOpacity'] as num?)?.toDouble() ?? 1,
      showNames: json['showNames'] as bool? ?? false,
      userName: json['userName'] as String? ?? 'You',
      botNameSize: (json['botNameSize'] as num?)?.toDouble() ?? 12,
      userNameSize: (json['userNameSize'] as num?)?.toDouble() ?? 12,
      botNameAlign: NameAlign.byName(json['botNameAlign'] as String?),
      userNameAlign: NameAlign.byName(json['userNameAlign'] as String?),
      botNamePosition: NamePosition.byName(json['botNamePosition'] as String?),
      userNamePosition: NamePosition.byName(json['userNamePosition'] as String?),
      markdown: json['markdown'] as bool? ?? true,
      userTextColor: (json['userTextColor'] as num?)?.toInt(),
      botTextColor: (json['botTextColor'] as num?)?.toInt(),
      userBubbleColor: (json['userBubbleColor'] as num?)?.toInt(),
      botBubbleColor: (json['botBubbleColor'] as num?)?.toInt(),
      backgroundColor: (json['backgroundColor'] as num?)?.toInt(),
      emphasisColor: (json['emphasisColor'] as num?)?.toInt(),
      quoteColor: (json['quoteColor'] as num?)?.toInt(),
      messageActionsEnabled: json['messageActionsEnabled'] as bool? ?? true,
      messageActions: _messageActionsFromJson(json['messageActions']),
      actionBarPlacement:
          ActionBarPlacement.byName(json['actionBarPlacement'] as String?),
    );
  }

  /// Reads a stored action-placement list, tolerating absence (→ defaults),
  /// unknown action names and an incomplete set (missing actions are appended
  /// as overflow items by [normalizeMessageActions]).
  static List<MessageActionPref> _messageActionsFromJson(Object? value) {
    if (value is! List) return kDefaultMessageActions;
    final loaded = <MessageActionPref>[];
    for (final e in value) {
      if (e is Map<String, dynamic>) {
        final pref = MessageActionPref.fromJson(e);
        if (pref != null) loaded.add(pref);
      }
    }
    if (loaded.isEmpty) return kDefaultMessageActions;
    return normalizeMessageActions(loaded);
  }

  @override
  bool operator ==(Object other) =>
      other is ChatInterface &&
      other.botAvatar == botAvatar &&
      other.userAvatar == userAvatar &&
      other.syncAvatars == syncAvatars &&
      other.textPlacement == textPlacement &&
      other.bubbles == bubbles &&
      other.contentWidth == contentWidth &&
      other.fontSize == fontSize &&
      other.bubbleOpacity == bubbleOpacity &&
      other.showNames == showNames &&
      other.userName == userName &&
      other.botNameSize == botNameSize &&
      other.userNameSize == userNameSize &&
      other.botNameAlign == botNameAlign &&
      other.userNameAlign == userNameAlign &&
      other.botNamePosition == botNamePosition &&
      other.userNamePosition == userNamePosition &&
      other.markdown == markdown &&
      other.userTextColor == userTextColor &&
      other.botTextColor == botTextColor &&
      other.userBubbleColor == userBubbleColor &&
      other.botBubbleColor == botBubbleColor &&
      other.backgroundColor == backgroundColor &&
      other.emphasisColor == emphasisColor &&
      other.quoteColor == quoteColor &&
      other.messageActionsEnabled == messageActionsEnabled &&
      listEquals(other.messageActions, messageActions) &&
      other.actionBarPlacement == actionBarPlacement;

  @override
  int get hashCode => Object.hash(
        botAvatar,
        userAvatar,
        syncAvatars,
        textPlacement,
        Object.hash(bubbles, contentWidth),
        fontSize,
        bubbleOpacity,
        showNames,
        userName,
        Object.hash(botNameSize, userNameSize, botNameAlign, userNameAlign,
            botNamePosition, userNamePosition),
        markdown,
        userTextColor,
        botTextColor,
        userBubbleColor,
        botBubbleColor,
        backgroundColor,
        emphasisColor,
        quoteColor,
        Object.hash(messageActionsEnabled, actionBarPlacement),
        Object.hashAll(messageActions),
      );
}




