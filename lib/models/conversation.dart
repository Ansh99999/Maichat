import 'character.dart';
import 'chat_interface.dart';
import 'floating_image.dart';
import 'message.dart';
import 'preset.dart';

/// The [Conversation.groupResponder] value meaning "a random member replies to
/// each send". Any other non-null value is a member's [Character.id]; null means
/// nobody replies automatically (the user taps a chip to pick who speaks).
const String kGroupResponderRandom = '__random__';

/// A named thread of messages, persisted as a whole.
class Conversation {
  Conversation({
    required this.id,
    required this.title,
    required this.messages,
    required this.updatedAt,
    this.characterId,
    this.characterName,
    this.systemPrompt = '',
    this.impersonateId,
    this.impersonateName,
    this.presetId,
    this.presetOverride,
    this.backgroundImage,
    this.backgroundOpacity = 1,
    this.interfaceOverride,
    this.overrideDefinitions = false,
    this.groupResponder,
    Map<String, Character>? characterOverrides,
    Map<String, String>? avatarOverrides,
    List<FloatingImage>? floatingImages,
    Map<String, String>? variables,
    List<String>? lorebookIds,
    List<String>? participantIds,
  })  : characterOverrides =
            characterOverrides ?? <String, Character>{},
        avatarOverrides = avatarOverrides ?? <String, String>{},
        floatingImages = floatingImages ?? <FloatingImage>[],
        variables = variables ?? <String, String>{},
        lorebookIds = lorebookIds ?? <String>[],
        participantIds = participantIds ?? <String>[];

  final String id;
  String title;
  final List<ChatMessage> messages;
  DateTime updatedAt;

  /// Set when this thread was started from a saved character. [characterName]
  /// is denormalised so the chat still reads right if the character is later
  /// edited or deleted, and [systemPrompt] is the composed persona injected
  /// (invisibly) ahead of the history on every turn.
  String? characterId;
  String? characterName;
  String systemPrompt;

  /// Set when the user is impersonating a saved character in this thread — the
  /// "active identity" chosen from the send bar. [impersonateName] is
  /// denormalised so a turn still labels right if the character is later edited
  /// or deleted. The persona is injected into every outgoing request.
  String? impersonateId;
  String? impersonateName;

  /// Whether the user is currently speaking as an impersonated character.
  bool get isImpersonating => impersonateId != null;

  /// The generation preset this thread runs under (by [Preset.id]); null falls
  /// back to the app's default preset.
  String? presetId;

  /// A chat-specific preset copy that overrides [presetId] when present — the
  /// "save for this chat only" case from the in-chat preset editor.
  Preset? presetOverride;

  /// A picture drawn behind this thread only, as an [avatarRef]-style
  /// `local:<file>` reference (or an `http(s)` URL). [backgroundOpacity] fades
  /// it towards the chat's background colour, because a full-strength photo
  /// behind running text is unreadable.
  String? backgroundImage;
  double backgroundOpacity;

  /// Chat-style settings for this thread only. Absent (the normal case) means
  /// the app-wide `ChatInterface` applies; once set it is a full standalone
  /// copy, so later app-wide changes deliberately do not reach this chat.
  ChatInterface? interfaceOverride;

  /// Whether [characterOverrides] are honoured. Kept as its own flag so a set of
  /// per-chat edits can be switched off and back on without losing them.
  bool overrideDefinitions;

  /// Per-chat character definitions, by [Character.id] — the "save for this
  /// chat" half of the chat-settings editor. Only consulted while
  /// [overrideDefinitions] is on.
  final Map<String, Character> characterOverrides;

  /// Which picture each character wears **in this thread**, by [Character.id] —
  /// the "Set" action in the in-chat avatar viewer. The value is a picture
  /// reference (`local:<file>` or a URL) chosen from that character's gallery.
  /// Read it through `AppState.avatarRefFor`, never directly, so the fallback to
  /// the card's own avatar happens in exactly one place.
  final Map<String, String> avatarOverrides;

  /// Pictures pinned over this thread, in z-order (last drawn on top). These are
  /// pure decoration: they are never part of the transcript and never reach the
  /// model, so nothing here affects the prompt, an export or a token count.
  final List<FloatingImage> floatingImages;

