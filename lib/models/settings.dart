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

  bool get isConfigured =>
      baseUrl.trim().isNotEmpty && model.trim().isNotEmpty;

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
