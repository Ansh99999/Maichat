/// The wire format an endpoint speaks. Each kind carries the label shown in the
/// UI and the base URL to pre-fill when a provider of that kind is created.
enum ProviderKind {
  openai('OpenAI-compatible', 'https://api.openai.com/v1'),
  anthropic('Anthropic', 'https://api.anthropic.com/v1'),
  gemini('Google Gemini', 'https://generativelanguage.googleapis.com/v1beta');

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

/// How to pick which key to send when a provider carries more than one. Mirrors
/// the strategies Agnai offers so a pool of keys can spread load or fail over.
enum KeyRotationStrategy {
  /// Cycle through the keys in order, one per request.
  roundRobin('round-robin', 'Round robin'),

  /// Pick a key at random for each request.
  random('random', 'Random'),

  /// Stick with one key until it errors, then move to the next.
  errorBased('error-based', 'Error based');

  const KeyRotationStrategy(this.id, this.label);

  /// The stored/wire id (kept stable and Agnai-compatible).
  final String id;

  /// The human label shown in the picker.
  final String label;

  static KeyRotationStrategy byName(String? id) {
    for (final s in values) {
      if (s.id == id || s.name == id) return s;
    }
    return KeyRotationStrategy.roundRobin;
  }
}

/// One named endpoint the app can talk to: its API format, address, one or more
/// credentials and the model currently selected for it. Several can be
/// configured at once, with [AppState] tracking which is active.
class Provider {
  Provider({
    required this.id,
    required this.name,
    required this.kind,
    required this.baseUrl,
    required this.model,
    String apiKey = '',
    List<String>? apiKeys,
    this.keyStrategy = KeyRotationStrategy.roundRobin,
  }) : apiKeys = apiKeys ??
            (apiKey.isEmpty ? const <String>[] : <String>[apiKey]);

  final String id;
  final String name;
  final ProviderKind kind;
  final String baseUrl;
  final String model;

  /// The pool of credentials. The single-key case is just a one-element list;
  /// an empty list means no key is set. Empty/whitespace entries are ignored at
  /// use time (see [usableKeys]).
  final List<String> apiKeys;

  /// How to choose among [apiKeys] when there is more than one.
  final KeyRotationStrategy keyStrategy;


  /// The first credential worth sending, or empty when none is set. Callers that
  /// only need "a key" (headers, display) read this; rotation happens upstream
  /// in [AppState], which narrows the pool to the chosen key via [withActiveKey].
  String get apiKey {
    for (final key in apiKeys) {
      final trimmed = key.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return '';
  }

  /// The non-empty, trimmed credentials — what rotation actually chooses from.
  List<String> get usableKeys =>
      apiKeys.map((k) => k.trim()).where((k) => k.isNotEmpty).toList();

  /// A blank provider of [kind], pre-filled with that format's default base URL
  /// and a friendly default name.
  factory Provider.create(ProviderKind kind) => Provider(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: kind.label,
        kind: kind,
        baseUrl: kind.defaultBaseUrl,
        model: '',
      );

  /// Usable for chat once it has somewhere to send and a model to name.
  bool get isConfigured =>
      baseUrl.trim().isNotEmpty && model.trim().isNotEmpty;

  /// What to show when the provider has no user-given name.
  String get displayName => name.trim().isEmpty ? kind.label : name.trim();

  /// A copy that will only ever send [key] — used by rotation to pin the chosen
  /// credential for a single request without disturbing the stored pool.
  Provider withActiveKey(String key) => copyWith(apiKeys: <String>[key]);

  Provider copyWith({
    String? name,
    ProviderKind? kind,
    String? baseUrl,
    String? apiKey,
    List<String>? apiKeys,
    KeyRotationStrategy? keyStrategy,
    String? model,
  }) =>
      Provider(
        id: id,
        name: name ?? this.name,
        kind: kind ?? this.kind,
        baseUrl: baseUrl ?? this.baseUrl,
        // A single apiKey override wins; otherwise keep or replace the pool.
        apiKeys: apiKey != null ? <String>[apiKey] : (apiKeys ?? this.apiKeys),
        keyStrategy: keyStrategy ?? this.keyStrategy,
        model: model ?? this.model,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'baseUrl': baseUrl,
        // Kept for readers that predate multi-key support.
        'apiKey': apiKey,
        'apiKeys': apiKeys,
        'keyStrategy': keyStrategy.id,
        'model': model,
      };

  factory Provider.fromJson(Map<String, dynamic> json) => Provider(
        id: json['id'] as String? ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        name: json['name'] as String? ?? '',
        kind: ProviderKind.byName(json['kind'] as String?),
        baseUrl: json['baseUrl'] as String? ?? '',
        apiKeys: (json['apiKeys'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList(),
        apiKey: json['apiKey'] as String? ?? '',
        keyStrategy: KeyRotationStrategy.byName(json['keyStrategy'] as String?),
        model: json['model'] as String? ?? '',
      );
}