  /// Per-chat macro variables ({{setvar}}/{{getvar}}), SillyTavern's local scope.
  final Map<String, String> variables;

  /// The lorebooks switched on for this thread, by [Lorebook.id]. More than one
  /// can be active at a time; their entries are pooled before the prompt is
  /// assembled. Order is the order they were added, which only matters as a
  /// tiebreaker between two entries of equal weight.
  final List<String> lorebookIds;

  /// The AI characters taking part in a **group chat**, by [Character.id], in
  /// speaking order — the chips shown in the group bar. Empty (the normal case)
  /// means a one-to-one thread, where [characterId] alone is the character; a
  /// group is any thread with two or more here. [characterId] stays the primary
  /// (first) member so single-character code paths and older readers keep
  /// working. The impersonated user ([impersonateId]) is deliberately *not* a
  /// participant — it is the human's seat, not a responder.
  final List<String> participantIds;

  /// Whether this thread is a group chat (two or more characters take part).
  bool get isGroup => participantIds.length >= 2;

  /// In a **group chat**, who replies automatically when the user sends a
  /// message: null means nobody (the default — the user taps a chip to pick who
  /// speaks), [kGroupResponderRandom] means a random member each turn, and any
  /// other value is the [Character.id] of the one member who always answers.
  /// Ignored outside a group. Persisted so the choice survives a restart.
  String? groupResponder;

  /// Every AI character in the thread, in order — the group roster when it is a
  /// group, otherwise the single bound character (or nothing).
  List<String> get memberIds {
    if (participantIds.isNotEmpty) return participantIds;
    return characterId == null ? const <String>[] : <String>[characterId!];
  }

  factory Conversation.empty() => Conversation(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        title: 'New chat',
        messages: <ChatMessage>[],
        updatedAt: DateTime.now(),
      );

  bool get isEmpty => messages.isEmpty;

  /// A copy under a new [id], carrying every per-chat setting across — used for
  /// forking a thread and for renumbering an imported one. Everything mutable is
  /// copied rather than shared, so the two threads can diverge; [messages]
  /// defaults to the same turn objects, so a caller that needs those deep-copied
  /// too passes its own list.
  ///
  /// Deliberately field-blind: it round-trips the per-chat overrides through
  /// JSON, so a setting added to this class is carried by both callers without
  /// either being touched.
  Conversation copyAs({
    required String id,
    String? title,
    List<ChatMessage>? messages,
    DateTime? updatedAt,
  }) =>
      Conversation(
        id: id,
        title: title ?? this.title,
        messages: messages ?? this.messages.toList(),
        updatedAt: updatedAt ?? this.updatedAt,
        characterId: characterId,
        characterName: characterName,
        systemPrompt: systemPrompt,
        impersonateId: impersonateId,
        impersonateName: impersonateName,
        presetId: presetId,
        presetOverride: presetOverride == null
            ? null
            : Preset.fromJson(presetOverride!.toJson()),
        backgroundImage: backgroundImage,
        backgroundOpacity: backgroundOpacity,
        interfaceOverride: interfaceOverride == null
            ? null
            : ChatInterface.fromJson(interfaceOverride!.toJson()),
        overrideDefinitions: overrideDefinitions,
        groupResponder: groupResponder,
        characterOverrides: characterOverrides.map(
          (charId, character) => MapEntry(charId, character.clone()),
        ),
        avatarOverrides: Map<String, String>.of(avatarOverrides),
        floatingImages: floatingImages.map((f) => f.copyWith()).toList(),
        variables: Map<String, String>.of(variables),
        lorebookIds: lorebookIds.toList(),
        participantIds: participantIds.toList(),
      );

  /// Whether this thread is bound to a saved character.
  bool get hasCharacter => characterId != null;

