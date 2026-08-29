import 'message_image.dart';

/// One generated alternative for a turn — the unit the swipe control selects
/// between.
///
/// A turn normally has exactly one. Regenerating adds another instead of
/// throwing the old text away, and a character's alternate greetings seed
/// several up front, so the opening turn can be flipped through.
class MessageVariant {
  const MessageVariant({
    required this.content,
    this.reasoning = '',
    this.thinkingMs,
    this.error = false,
  });

  final String content;

  /// The model's thinking for this variant, tags stripped.
  final String reasoning;

  /// How long the model spent thinking, in milliseconds, or null while it is
  /// still thinking (or if it never did).
  final int? thinkingMs;

  /// Set when this variant holds a failure notice rather than model output.
  final bool error;

  MessageVariant copyWith({
    String? content,
    String? reasoning,
    int? thinkingMs,
    bool? error,
  }) =>
      MessageVariant(
        content: content ?? this.content,
        reasoning: reasoning ?? this.reasoning,
        thinkingMs: thinkingMs ?? this.thinkingMs,
        error: error ?? this.error,
      );

  Map<String, dynamic> toJson() => {
        'content': content,
        if (reasoning.isNotEmpty) 'reasoning': reasoning,
        if (thinkingMs != null) 'thinkingMs': thinkingMs,
        if (error) 'error': true,
      };

  factory MessageVariant.fromJson(Map<String, dynamic> json) => MessageVariant(
        content: json['content'] as String? ?? '',
        reasoning: json['reasoning'] as String? ?? '',
        thinkingMs: (json['thinkingMs'] as num?)?.toInt(),
        error: json['error'] as bool? ?? false,
      );

  @override
  bool operator ==(Object other) =>
      other is MessageVariant &&
      other.content == content &&
      other.reasoning == reasoning &&
      other.thinkingMs == thinkingMs &&
      other.error == error;

  @override
  int get hashCode => Object.hash(content, reasoning, thinkingMs, error);
}

/// A single turn in a conversation.
///
/// The turn owns a list of [swipes] — its alternative texts — of which
/// [swipeIndex] is the live one; [content], [reasoning], [thinkingMs] and
/// [error] all read through to it, so everything that consumes a message (the
/// wire format included) sees the selected variant and nothing has to know
/// swipes exist. A turn built the plain way (`content:`) holds exactly one.
class ChatMessage {
  ChatMessage({
    required this.role,
    String content = '',
    bool error = false,
    String reasoning = '',
    int? thinkingMs,
    List<MessageVariant>? swipes,
    int swipeIndex = 0,
    this.speakerId,
    this.speakerName,
    List<MessageImage>? images,
  })  : images = List<MessageImage>.unmodifiable(
          images ?? const <MessageImage>[],
        ),
        swipes = List<MessageVariant>.unmodifiable(
          swipes == null || swipes.isEmpty
              ? <MessageVariant>[
                  MessageVariant(
                    content: content,
                    reasoning: reasoning,
                    thinkingMs: thinkingMs,
                    error: error,
                  ),
                ]
              : swipes,
        ),
        swipeIndex = swipes == null || swipes.isEmpty
            ? 0
            : swipeIndex.clamp(0, swipes.length - 1);

  /// Either `user` or `assistant`.
  final String role;

  /// Pictures attached to this turn, in the order they were added. They belong
  /// to the *turn* rather than to a variant: regenerating a reply produces new
  /// text, never new attachments, and it is the user's turns that carry these.
  /// Empty for the overwhelming majority of messages.
  final List<MessageImage> images;

  bool get hasImages => images.isNotEmpty;

  /// In a group chat, which participant *said* this turn — its [Character.id]
  /// and a denormalised display name (kept so a turn still labels right if the
  /// character is later edited or deleted). Null in an ordinary one-to-one chat,
  /// where the thread's single character (or the impersonated user) is implied,
  /// so nothing about the pre-group JSON shape changes.
  final String? speakerId;
  final String? speakerName;

