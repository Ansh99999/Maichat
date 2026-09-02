import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'text_wrap.dart';

export 'text_wrap.dart';

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

/// Bounds for the sender-name font-size sliders, in logical pixels. The ceiling
/// is deliberately generous — a name can be a headline over its message, not
/// just a caption.
const double kMinNameSize = 8;
const double kMaxNameSize = 100;

/// Bounds for the gap between consecutive messages, in logical pixels. The
/// default leaves a clear break between turns — tight enough to read as one
/// thread, wide enough that two neighbouring avatars never touch.
const double kMinMessageSpacing = 0;
const double kMaxMessageSpacing = 48;
const double kDefaultMessageSpacing = 14;

/// How far a name label may be nudged from its anchored spot, in logical
/// pixels — the bound both the preview's drag and the settings sliders honour.
const double kMaxNameOffset = 100;

/// The same bound for an avatar, which is allowed to travel further because it
/// is often being pulled clear of a tall turn rather than snugged up to a line
/// of text. Honoured by the preview's drag and by the settings nudge pad.
const double kMaxAvatarNudge = 200;

/// Bounds for the group-chat participant bar's height, in logical pixels. The
/// default is one comfortable row of avatar chips; the ceiling allows two rows.
const double kMinGroupBarHeight = 44;
const double kMaxGroupBarHeight = 160;
const double kDefaultGroupBarHeight = 64;

/// Bounds for the opacity of the two buttons that float over a conversation —
/// the menu square at the top-left and the jump-to-latest arrow at the
/// bottom-right. Literal opacity: 1 is a solid button, the default is half
/// visible, so the chat reads through its own chrome.
///
/// The floor is deliberately *not* 0. Both buttons are the plain way to reach
/// what they do, and a control that cannot be seen but still swallows the tap
/// meant for the message underneath is worse than a faint one.
const double kMinChromeOpacity = 0.1;
const double kMaxChromeOpacity = 1;
const double kDefaultChromeOpacity = 0.5;

/// How deep into the conversation a response hint may be injected, counted in
/// messages from the newest end. 0 puts it after the last turn — right in front
/// of the reply it is steering, which is where Agnai puts its own hint. The
/// ceiling is a whole screenful of turns back, past which a hint stops reading
/// as guidance for *this* reply.
const int kMinResponseHintDepth = 0;
const int kMaxResponseHintDepth = 20;
const int kDefaultResponseHintDepth = 0;

/// Where a sender's name label sits across the message row. The label spans the
/// whole row, so this aligns it against the *screen*, not against the message it
/// belongs to: "Right" really means the right edge of the chat.
enum NameAlign {
  start('Left'),
  center('Center'),
  end('Right');

  const NameAlign(this.label);

  final String label;

  TextAlign get textAlign => switch (this) {
        NameAlign.start => TextAlign.left,
        NameAlign.center => TextAlign.center,
        NameAlign.end => TextAlign.right,
      };

  /// Where to place the label within the full-width band it is drawn in.
  Alignment get alignment => switch (this) {
        NameAlign.start => Alignment.centerLeft,
        NameAlign.center => Alignment.center,
        NameAlign.end => Alignment.centerRight,
      };

  static NameAlign byName(String? name) {
    for (final a in values) {
      if (a.name == name) return a;
    }
    return NameAlign.start;
  }
}

/// Whether a sender's name label sits above its message or below its avatar.
///
/// [above] puts it over the whole turn; [below] hangs it under the avatar, in the
/// empty space beside the text — falling back to under the message when this turn
/// has no standalone avatar to hang from.
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

/// How far a [AvatarShape.rounded] avatar's corners are actually rounded, as a
/// t-shirt-sized scale. The value is a fraction of the frame's short side, so a
/// level looks the same at any avatar size.
///
/// [m] is the default — noticeably softer than a square, well short of a
/// squircle. The old single "Rounded" look was 0.24, which sits at [xl].
enum CornerRounding {
  none('None', 0),
  xxs('XXS', 0.04),
  xs('XS', 0.07),
  s('S', 0.10),
  m('M', 0.14),
  l('L', 0.18),
  xl('XL', 0.24),
  xxl('XXL', 0.32);

