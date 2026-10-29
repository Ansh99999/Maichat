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

/// Preferences for new side conversations. Kept outside the legacy provider
/// settings so changing a title preference never rewrites credentials.
class BtwSettings {
  const BtwSettings({this.titleMode = BtwTitleMode.firstLine});

  final BtwTitleMode titleMode;

  BtwSettings copyWith({BtwTitleMode? titleMode}) =>
      BtwSettings(titleMode: titleMode ?? this.titleMode);

  Map<String, dynamic> toJson() => {'titleMode': titleMode.name};

  factory BtwSettings.fromJson(Map<String, dynamic> json) => BtwSettings(
    titleMode: json['titleMode'] == BtwTitleMode.generated.name
        ? BtwTitleMode.generated
        : BtwTitleMode.firstLine,
  );
}
