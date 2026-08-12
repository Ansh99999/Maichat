import 'package:flutter/material.dart';

/// Bounds the avatar-size slider (and the drag-to-resize handle) honour, in
/// logical pixels of diameter.
const double kMinAvatarSize = 24;
const double kMaxAvatarSize = 128;

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

  /// The corner radius to clip a [size]-diameter avatar with.
  double radiusFor(double size) => switch (this) {
        AvatarShape.circle => size / 2,
        AvatarShape.rounded => size * 0.24,
        AvatarShape.square => 0,
      };
}

/// How an avatar image fills its (possibly non-square) frame.
enum AvatarFit {
  cover('Fill'),
  contain('Fit');

  const AvatarFit(this.label);

  final String label;

  static AvatarFit byName(String? name) {
    for (final f in values) {
      if (f.name == name) return f;
    }
    return AvatarFit.cover;
  }

  BoxFit get boxFit => this == AvatarFit.cover ? BoxFit.cover : BoxFit.contain;
}

/// Where a turn's text sits relative to its avatar — the "text placement"
/// choice: beside the avatar (classic messenger row), below it (avatar on top),
/// or wrapped around a floated avatar.
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
/// Everything the "Chat Interface" settings section controls: how avatars are
/// sized and shaped, where the text sits relative to them, whether turns are
/// drawn as bubbles or flat, the message font size, and a set of optional
/// colour overrides. A null colour means "follow the app theme".
///
/// [avatarOffsetX]/[avatarOffsetY] are a free-form nudge applied to the avatar
/// from its anchored spot — the value the preview's drag-to-move writes back,
/// giving the "put the avatar wherever you like" behaviour.
class ChatInterface {
  const ChatInterface({
    this.showAvatars = true,
    this.avatarSize = 44,
    this.avatarShape = AvatarShape.circle,
    this.avatarFit = AvatarFit.cover,
    this.textPlacement = TextPlacement.beside,
    this.bubbles = true,
    this.fontSize = 16,
    this.bubbleOpacity = 1,
    this.userTextColor,
    this.botTextColor,
    this.userBubbleColor,
    this.botBubbleColor,
    this.backgroundColor,
    this.avatarOffsetX = 0,
    this.avatarOffsetY = 0,
  });

  final bool showAvatars;
  final double avatarSize;
  final AvatarShape avatarShape;
  final AvatarFit avatarFit;
  final TextPlacement textPlacement;
  final bool bubbles;
  final double fontSize;

  /// 0..1 opacity for the bubble fill, so bubbles can be softened over a
  /// background without affecting the text.
  final double bubbleOpacity;

  /// ARGB overrides; null defers to the theme.
  final int? userTextColor;
  final int? botTextColor;
  final int? userBubbleColor;
  final int? botBubbleColor;
  final int? backgroundColor;

  final double avatarOffsetX;
  final double avatarOffsetY;

  Offset get avatarOffset => Offset(avatarOffsetX, avatarOffsetY);

  ChatInterface copyWith({
    bool? showAvatars,
    double? avatarSize,
    AvatarShape? avatarShape,
    AvatarFit? avatarFit,
    TextPlacement? textPlacement,
    bool? bubbles,
    double? fontSize,
    double? bubbleOpacity,
    Object? userTextColor = _unset,
    Object? botTextColor = _unset,
    Object? userBubbleColor = _unset,
    Object? botBubbleColor = _unset,
    Object? backgroundColor = _unset,
    double? avatarOffsetX,
    double? avatarOffsetY,
  }) =>
      ChatInterface(
        showAvatars: showAvatars ?? this.showAvatars,
        avatarSize: avatarSize ?? this.avatarSize,
        avatarShape: avatarShape ?? this.avatarShape,
        avatarFit: avatarFit ?? this.avatarFit,
        textPlacement: textPlacement ?? this.textPlacement,
        bubbles: bubbles ?? this.bubbles,
        fontSize: fontSize ?? this.fontSize,
        bubbleOpacity: bubbleOpacity ?? this.bubbleOpacity,
        userTextColor: _pick(userTextColor, this.userTextColor),
        botTextColor: _pick(botTextColor, this.botTextColor),
        userBubbleColor: _pick(userBubbleColor, this.userBubbleColor),
        botBubbleColor: _pick(botBubbleColor, this.botBubbleColor),
        backgroundColor: _pick(backgroundColor, this.backgroundColor),
        avatarOffsetX: avatarOffsetX ?? this.avatarOffsetX,
        avatarOffsetY: avatarOffsetY ?? this.avatarOffsetY,
      );