  const CornerRounding(this.label, this.factor);

  final String label;

  /// Radius as a fraction of the frame's short side.
  final double factor;

  static CornerRounding byName(String? name) {
    for (final r in values) {
      if (r.name == name) return r;
    }
    return CornerRounding.m;
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

  /// The corner radius to clip a frame [shortSide] pixels across with. Only
  /// [rounded] consults [rounding]; a circle is always half the short side and
  /// a square is always sharp.
  double radiusFor(double shortSide,
          {CornerRounding rounding = CornerRounding.m}) =>
      switch (this) {
        AvatarShape.circle => shortSide / 2,
        AvatarShape.rounded => shortSide * rounding.factor,
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
  oppositeName('Opposite name'),
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
  // The enum *name* stays `fork` — it is the persisted json key — while the
  // label reads "Branch", which is what the Chat Graph calls the result.
  fork('Branch', Icons.call_split),
  prompt('View prompt', Icons.terminal),
  info('Info', Icons.info_outline),
  // Opens the image studio with this turn's text as the prompt. Independent of
  // the chat's own model — generation goes to the studio's endpoint — so it
  // applies to either speaker and is never blocked by a reply in flight.
  imagine('Generate image', Icons.auto_awesome_outlined);

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
  MessageActionPref(MessageAction.imagine),
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
    this.corner = CornerRounding.m,
    this.fit = AvatarFit.cover,
    this.side = ChatSide.left,
    this.offsetX = 0,
    this.offsetY = 0,
  });

  final bool show;
  final double size;
  final AvatarShape shape;

  /// How far [AvatarShape.rounded] corners are rounded; ignored by the circle
  /// and square shapes.
  final CornerRounding corner;

  final AvatarFit fit;
  final ChatSide side;
  final double offsetX;
  final double offsetY;

  Offset get offset => Offset(offsetX, offsetY);

  /// The clip radius for a frame [shortSide] pixels across, honouring both the
  /// shape and (for a rounded one) the chosen level.
  double radiusFor(double shortSide) =>
      shape.radiusFor(shortSide, rounding: corner);

  /// A short human label for the current corner treatment — "Circle",
  /// "Square", or e.g. "Rounded · M".
  String get cornerLabel => shape == AvatarShape.rounded
      ? '${shape.label} · ${corner.label}'
      : shape.label;

  AvatarStyle copyWith({
    bool? show,
    double? size,
    AvatarShape? shape,
    CornerRounding? corner,
    AvatarFit? fit,
    ChatSide? side,
    double? offsetX,
    double? offsetY,
  }) =>
      AvatarStyle(
        show: show ?? this.show,
        size: size ?? this.size,
        shape: shape ?? this.shape,
        corner: corner ?? this.corner,
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
        'corner': corner.name,
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
        corner: CornerRounding.byName(json['corner'] as String?),
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
      other.corner == corner &&
      other.fit == fit &&
      other.side == side &&
      other.offsetX == offsetX &&
      other.offsetY == offsetY;

  @override
  int get hashCode =>
      Object.hash(show, size, shape, corner, fit, side, offsetX, offsetY);
}
// APPEND-CHATINTERFACE

/// One role's sender-name label: its type (size and optional Google font),
/// where it sits relative to its anchor, and a free-form nudge from that spot.
///
/// [offsetX]/[offsetY] are what the preview's drag-to-move writes back — the
/// lever for pulling a name down towards the message body it belongs to. Like
/// [AvatarStyle.offset] they move the label without disturbing the layout
/// around it.
class NameStyle {
  const NameStyle({
    this.size = 12,
    this.align = NameAlign.start,
    this.position = NamePosition.above,
    this.fontFamily,
    this.color,
    this.offsetX = 0,
    this.offsetY = 0,
  });

  final double size;
  final NameAlign align;
  final NamePosition position;

  /// A Google Fonts family for this name only; null follows the app font.
  final String? fontFamily;

  /// ARGB colour for this name only; null follows the theme.
  final int? color;

