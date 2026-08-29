/// The dialect an image endpoint speaks. Only two are supported, deliberately:
/// the OpenAI images API (which every hosted proxy and most local servers
/// imitate) and Gemini's `generateContent` with an image response — between them
/// they cover what a phone can actually reach.
enum ImageGenKind {
  openai(
    'OpenAI-compatible',
    'https://api.openai.com/v1',
    'gpt-image-1',
    'An images endpoint serving /images/generations, usually ending in /v1',
  ),
  gemini(
    'Gemini-compatible',
    'https://generativelanguage.googleapis.com/v1beta',
    'gemini-2.5-flash-image',
    'Gemini API root (…/v1beta)',
  );

  const ImageGenKind(this.label, this.defaultBaseUrl, this.modelHint, this.baseUrlHelper);

  final String label;
  final String defaultBaseUrl;
  final String modelHint;
  final String baseUrlHelper;

  static ImageGenKind byName(String? name) {
    for (final kind in values) {
      if (kind.name == name) return kind;
    }
    return ImageGenKind.openai;
  }
}

/// The sizes offered in the studio's settings. `auto` sends no size at all,
/// which is what the newer models want and what every host understands.
const List<String> kImageSizes = <String>[
  'auto',
  '1024x1024',
  '1024x1536',
  '1536x1024',
  '512x512',
  '1792x1024',
  '1024x1792',
];

/// The quality levels offered. Empty means "don't send one" — several hosts
/// reject a quality they do not know.
const List<String> kImageQualities = <String>['', 'low', 'medium', 'high'];

/// How the image studio talks to its endpoint.
///
/// Deliberately independent of the chat [Provider] list: picture generation and
/// conversation are separate services with separate keys far more often than not,
/// and "every chat can generate a picture" only holds if the studio has an
/// endpoint of its own. Stored under its own preferences entry, so nothing here
/// is rewritten when a chat is saved.
class ImageGenConfig {
  const ImageGenConfig({
    this.kind = ImageGenKind.openai,
    this.baseUrl = '',
    this.apiKey = '',
    this.model = '',
    this.size = 'auto',
    this.quality = '',
    this.count = 1,
    this.systemPrompt = '',
    this.negativePrompt = '',
  });

  final ImageGenKind kind;

  /// Where to send. Empty falls back to the kind's own default root, so a user
  /// who only pastes a key still has a working endpoint.
  final String baseUrl;
  final String apiKey;
  final String model;

  /// `auto` (send nothing) or a `WxH` string.
  final String size;

  /// `''` (send nothing), `low`, `medium` or `high`.
  final String quality;

  /// How many pictures to ask for per prompt.
  final int count;

  /// Standing instructions prepended to every prompt — the studio's "system
  /// prompt". A style, a rendering brief, a set of things to always avoid.
  /// Gemini takes it as a real `systemInstruction`; the OpenAI images API has no
  /// system field, so it is prefixed to the prompt instead.
  final String systemPrompt;

  /// Appended as "Avoid: …". The images API has no negative-prompt field either,
  /// so this is honest about being part of the prompt rather than pretending to
  /// be a separate channel.
  final String negativePrompt;

  /// The root actually used for a request.
  String get resolvedBaseUrl =>
      baseUrl.trim().isEmpty ? kind.defaultBaseUrl : baseUrl.trim();

  /// Whether a request could be made at all: somewhere to send and something to
  /// send to. A key is not required — a local server needs none.
  bool get isReady => resolvedBaseUrl.isNotEmpty && model.trim().isNotEmpty;

  /// The full prompt for [prompt]: the standing instructions, the prompt itself,
  /// then anything to avoid. Kept here rather than in the client so the studio
  /// can show exactly what will be sent.
  String composePrompt(String prompt) {
    final parts = <String>[
      systemPrompt.trim(),
      prompt.trim(),
      if (negativePrompt.trim().isNotEmpty) 'Avoid: ${negativePrompt.trim()}',
    ]..removeWhere((p) => p.isEmpty);
    return parts.join('\n\n');
  }

  ImageGenConfig copyWith({
    ImageGenKind? kind,
    String? baseUrl,
    String? apiKey,
    String? model,
    String? size,
    String? quality,
    int? count,
    String? systemPrompt,
    String? negativePrompt,
  }) =>
      ImageGenConfig(
        kind: kind ?? this.kind,
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
        size: size ?? this.size,
        quality: quality ?? this.quality,
        count: count ?? this.count,
        systemPrompt: systemPrompt ?? this.systemPrompt,
        negativePrompt: negativePrompt ?? this.negativePrompt,
      );

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        if (baseUrl.isNotEmpty) 'baseUrl': baseUrl,
        if (apiKey.isNotEmpty) 'apiKey': apiKey,
        if (model.isNotEmpty) 'model': model,
        if (size != 'auto') 'size': size,
        if (quality.isNotEmpty) 'quality': quality,
        if (count != 1) 'count': count,
        if (systemPrompt.isNotEmpty) 'systemPrompt': systemPrompt,
        if (negativePrompt.isNotEmpty) 'negativePrompt': negativePrompt,
      };

  factory ImageGenConfig.fromJson(Map<String, dynamic> json) => ImageGenConfig(
        kind: ImageGenKind.byName(json['kind'] as String?),
        baseUrl: json['baseUrl'] as String? ?? '',
        apiKey: json['apiKey'] as String? ?? '',
        model: json['model'] as String? ?? '',
        size: json['size'] as String? ?? 'auto',
        quality: json['quality'] as String? ?? '',
        count: ((json['count'] as num?)?.toInt() ?? 1).clamp(1, 8),
        systemPrompt: json['systemPrompt'] as String? ?? '',
        negativePrompt: json['negativePrompt'] as String? ?? '',
      );
}
