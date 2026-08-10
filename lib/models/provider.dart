/// The wire format an endpoint speaks. Each kind carries the label shown in the
/// UI and the base URL to pre-fill when a provider of that kind is created.
enum ProviderKind {
  openai('OpenAI-compatible', 'https://api.openai.com/v1'),
  anthropic('Anthropic', 'https://api.anthropic.com/v1');

  const ProviderKind(this.label, this.defaultBaseUrl);

  final String label;
  final String defaultBaseUrl;

  /// Unknown or missing names fall back to the OpenAI-compatible format, which
  /// is what the vast majority of hosts speak.
  static ProviderKind byName(String? name) {
    for (final kind in values) {
      if (kind.name == name) return kind;
    }
    return ProviderKind.openai;
  }
}

/// One named endpoint the app can talk to: its API format, address, credential
/// and the model currently selected for it. Several can be configured at once,
/// with [AppState] tracking which is active.
class Provider {
  Provider({
    required this.id,
    required this.name,
    required this.kind,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  final String id;
  final String name;
  final ProviderKind kind;
  final String baseUrl;
  final String apiKey;
  final String model;

  /// A blank provider of [kind], pre-filled with that format's default base URL
  /// and a friendly default name.
  factory Provider.create(ProviderKind kind) => Provider(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: kind.label,
        kind: kind,
        baseUrl: kind.defaultBaseUrl,
        apiKey: '',
        model: '',
      );

  /// Usable for chat once it has somewhere to send and a model to name.
  bool get isConfigured =>
      baseUrl.trim().isNotEmpty && model.trim().isNotEmpty;

  /// What to show when the provider has no user-given name.
  String get displayName => name.trim().isEmpty ? kind.label : name.trim();

  Provider copyWith({
    String? name,
    ProviderKind? kind,
    String? baseUrl,
    String? apiKey,
    String? model,
  }) =>
      Provider(
        id: id,
        name: name ?? this.name,
        kind: kind ?? this.kind,
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
      };

  factory Provider.fromJson(Map<String, dynamic> json) => Provider(
        id: json['id'] as String? ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        name: json['name'] as String? ?? '',
        kind: ProviderKind.byName(json['kind'] as String?),
        baseUrl: json['baseUrl'] as String? ?? '',
        apiKey: json['apiKey'] as String? ?? '',
        model: json['model'] as String? ?? '',
      );
}