  final double offsetX;
  final double offsetY;

  Offset get offset => Offset(offsetX, offsetY);

  bool get isNudged => offsetX != 0 || offsetY != 0;

  String get summary =>
      '${size.round()} px · ${position.label} · ${align.label}'
      '${fontFamily == null ? '' : ' · $fontFamily'}';

  NameStyle copyWith({
    double? size,
    NameAlign? align,
    NamePosition? position,
    Object? fontFamily = _unsetName,
    Object? color = _unsetName,
    double? offsetX,
    double? offsetY,
  }) =>
      NameStyle(
        size: size ?? this.size,
        align: align ?? this.align,
        position: position ?? this.position,
        fontFamily: identical(fontFamily, _unsetName)
            ? this.fontFamily
            : fontFamily as String?,
        color: identical(color, _unsetName) ? this.color : color as int?,
        offsetX: offsetX ?? this.offsetX,
        offsetY: offsetY ?? this.offsetY,
      );

  // Sentinel so copyWith can tell "leave it" from "clear it to null".
  static const Object _unsetName = Object();

  Map<String, dynamic> toJson() => {
        'size': size,
        'align': align.name,
        'position': position.name,
        if (fontFamily != null) 'fontFamily': fontFamily,
        if (color != null) 'color': color,
        'offsetX': offsetX,
        'offsetY': offsetY,
      };

  /// Reads a stored style, falling back per field to [fallback] — which is how
  /// the pre-[NameStyle] flat keys (`botNameSize`, `botNameAlign`, …) are
  /// migrated: they are read into a fallback and this factory fills the rest.
  factory NameStyle.fromJson(
    Map<String, dynamic> json, {
    NameStyle fallback = const NameStyle(),
  }) =>
      NameStyle(
        size: (json['size'] as num?)?.toDouble() ?? fallback.size,
        align: json['align'] == null
            ? fallback.align
            : NameAlign.byName(json['align'] as String?),
        position: json['position'] == null
            ? fallback.position
            : NamePosition.byName(json['position'] as String?),
        fontFamily: json['fontFamily'] as String? ?? fallback.fontFamily,
        color: (json['color'] as num?)?.toInt() ?? fallback.color,
        offsetX: (json['offsetX'] as num?)?.toDouble() ?? fallback.offsetX,
        offsetY: (json['offsetY'] as num?)?.toDouble() ?? fallback.offsetY,
      );

  @override
  bool operator ==(Object other) =>
      other is NameStyle &&
      other.size == size &&
      other.align == align &&
      other.position == position &&
      other.fontFamily == fontFamily &&
      other.color == color &&
      other.offsetX == offsetX &&
      other.offsetY == offsetY;

  @override
  int get hashCode => Object.hash(
      size, align, position, fontFamily, color, offsetX, offsetY);
}

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
    this.messageSpacing = kDefaultMessageSpacing,
    this.bubbleOpacity = 1,
    this.showNames = false,
    this.userName = 'You',
    this.botNameStyle = const NameStyle(),
    this.userNameStyle = const NameStyle(align: NameAlign.end),
    this.syncNames = false,
    this.markdown = true,
    this.userTextColor,
    this.botTextColor,
    this.userBubbleColor,
    this.botBubbleColor,
    this.backgroundColor,
    this.emphasisColor,
    this.quoteColor,
    this.textWrapRules = const [],
    this.messageActionsEnabled = true,
    this.messageActions = kDefaultMessageActions,
    this.actionBarPlacement = ActionBarPlacement.belowMessage,
    this.groupChatsEnabled = false,
    this.groupBarHeight = kDefaultGroupBarHeight,
    this.groupBarColor,
    this.groupBarImage,
    this.responseHintEnabled = false,
    this.responseHintDepth = kDefaultResponseHintDepth,
    this.menuButtonOpacity = kDefaultChromeOpacity,
    this.jumpButtonOpacity = kDefaultChromeOpacity,
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

  /// The gap between consecutive messages, in logical pixels — split evenly
  /// above and below each turn. Large avatars need more of it, so it is a
  /// setting rather than a constant.
  final double messageSpacing;