  // Sentinel so copyWith can distinguish "leave the colour" from "clear it to
  // null" (follow the theme).
  static const Object _unset = Object();
  static int? _pick(Object? next, int? current) =>
      identical(next, _unset) ? current : next as int?;

  Map<String, dynamic> toJson() => {
        'showAvatars': showAvatars,
        'avatarSize': avatarSize,
        'avatarShape': avatarShape.name,
        'avatarFit': avatarFit.name,
        'textPlacement': textPlacement.name,
        'bubbles': bubbles,
        'fontSize': fontSize,
        'bubbleOpacity': bubbleOpacity,
        if (userTextColor != null) 'userTextColor': userTextColor,
        if (botTextColor != null) 'botTextColor': botTextColor,
        if (userBubbleColor != null) 'userBubbleColor': userBubbleColor,
        if (botBubbleColor != null) 'botBubbleColor': botBubbleColor,
        if (backgroundColor != null) 'backgroundColor': backgroundColor,
        'avatarOffsetX': avatarOffsetX,
        'avatarOffsetY': avatarOffsetY,
      };

  factory ChatInterface.fromJson(Map<String, dynamic> json) => ChatInterface(
        showAvatars: json['showAvatars'] as bool? ?? true,
        avatarSize: (json['avatarSize'] as num?)?.toDouble() ?? 44,
        avatarShape: AvatarShape.byName(json['avatarShape'] as String?),
        avatarFit: AvatarFit.byName(json['avatarFit'] as String?),
        textPlacement: TextPlacement.byName(json['textPlacement'] as String?),
        bubbles: json['bubbles'] as bool? ?? true,
        fontSize: (json['fontSize'] as num?)?.toDouble() ?? 16,
        bubbleOpacity: (json['bubbleOpacity'] as num?)?.toDouble() ?? 1,
        userTextColor: (json['userTextColor'] as num?)?.toInt(),
        botTextColor: (json['botTextColor'] as num?)?.toInt(),
        userBubbleColor: (json['userBubbleColor'] as num?)?.toInt(),
        botBubbleColor: (json['botBubbleColor'] as num?)?.toInt(),
        backgroundColor: (json['backgroundColor'] as num?)?.toInt(),
        avatarOffsetX: (json['avatarOffsetX'] as num?)?.toDouble() ?? 0,
        avatarOffsetY: (json['avatarOffsetY'] as num?)?.toDouble() ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      other is ChatInterface &&
      other.showAvatars == showAvatars &&
      other.avatarSize == avatarSize &&
      other.avatarShape == avatarShape &&
      other.avatarFit == avatarFit &&
      other.textPlacement == textPlacement &&
      other.bubbles == bubbles &&
      other.fontSize == fontSize &&
      other.bubbleOpacity == bubbleOpacity &&
      other.userTextColor == userTextColor &&
      other.botTextColor == botTextColor &&
      other.userBubbleColor == userBubbleColor &&
      other.botBubbleColor == botBubbleColor &&
      other.backgroundColor == backgroundColor &&
      other.avatarOffsetX == avatarOffsetX &&
      other.avatarOffsetY == avatarOffsetY;

  @override
  int get hashCode => Object.hash(
        showAvatars,
        avatarSize,
        avatarShape,
        avatarFit,
        textPlacement,
        bubbles,
        fontSize,
        bubbleOpacity,
        userTextColor,
        botTextColor,
        userBubbleColor,
        botBubbleColor,
        backgroundColor,
        avatarOffsetX,
        avatarOffsetY,
      );
}