  /// Every alternative this turn holds, oldest first. Never empty.
  final List<MessageVariant> swipes;

  /// Which of [swipes] is live.
  final int swipeIndex;

  /// The live variant — what the chat shows and the model receives.
  MessageVariant get active => swipes[swipeIndex];

  String get content => active.content;
  String get reasoning => active.reasoning;
  int? get thinkingMs => active.thinkingMs;
  bool get error => active.error;

  bool get isUser => role == 'user';

  bool get hasReasoning => reasoning.trim().isNotEmpty;

  /// How many alternatives this turn holds.
  int get swipeCount => swipes.length;

  /// Whether there is more than one alternative — the only case where the swipe
  /// control is worth drawing.
  bool get hasSwipes => swipes.length > 1;

  /// Edits the live variant, leaving the others untouched.
  ChatMessage copyWith({
    String? content,
    bool? error,
    String? reasoning,
    int? thinkingMs,
    Object? speakerId = _unset,
    Object? speakerName = _unset,
    List<MessageImage>? images,
  }) {
    final next = active.copyWith(
      content: content,
      error: error,
      reasoning: reasoning,
      thinkingMs: thinkingMs,
    );
    return ChatMessage(
      role: role,
      swipes: <MessageVariant>[...swipes]..[swipeIndex] = next,
      swipeIndex: swipeIndex,
      images: images ?? this.images,
      speakerId: identical(speakerId, _unset)
          ? this.speakerId
          : speakerId as String?,
      speakerName: identical(speakerName, _unset)
          ? this.speakerName
          : speakerName as String?,
    );
  }

  // Sentinel so copyWith can tell "leave the speaker" from "clear it to null".
  static const Object _unset = Object();

  /// Selects the variant at [index] — the ‹ › control. Out-of-range indices and
  /// the current one are no-ops.
  ChatMessage withSwipe(int index) =>
      index == swipeIndex || index < 0 || index >= swipes.length
          ? this
          : ChatMessage(
              role: role,
              swipes: swipes.toList(),
              swipeIndex: index,
              images: images,
              speakerId: speakerId,
              speakerName: speakerName,
            );

  /// Appends [variant] and selects it — the regenerate path, which keeps the
  /// reply it replaced as a swipe.
  ChatMessage addSwipe(MessageVariant variant) => ChatMessage(
        role: role,
        swipes: <MessageVariant>[...swipes, variant],
        swipeIndex: swipes.length,
        images: images,
        speakerId: speakerId,
        speakerName: speakerName,
      );

  /// Drops the variant at [index], selecting the one before it. A turn always
  /// keeps at least one variant, so this is a no-op on a single-swipe turn —
  /// used when a regeneration is aborted before producing anything.
  ChatMessage removeSwipe(int index) {
    if (swipes.length <= 1 || index < 0 || index >= swipes.length) return this;
    final rest = <MessageVariant>[...swipes]..removeAt(index);
    final selected = swipeIndex > index
        ? swipeIndex - 1
        : (swipeIndex == index ? index - 1 : swipeIndex);
    return ChatMessage(
      role: role,
      swipes: rest,
      swipeIndex: selected.clamp(0, rest.length - 1),
      images: images,
      speakerId: speakerId,
      speakerName: speakerName,
    );
  }