  /// 0..1 opacity for the bubble fill.
  final double bubbleOpacity;

  /// Whether to label each turn with its sender's name.
  final bool showNames;

  /// The user's display name (the character's own name labels its turns). Used
  /// as the fallback label when the user is not impersonating a character.
  final String userName;

  /// Each role's name label: size, font, colour, placement and nudge. Held
  /// separately so they can be tuned independently, or kept in step via
  /// [syncNames] — mirroring how the two [AvatarStyle]s work. The defaults put
  /// each name over its own side of the thread (bot left, user right).
  final NameStyle botNameStyle;
  final NameStyle userNameStyle;

  /// When true, editing either name style writes both.
  final bool syncNames;

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

  /// User-defined symbol pairs that tint what they wrap — the general case of
  /// what `*` and `"` do, with the markers hidden or kept per rule. Applied in
  /// order, ahead of the built-in markdown styles, so a rule wins any collision
  /// with them.
  final List<TextWrapRule> textWrapRules;

  /// The wrap rules a renderer should actually apply.
  List<TextWrapRule> get activeTextWrapRules => activeWrapRules(textWrapRules);

  /// Whether the inline per-message action bar is shown at all. When off, only
  /// the long-press action sheet remains.
  final bool messageActionsEnabled;

  /// Per-action placement (inline icon vs three-dot overflow), in display order.
  /// Always the full set of [MessageAction]s once normalised.
  final List<MessageActionPref> messageActions;

  /// Where the action bar sits relative to a message.
  final ActionBarPlacement actionBarPlacement;

  /// Whether the group-chat feature is offered at all. When off, the composer's
  /// group toggle is hidden and every thread behaves one-to-one. Read from the
  /// app-wide interface (a per-chat copy just inherits whatever it was frozen
  /// at), so it acts as a global feature flag.
  final bool groupChatsEnabled;

  /// The height of the group participant bar, in logical pixels.
  final double groupBarHeight;

  /// ARGB fill behind the group bar; null follows the theme's surface.
  final int? groupBarColor;

  /// A picture drawn behind the group bar, as an [avatarRef]-style
  /// `local:<file>` reference (or an `http(s)` URL); null draws none.
  final String? groupBarImage;

  /// Whether the composer offers a **response hint**: a line of steering typed
  /// beside the conversation and injected into the prompt on every send, so a
  /// reply can be nudged ("she is lying", "keep it short") without that nudge
  /// becoming a turn in the transcript. Off by default.
  ///
  /// Read from the app-wide interface like [groupChatsEnabled] — a per-chat copy
  /// only inherits whatever it was frozen at, so this behaves as a feature flag
  /// rather than something a single thread can silently disagree about.
  final bool responseHintEnabled;

  /// How far from the newest end of the conversation the hint is injected, in
  /// messages: 0 places it after the last turn, 2 places it two turns back.
  /// Bounded by [kMinResponseHintDepth]/[kMaxResponseHintDepth]; read from the
  /// app-wide interface, as [responseHintEnabled] is.
  final int responseHintDepth;

  /// How visible the menu square that floats at the top-left of a chat is,
  /// 0..1. Bounded by [kMinChromeOpacity]/[kMaxChromeOpacity]; unlike the
  /// feature flags above this one *is* honoured per chat, since it is a matter
  /// of what suits the picture behind a particular thread.
  final double menuButtonOpacity;

  /// The same, for the arrow at the bottom-right that jumps to the newest turn.
  final double jumpButtonOpacity;

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

  NameStyle nameFor(bool isUser) => isUser ? userNameStyle : botNameStyle;

  /// Every picture file this look refers to.
  ///
  /// One place, named once, because two callers need it and both are the kind
  /// that fails silently when a field is forgotten: the sweep's keep-list, which
  /// deletes any picture nothing claims, and a look's export, which has to carry
  /// its pictures for the file to mean anything on another device.
  Iterable<String> get pictureRefs => [
        if (groupBarImage != null && groupBarImage!.isNotEmpty) groupBarImage!,
      ];
// APPEND-CI-2

