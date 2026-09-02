import 'chat_interface.dart';

/// A named look: a whole [ChatInterface] you can save, switch to, hand to one
/// chat or to all of them, carry out to a file and bring back.
///
/// The point is that ~66 settings become reversible. Before this, a session spent
/// exploring the interface had no way back short of remembering what every knob
/// used to be.
class InterfacePreset {
  const InterfacePreset({
    required this.id,
    required this.name,
    required this.ui,
    this.createdAt,
  });

  final String id;
  final String name;
  final ChatInterface ui;

  /// Null for the looks that ship with the app, which have no history.
  final DateTime? createdAt;

  /// The shipped looks are told apart by their id rather than by a flag, so a
  /// saved file cannot claim to be one of them.
  bool get isBuiltIn => id.startsWith(kBuiltInPresetPrefix);

  InterfacePreset copyWith({String? name, ChatInterface? ui}) => InterfacePreset(
        id: id,
        name: name ?? this.name,
        ui: ui ?? this.ui,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'ui': ui.toJson(),
        if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
      };

  /// Tolerant, like every other reader here: a preset with an unreadable look
  /// still lands, wearing the defaults, rather than taking the whole list down.
  static InterfacePreset? fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as String?)?.trim();
    final name = (json['name'] as String?)?.trim();
    if (id == null || id.isEmpty || name == null || name.isEmpty) return null;
    final raw = json['ui'];
    return InterfacePreset(
      id: id,
      name: name,
      ui: raw is Map<String, dynamic>
          ? ChatInterface.fromJson(raw)
          : const ChatInterface(),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is InterfacePreset &&
      other.id == id &&
      other.name == name &&
      other.ui == ui;

  @override
  int get hashCode => Object.hash(id, name, ui);
}
/// Marks the looks that ship with the app. A saved look gets a timestamp id, so
/// nothing a user creates or imports can collide with one of these.
const String kBuiltInPresetPrefix = 'builtin:';

/// The four looks the app ships with, offered above whatever the user has saved.
///
/// They are deliberately far apart rather than four shades of the same thing:
/// picking one should visibly answer "what else could this look like?".
const List<InterfacePreset> kBuiltInInterfacePresets = [
  InterfacePreset(
    id: '${kBuiltInPresetPrefix}bubbles',
    name: 'Bubbles',
    // The out-of-the-box look, named so there is always a way back to it.
    ui: ChatInterface(),
  ),
  InterfacePreset(
    id: '${kBuiltInPresetPrefix}document',
    name: 'Document',
    // A flat transcript: no bubbles, full width, both speakers down the left with
    // their names over each turn. Reads like a script rather than a messenger.
    ui: ChatInterface(
      bubbles: false,
      contentWidth: ContentWidth.full,
      textPlacement: TextPlacement.below,
      messageSpacing: 22,
      showNames: true,
      syncNames: true,
      botAvatar: AvatarStyle(show: false, side: ChatSide.left),
      userAvatar: AvatarStyle(show: false, side: ChatSide.left),
      botNameStyle: NameStyle(size: 13),
      userNameStyle: NameStyle(size: 13),
    ),
  ),
  InterfacePreset(
    id: '${kBuiltInPresetPrefix}compact',
    name: 'Compact',
    // As many turns on screen as will fit: small type, small avatars, almost no
    // gap. For reading back through a long thread.
    ui: ChatInterface(
      contentWidth: ContentWidth.full,
      fontSize: 14,
      messageSpacing: 4,
      botAvatar: AvatarStyle(size: 30, side: ChatSide.left),
      userAvatar: AvatarStyle(size: 30, side: ChatSide.right),
      syncAvatars: true,
    ),
  ),
  InterfacePreset(
    id: '${kBuiltInPresetPrefix}roleplay',
    name: 'Roleplay',
    // The character gets a portrait and a headline; you stay out of the way.
    ui: ChatInterface(
      bubbles: false,
      textPlacement: TextPlacement.below,
      contentWidth: ContentWidth.wide,
      messageSpacing: 26,
      showNames: true,
      botAvatar: AvatarStyle(size: 96, shape: AvatarShape.rounded),
      userAvatar: AvatarStyle(show: false, side: ChatSide.right),
      botNameStyle: NameStyle(size: 24),
      userNameStyle: NameStyle(size: 12, align: NameAlign.end),
    ),
  ),
];