  /// The live variant is written flat (so an older reader, and anything that
  /// only cares about the current text, still finds it), with the alternatives
  /// alongside it only when there are any.
  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (error) 'error': true,
        if (reasoning.isNotEmpty) 'reasoning': reasoning,
        if (thinkingMs != null) 'thinkingMs': thinkingMs,
        if (speakerId != null) 'speakerId': speakerId,
        if (speakerName != null) 'speakerName': speakerName,
        if (images.isNotEmpty)
          'images': images.map((i) => i.toJson()).toList(),
        if (hasSwipes) 'swipes': swipes.map((s) => s.toJson()).toList(),
        if (hasSwipes) 'swipeIndex': swipeIndex,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final raw = json['swipes'];
    final swipes = raw is List
        ? raw
            .whereType<Map<String, dynamic>>()
            .map(MessageVariant.fromJson)
            .toList()
        : const <MessageVariant>[];
    final pictures = json['images'];
    return ChatMessage(
      role: json['role'] as String? ?? 'assistant',
      content: json['content'] as String? ?? '',
      error: json['error'] as bool? ?? false,
      reasoning: json['reasoning'] as String? ?? '',
      thinkingMs: (json['thinkingMs'] as num?)?.toInt(),
      speakerId: (json['speakerId'] as String?)?.trim().isEmpty ?? true
          ? null
          : (json['speakerId'] as String).trim(),
      speakerName: (json['speakerName'] as String?)?.trim().isEmpty ?? true
          ? null
          : (json['speakerName'] as String).trim(),
      images: pictures is List
          ? pictures
              .whereType<Map<String, dynamic>>()
              .map(MessageImage.fromJson)
              .where((i) => i.ref.isNotEmpty)
              .toList()
          : null,
      swipes: swipes.isEmpty ? null : swipes,
      swipeIndex: (json['swipeIndex'] as num?)?.toInt() ?? 0,
    );
  }

  /// Wire format for the chat completions endpoint. Thinking is deliberately
  /// absent: it is a display artefact of one turn, not part of the transcript.
  ///
  /// A turn with attachments sends OpenAI's multi-part content array instead of
  /// a plain string — but only when a picture actually has something to send, so
  /// a text-only turn (every turn, in the overwhelming majority of chats) keeps
  /// the exact shape it has always had.
  Map<String, dynamic> toApi() => {'role': role, 'content': openAiContent()};

  /// This turn's content in OpenAI's chat dialect: the plain string when there
  /// is nothing attached, otherwise `[{type: text}, {type: image_url}, …]`.
  Object openAiContent() {
    final parts = <Map<String, dynamic>>[];
    for (final image in images) {
      final url = _imageUrl(image);
      if (url != null) {
        parts.add({
          'type': 'image_url',
          'image_url': <String, dynamic>{'url': url},
        });
      }
    }
    if (parts.isEmpty) return content;
    return <Map<String, dynamic>>[
      if (content.isNotEmpty) {'type': 'text', 'text': content},
      ...parts,
    ];
  }

  /// What an OpenAI-shaped `image_url` should carry for [image]: the picture's
  /// own address when it lives online, a data URL when its bytes are to hand,
  /// and null when neither — a picture whose file has gone is dropped rather
  /// than sent as an empty attachment the host will reject.
  static String? _imageUrl(MessageImage image) {
    if (image.isUrl) return image.ref.trim();
    if (!image.hasData) return null;
    return 'data:${image.mime};base64,${image.data}';
  }
}

/// Collapses runs of consecutive same-role messages into one, joined by blank
/// lines.
///
/// Hosts disagree about same-role runs: Anthropic rejects them outright, and
/// several OpenAI-compatible gateways honour only the first `system` message and
/// drop the rest — which silently reduces a preset that frames the prompt with
/// many small blocks to whichever fragment happened to come first. Adjacent
/// blocks of one role are contiguous document text by design, so joining them is
/// what the preset author meant.
///
/// Attachments are carried across the join rather than dropped: a preset that
/// wraps the conversation in framing blocks can merge a `user` framing turn into
/// the very turn a picture was attached to, and losing the picture there would
/// make an attachment vanish for one preset and work for another.
List<ChatMessage> mergeSameRole(List<ChatMessage> input) {
  final out = <ChatMessage>[];
  for (final message in input) {
    if (out.isNotEmpty && out.last.role == message.role) {
      out[out.length - 1] = ChatMessage(
        role: message.role,
        content: '${out.last.content}\n\n${message.content}',
        images: <MessageImage>[...out.last.images, ...message.images],
      );
    } else {
      out.add(message);
    }
  }
  return out;
}