  ChatInterface copyWith({
    AvatarStyle? botAvatar,
    AvatarStyle? userAvatar,
    bool? syncAvatars,
    TextPlacement? textPlacement,
    bool? bubbles,
    ContentWidth? contentWidth,
    double? fontSize,
    double? messageSpacing,
    double? bubbleOpacity,
    bool? showNames,
    String? userName,
    NameStyle? botNameStyle,
    NameStyle? userNameStyle,
    bool? syncNames,
    bool? markdown,
    Object? userTextColor = _unset,
    Object? botTextColor = _unset,
    Object? userBubbleColor = _unset,
    Object? botBubbleColor = _unset,
    Object? backgroundColor = _unset,
    Object? emphasisColor = _unset,
    Object? quoteColor = _unset,
    List<TextWrapRule>? textWrapRules,
    bool? messageActionsEnabled,
    List<MessageActionPref>? messageActions,
    ActionBarPlacement? actionBarPlacement,
    bool? groupChatsEnabled,
    double? groupBarHeight,
    Object? groupBarColor = _unset,
    Object? groupBarImage = _unset,
    bool? responseHintEnabled,
    int? responseHintDepth,
    double? menuButtonOpacity,
    double? jumpButtonOpacity,
  }) =>
      ChatInterface(
        botAvatar: botAvatar ?? this.botAvatar,
        userAvatar: userAvatar ?? this.userAvatar,
        syncAvatars: syncAvatars ?? this.syncAvatars,
        textPlacement: textPlacement ?? this.textPlacement,
        bubbles: bubbles ?? this.bubbles,
        contentWidth: contentWidth ?? this.contentWidth,
        fontSize: fontSize ?? this.fontSize,
        messageSpacing: messageSpacing ?? this.messageSpacing,
        bubbleOpacity: bubbleOpacity ?? this.bubbleOpacity,
        showNames: showNames ?? this.showNames,
        userName: userName ?? this.userName,
        botNameStyle: botNameStyle ?? this.botNameStyle,
        userNameStyle: userNameStyle ?? this.userNameStyle,
        syncNames: syncNames ?? this.syncNames,
        markdown: markdown ?? this.markdown,
        userTextColor: _pick(userTextColor, this.userTextColor),
        botTextColor: _pick(botTextColor, this.botTextColor),
        userBubbleColor: _pick(userBubbleColor, this.userBubbleColor),
        botBubbleColor: _pick(botBubbleColor, this.botBubbleColor),
        backgroundColor: _pick(backgroundColor, this.backgroundColor),
        emphasisColor: _pick(emphasisColor, this.emphasisColor),
        quoteColor: _pick(quoteColor, this.quoteColor),
        textWrapRules: textWrapRules ?? this.textWrapRules,
        messageActionsEnabled:
            messageActionsEnabled ?? this.messageActionsEnabled,
        messageActions: messageActions ?? this.messageActions,
        actionBarPlacement: actionBarPlacement ?? this.actionBarPlacement,
        groupChatsEnabled: groupChatsEnabled ?? this.groupChatsEnabled,
        groupBarHeight: groupBarHeight ?? this.groupBarHeight,
        groupBarColor: _pick(groupBarColor, this.groupBarColor),
        groupBarImage: identical(groupBarImage, _unset)
            ? this.groupBarImage
            : groupBarImage as String?,
        responseHintEnabled: responseHintEnabled ?? this.responseHintEnabled,
        responseHintDepth: responseHintDepth ?? this.responseHintDepth,
        menuButtonOpacity: menuButtonOpacity ?? this.menuButtonOpacity,
        jumpButtonOpacity: jumpButtonOpacity ?? this.jumpButtonOpacity,
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

  /// Writes [style] to one role's name and, when [syncNames] is on, to both.
  /// Unlike avatars there is nothing role-specific to preserve (a name has no
  /// side of its own), so a synced write is a straight mirror.
  ChatInterface withName(bool isUser, NameStyle style) {
    if (syncNames) {
      return copyWith(botNameStyle: style, userNameStyle: style);
    }
    return isUser
        ? copyWith(userNameStyle: style)
        : copyWith(botNameStyle: style);
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
        'messageSpacing': messageSpacing,
        'bubbleOpacity': bubbleOpacity,
        'showNames': showNames,
        'userName': userName,
        'botNameStyle': botNameStyle.toJson(),
        'userNameStyle': userNameStyle.toJson(),
        'syncNames': syncNames,
        'markdown': markdown,
        if (userTextColor != null) 'userTextColor': userTextColor,
        if (botTextColor != null) 'botTextColor': botTextColor,
        if (userBubbleColor != null) 'userBubbleColor': userBubbleColor,
        if (botBubbleColor != null) 'botBubbleColor': botBubbleColor,
        if (backgroundColor != null) 'backgroundColor': backgroundColor,
        if (emphasisColor != null) 'emphasisColor': emphasisColor,
        if (quoteColor != null) 'quoteColor': quoteColor,
        if (textWrapRules.isNotEmpty)
          'textWrapRules': textWrapRules.map((r) => r.toJson()).toList(),
        'messageActionsEnabled': messageActionsEnabled,
        'messageActions': messageActions.map((p) => p.toJson()).toList(),
        'actionBarPlacement': actionBarPlacement.name,
        'groupChatsEnabled': groupChatsEnabled,
        'groupBarHeight': groupBarHeight,
        if (groupBarColor != null) 'groupBarColor': groupBarColor,
        if (groupBarImage != null && groupBarImage!.isNotEmpty)
          'groupBarImage': groupBarImage,
        'responseHintEnabled': responseHintEnabled,
        'responseHintDepth': responseHintDepth,
        'menuButtonOpacity': menuButtonOpacity,
        'jumpButtonOpacity': jumpButtonOpacity,
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
      messageSpacing: (json['messageSpacing'] as num?)?.toDouble() ??
          kDefaultMessageSpacing,
      bubbleOpacity: (json['bubbleOpacity'] as num?)?.toDouble() ?? 1,
      showNames: json['showNames'] as bool? ?? false,
      userName: json['userName'] as String? ?? 'You',
      botNameStyle: _nameStyleFromJson(json, 'botNameStyle', 'bot',
          const NameStyle()),
      userNameStyle: _nameStyleFromJson(json, 'userNameStyle', 'user',
          const NameStyle(align: NameAlign.end)),
      syncNames: json['syncNames'] as bool? ?? false,
      markdown: json['markdown'] as bool? ?? true,
      userTextColor: (json['userTextColor'] as num?)?.toInt(),
      botTextColor: (json['botTextColor'] as num?)?.toInt(),
      userBubbleColor: (json['userBubbleColor'] as num?)?.toInt(),
      botBubbleColor: (json['botBubbleColor'] as num?)?.toInt(),
      backgroundColor: (json['backgroundColor'] as num?)?.toInt(),
      emphasisColor: (json['emphasisColor'] as num?)?.toInt(),
      quoteColor: (json['quoteColor'] as num?)?.toInt(),
      textWrapRules: textWrapRulesFromJson(json['textWrapRules']),
      messageActionsEnabled: json['messageActionsEnabled'] as bool? ?? true,
      messageActions: _messageActionsFromJson(json['messageActions']),
      actionBarPlacement:
          ActionBarPlacement.byName(json['actionBarPlacement'] as String?),
      groupChatsEnabled: json['groupChatsEnabled'] as bool? ?? false,
      groupBarHeight: (json['groupBarHeight'] as num?)?.toDouble() ??
          kDefaultGroupBarHeight,
      groupBarColor: (json['groupBarColor'] as num?)?.toInt(),
      groupBarImage: (json['groupBarImage'] as String?)?.trim().isEmpty ?? true
          ? null
          : (json['groupBarImage'] as String).trim(),
      responseHintEnabled: json['responseHintEnabled'] as bool? ?? false,
      responseHintDepth: ((json['responseHintDepth'] as num?)?.toInt() ??
              kDefaultResponseHintDepth)
          .clamp(kMinResponseHintDepth, kMaxResponseHintDepth),
      menuButtonOpacity: _chromeOpacity(json['menuButtonOpacity']),
      jumpButtonOpacity: _chromeOpacity(json['jumpButtonOpacity']),
    );
  }

