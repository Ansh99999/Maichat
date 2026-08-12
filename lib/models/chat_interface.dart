import 'package:flutter/material.dart';

/// Bounds the avatar-size slider (and the drag-to-resize handle) honour, in
/// logical pixels. For [AvatarFit.free] this is the longest side of the frame.
const double kMinAvatarSize = 24;
const double kMaxAvatarSize = 160;

/// Bounds for the message font-size slider, in logical pixels.
const double kMinFontSize = 11;
const double kMaxFontSize = 26;

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
// APPEND-AVATARSTYLE

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
    this.fontSize = 16,
    this.bubbleOpacity = 1,
    this.showNames = false,
    this.userName = 'You',
    this.userTextColor,
    this.botTextColor,
    this.userBubbleColor,
    this.botBubbleColor,
    this.backgroundColor,
  });

  final AvatarStyle botAvatar;
  final AvatarStyle userAvatar;

  /// When true, the two avatar styles share a look (the settings UI edits one
  /// and mirrors it to both, keeping each role's own [ChatSide.side]).
  final bool syncAvatars;

  final TextPlacement textPlacement;

  /// Bubbles vs flat "document" turns.
  final bool bubbles;

  final double fontSize;

  /// 0..1 opacity for the bubble fill.
  final double bubbleOpacity;

  /// Whether to label each turn with its sender's name.
  final bool showNames;

  /// The user's display name (the character's own name labels its turns).
  final String userName;

  /// ARGB overrides; null defers to the theme.
  final int? userTextColor;
  final int? botTextColor;
  final int? userBubbleColor;
  final int? botBubbleColor;
  final int? backgroundColor;

  AvatarStyle avatarFor(bool isUser) => isUser ? userAvatar : botAvatar;
// APPEND-CI-2

  ChatInterface copyWith({
    AvatarStyle? botAvatar,
    AvatarStyle? userAvatar,
    bool? syncAvatars,
    TextPlacement? textPlacement,
    bool? bubbles,
    double? fontSize,
    double? bubbleOpacity,
    bool? showNames,
    String? userName,
    Object? userTextColor = _unset,
    Object? botTextColor = _unset,
    Object? userBubbleColor = _unset,
    Object? botBubbleColor = _unset,
    Object? backgroundColor = _unset,
  }) =>
      ChatInterface(
        botAvatar: botAvatar ?? this.botAvatar,
        userAvatar: userAvatar ?? this.userAvatar,
        syncAvatars: syncAvatars ?? this.syncAvatars,
        textPlacement: textPlacement ?? this.textPlacement,
        bubbles: bubbles ?? this.bubbles,
        fontSize: fontSize ?? this.fontSize,
        bubbleOpacity: bubbleOpacity ?? this.bubbleOpacity,
        showNames: showNames ?? this.showNames,
        userName: userName ?? this.userName,
        userTextColor: _pick(userTextColor, this.userTextColor),
        botTextColor: _pick(botTextColor, this.botTextColor),
        userBubbleColor: _pick(userBubbleColor, this.userBubbleColor),
        botBubbleColor: _pick(botBubbleColor, this.botBubbleColor),
        backgroundColor: _pick(backgroundColor, this.backgroundColor),
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
        'fontSize': fontSize,
        'bubbleOpacity': bubbleOpacity,
        'showNames': showNames,
        'userName': userName,
        if (userTextColor != null) 'userTextColor': userTextColor,
        if (botTextColor != null) 'botTextColor': botTextColor,
        if (userBubbleColor != null) 'userBubbleColor': userBubbleColor,
        if (botBubbleColor != null) 'botBubbleColor': botBubbleColor,
        if (backgroundColor != null) 'backgroundColor': backgroundColor,
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
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 16,
      bubbleOpacity: (json['bubbleOpacity'] as num?)?.toDouble() ?? 1,
      showNames: json['showNames'] as bool? ?? false,
      userName: json['userName'] as String? ?? 'You',
      userTextColor: (json['userTextColor'] as num?)?.toInt(),
      botTextColor: (json['botTextColor'] as num?)?.toInt(),
      userBubbleColor: (json['userBubbleColor'] as num?)?.toInt(),
      botBubbleColor: (json['botBubbleColor'] as num?)?.toInt(),
      backgroundColor: (json['backgroundColor'] as num?)?.toInt(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ChatInterface &&
      other.botAvatar == botAvatar &&
      other.userAvatar == userAvatar &&
      other.syncAvatars == syncAvatars &&
      other.textPlacement == textPlacement &&
      other.bubbles == bubbles &&
      other.fontSize == fontSize &&
      other.bubbleOpacity == bubbleOpacity &&
      other.showNames == showNames &&
      other.userName == userName &&
      other.userTextColor == userTextColor &&
      other.botTextColor == botTextColor &&
      other.userBubbleColor == userBubbleColor &&
      other.botBubbleColor == botBubbleColor &&
      other.backgroundColor == backgroundColor;

  @override
  int get hashCode => Object.hash(
        botAvatar,
        userAvatar,
        syncAvatars,
        textPlacement,
        bubbles,
        fontSize,
        bubbleOpacity,
        showNames,
        userName,
        userTextColor,
        botTextColor,
        userBubbleColor,
        botBubbleColor,
        backgroundColor,
      );
}




