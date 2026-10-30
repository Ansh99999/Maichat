/// Connection details for any OpenAI-compatible endpoint.
class AppSettings {
  const AppSettings({
    this.baseUrl = defaultBaseUrl,
    this.apiKey = '',
    this.model = '',
  });

  static const String defaultBaseUrl = 'https://api.openai.com/v1';

  final String baseUrl;
  final String apiKey;
  final String model;

  bool get isConfigured => baseUrl.trim().isNotEmpty && model.trim().isNotEmpty;

  AppSettings copyWith({String? baseUrl, String? apiKey, String? model}) =>
      AppSettings(
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
      );

  Map<String, dynamic> toJson() => {
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'model': model,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
    baseUrl: json['baseUrl'] as String? ?? defaultBaseUrl,
    apiKey: json['apiKey'] as String? ?? '',
    model: json['model'] as String? ?? '',
  );
}

enum BtwTitleMode {
  firstLine('First line'),
  generated('AI generated');

  const BtwTitleMode(this.label);
  final String label;
}

/// Side conversation preferences, kept apart from provider credentials.
class BtwSettings {
  const BtwSettings({
    this.titleMode = BtwTitleMode.firstLine,
    this.mainChatArrowOpacity = 1,
  });

  static const minArrowOpacity = 0.1;
  static const maxArrowOpacity = 1.0;

  final BtwTitleMode titleMode;
  final double mainChatArrowOpacity;

  BtwSettings copyWith({
    BtwTitleMode? titleMode,
    double? mainChatArrowOpacity,
  }) => BtwSettings(
    titleMode: titleMode ?? this.titleMode,
    mainChatArrowOpacity: mainChatArrowOpacity ?? this.mainChatArrowOpacity,
  );

  Map<String, dynamic> toJson() => {
    'titleMode': titleMode.name,
    'mainChatArrowOpacity': mainChatArrowOpacity,
  };

  factory BtwSettings.fromJson(Map<String, dynamic> json) => BtwSettings(
    titleMode: json['titleMode'] == BtwTitleMode.generated.name
        ? BtwTitleMode.generated
        : BtwTitleMode.firstLine,
    mainChatArrowOpacity: switch (json['mainChatArrowOpacity']) {
      num value when value.isFinite => value.toDouble().clamp(
        minArrowOpacity,
        maxArrowOpacity,
      ),
      _ => 1,
    },
  );
}