  /// Names an untitled thread after its opening user message.
  void retitleFrom(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return;
    title = flat.length <= 40 ? flat : '${flat.substring(0, 40)}...';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'updatedAt': updatedAt.toIso8601String(),
        if (characterId != null) 'characterId': characterId,
        if (characterName != null) 'characterName': characterName,
        if (systemPrompt.isNotEmpty) 'systemPrompt': systemPrompt,
        if (impersonateId != null) 'impersonateId': impersonateId,
        if (impersonateName != null) 'impersonateName': impersonateName,
        if (presetId != null) 'presetId': presetId,
        if (presetOverride != null) 'presetOverride': presetOverride!.toJson(),
        if (backgroundImage != null && backgroundImage!.isNotEmpty)
          'backgroundImage': backgroundImage,
        if (backgroundOpacity != 1) 'backgroundOpacity': backgroundOpacity,
        if (interfaceOverride != null)
          'interfaceOverride': interfaceOverride!.toJson(),
        if (overrideDefinitions) 'overrideDefinitions': true,
        if (groupResponder != null) 'groupResponder': groupResponder,
        if (characterOverrides.isNotEmpty)
          'characterOverrides': characterOverrides.map(
            (id, character) => MapEntry(id, character.toJson()),
          ),
        if (avatarOverrides.isNotEmpty) 'avatarOverrides': avatarOverrides,
        if (floatingImages.isNotEmpty)
          'floatingImages': floatingImages.map((f) => f.toJson()).toList(),
        if (variables.isNotEmpty) 'variables': variables,
        if (lorebookIds.isNotEmpty) 'lorebookIds': lorebookIds,
        if (participantIds.isNotEmpty) 'participantIds': participantIds,
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
        id: json['id'] as String? ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        title: json['title'] as String? ?? 'New chat',
        updatedAt:
            DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
                DateTime.now(),
        characterId: json['characterId'] as String?,
        characterName: json['characterName'] as String?,
        systemPrompt: json['systemPrompt'] as String? ?? '',
        impersonateId: json['impersonateId'] as String?,
        impersonateName: json['impersonateName'] as String?,
        presetId: json['presetId'] as String?,
        presetOverride: json['presetOverride'] is Map<String, dynamic>
            ? Preset.fromJson(json['presetOverride'] as Map<String, dynamic>)
            : null,
        backgroundImage: (json['backgroundImage'] as String?)?.trim(),
        backgroundOpacity:
            ((json['backgroundOpacity'] as num?)?.toDouble() ?? 1)
                .clamp(0, 1)
                .toDouble(),
        interfaceOverride: json['interfaceOverride'] is Map<String, dynamic>
            ? ChatInterface.fromJson(
                json['interfaceOverride'] as Map<String, dynamic>)
            : null,
        overrideDefinitions: json['overrideDefinitions'] as bool? ?? false,
        groupResponder: (json['groupResponder'] as String?)?.trim().isEmpty ?? true
            ? null
            : (json['groupResponder'] as String).trim(),
        characterOverrides: _characterMap(json['characterOverrides']),
        avatarOverrides: _refMap(json['avatarOverrides']),
        floatingImages: (json['floatingImages'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(FloatingImage.fromJson)
            .where((f) => f.imageId.isNotEmpty)
            .toList(),
        variables: (json['variables'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
        ),
        lorebookIds: (json['lorebookIds'] as List?)
            ?.map((e) => e.toString())
            .where((s) => s.isNotEmpty)
            .toList(),
        participantIds: (json['participantIds'] as List?)
            ?.map((e) => e.toString())
            .where((s) => s.isNotEmpty)
            .toList(),
        messages: (json['messages'] as List<dynamic>? ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(ChatMessage.fromJson)
            .toList(),
      );

  /// Reads the per-chat character definitions, skipping anything that is not a
  /// card. Null (rather than an empty map) when there are none, so the
  /// constructor's own default applies.
  static Map<String, Character>? _characterMap(Object? value) {
    if (value is! Map) return null;
    final overrides = <String, Character>{};
    for (final entry in value.entries) {
      final card = entry.value;
      if (card is Map<String, dynamic>) {
        overrides[entry.key.toString()] = Character.fromJson(card);
      }
    }
    return overrides;
  }

  /// Reads the per-chat avatar choices, dropping any entry that does not name a
  /// picture — an empty value would resolve to "no avatar at all" rather than
  /// falling back to the card's own, which is not what an absent choice means.
  static Map<String, String>? _refMap(Object? value) {
    if (value is! Map) return null;
    final refs = <String, String>{};
    for (final entry in value.entries) {
      final ref = entry.value?.toString().trim() ?? '';
      if (ref.isNotEmpty) refs[entry.key.toString()] = ref;
    }
    return refs;
  }
}