  /// A stored floating-button opacity, defaulted when absent (a config saved
  /// before the setting existed) and clamped into range.
  static double _chromeOpacity(Object? value) =>
      ((value as num?)?.toDouble() ?? kDefaultChromeOpacity)
          .clamp(kMinChromeOpacity, kMaxChromeOpacity);

  /// Reads one role's [NameStyle], migrating the pre-nested flat keys
  /// (`botNameSize`/`botNameAlign`/`botNamePosition` and the `user` pair) when
  /// the nested object is absent — so a config saved before names grew fonts,
  /// colours and offsets keeps the typography it had. [defaults] carries the
  /// role's own starting point for anything neither shape stored.
  static NameStyle _nameStyleFromJson(Map<String, dynamic> json, String key,
      String role, NameStyle defaults) {
    final legacy = defaults.copyWith(
      size: (json['${role}NameSize'] as num?)?.toDouble(),
      align: json['${role}NameAlign'] == null
          ? null
          : NameAlign.byName(json['${role}NameAlign'] as String?),
      position: json['${role}NamePosition'] == null
          ? null
          : NamePosition.byName(json['${role}NamePosition'] as String?),
    );
    final nested = json[key];
    if (nested is! Map) return legacy;
    return NameStyle.fromJson(nested.cast<String, dynamic>(),
        fallback: legacy);
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
      other.messageSpacing == messageSpacing &&
      other.bubbleOpacity == bubbleOpacity &&
      other.showNames == showNames &&
      other.userName == userName &&
      other.botNameStyle == botNameStyle &&
      other.userNameStyle == userNameStyle &&
      other.syncNames == syncNames &&
      other.markdown == markdown &&
      other.userTextColor == userTextColor &&
      other.botTextColor == botTextColor &&
      other.userBubbleColor == userBubbleColor &&
      other.botBubbleColor == botBubbleColor &&
      other.backgroundColor == backgroundColor &&
      other.emphasisColor == emphasisColor &&
      other.quoteColor == quoteColor &&
      listEquals(other.textWrapRules, textWrapRules) &&
      other.messageActionsEnabled == messageActionsEnabled &&
      listEquals(other.messageActions, messageActions) &&
      other.actionBarPlacement == actionBarPlacement &&
      other.groupChatsEnabled == groupChatsEnabled &&
      other.groupBarHeight == groupBarHeight &&
      other.groupBarColor == groupBarColor &&
      other.groupBarImage == groupBarImage &&
      other.responseHintEnabled == responseHintEnabled &&
      other.responseHintDepth == responseHintDepth &&
      other.menuButtonOpacity == menuButtonOpacity &&
      other.jumpButtonOpacity == jumpButtonOpacity;

  @override
  int get hashCode => Object.hash(
        botAvatar,
        userAvatar,
        syncAvatars,
        textPlacement,
        Object.hash(bubbles, contentWidth, messageSpacing),
        fontSize,
        bubbleOpacity,
        showNames,
        userName,
        Object.hash(botNameStyle, userNameStyle, syncNames),
        markdown,
        userTextColor,
        botTextColor,
        userBubbleColor,
        botBubbleColor,
        backgroundColor,
        emphasisColor,
        // Folded together because Object.hash takes at most 20 arguments and
        // this list is already at that ceiling.
        Object.hash(quoteColor, Object.hashAll(textWrapRules)),
        Object.hash(messageActionsEnabled, actionBarPlacement),
        // Folded together because Object.hash caps at 20 arguments: the message
        // action list, the group-bar settings, the response-hint pair and the
        // floating buttons' opacity share this final slot.
        Object.hash(Object.hashAll(messageActions), groupChatsEnabled,
            groupBarHeight, groupBarColor, groupBarImage,
            responseHintEnabled, responseHintDepth,
            Object.hash(menuButtonOpacity, jumpButtonOpacity)),
      );
}




