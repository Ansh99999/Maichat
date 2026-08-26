import 'budget.dart';
import 'model_pricing.dart';

/// The wire dialect an endpoint actually speaks.
///
/// Kept separate from [ProviderKind] on purpose: several kinds share one
/// dialect — a local llama.cpp server and OpenAI itself both speak
/// [WireFormat.openaiChat] — so [ChatClient] switches on this (a handful of real
/// cases) while the kind stays a user-facing label. A future kind that reuses a
/// dialect then costs nothing in the client.
enum WireFormat {
  /// `POST /chat/completions`, SSE terminated by `[DONE]`.
  openaiChat,

  /// `POST /responses` — OpenAI's newer API, with typed SSE events.
  openaiResponses,

  /// `POST /messages`, SSE terminated by `message_stop`.
  anthropic,

  /// `POST /models/<model>:streamGenerateContent?alt=sse`.
  gemini,
}

/// The wire format an endpoint speaks. Each kind carries the label shown in the
/// UI, the base URL to pre-fill, and the dialect it talks.
enum ProviderKind {
  openai(
    'OpenAI chat/completions',
    'https://api.openai.com/v1',
    WireFormat.openaiChat,
  ),
  openaiResponses(
    'OpenAI v1/responses',
    'https://api.openai.com/v1',
    WireFormat.openaiResponses,
  ),
  anthropic(
    'Anthropic',
    'https://api.anthropic.com/v1',
    WireFormat.anthropic,
  ),
  gemini(
    'Google Gemini',
    'https://generativelanguage.googleapis.com/v1beta',
    WireFormat.gemini,
  ),
  localLlm(
    'Local LLM (HTTP)',
    'http://127.0.0.1:11434/v1',
    WireFormat.openaiChat,
    prefersHttp: true,
    requiresKey: false,
  ),
  koboldCpp(
    'KoboldCPP',
    'http://127.0.0.1:5001/v1',
    WireFormat.openaiChat,
    prefersHttp: true,
    requiresKey: false,
  );

  const ProviderKind(
    this.label,
    this.defaultBaseUrl,
    this.wire, {
    this.prefersHttp = false,
    this.requiresKey = true,
  });

  final String label;
  final String defaultBaseUrl;

  /// The dialect [ChatClient] should speak to this kind.
  final WireFormat wire;

  /// True for the kinds that normally live on loopback or a LAN address, where a
  /// scheme-less base URL should become `http://` rather than `https://`.
  final bool prefersHttp;

  /// False where a key is genuinely optional, so the UI stops nagging for one.
  final bool requiresKey;

  /// The helper line under the base-URL field. Lives on the kind so the editor
  /// does not need a `switch` that has to be revisited for every new format.
  String get baseUrlHelper => switch (this) {
        ProviderKind.anthropic => 'Anthropic API root, usually ending in /v1',
        ProviderKind.gemini => 'Gemini API root (…/v1beta)',
        ProviderKind.openaiResponses =>
          'OpenAI-compatible root serving /responses, usually ending in /v1',
        ProviderKind.localLlm =>
          'Your server’s address, e.g. http://127.0.0.1:11434/v1',
        ProviderKind.koboldCpp =>
          'KoboldCPP’s OpenAI-compatible root, e.g. http://127.0.0.1:5001/v1',
        ProviderKind.openai => 'OpenAI-compatible root, usually ending in /v1',
      };

  /// An example model id, shown as the model field's hint.
  String get modelHint => switch (this) {
        ProviderKind.anthropic => 'claude-sonnet-4-5',
        ProviderKind.gemini => 'gemini-2.5-flash',
        ProviderKind.openaiResponses => 'gpt-5',
        ProviderKind.localLlm => 'llama3.1',
        ProviderKind.koboldCpp => 'koboldcpp/model',
        ProviderKind.openai => 'gpt-4o-mini',
      };

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
    List<ModelPrice>? prices,
    List<String>? fallbackModels,
    Map<String, String>? customHeaders,
    this.claudeCodeHeaders = false,
    List<Budget>? budgets,
  })  : apiKeys = apiKeys ??
            (apiKey.isEmpty ? const <String>[] : <String>[apiKey]),
        prices = prices ?? const <ModelPrice>[],
        fallbackModels = fallbackModels ?? const <String>[],
        customHeaders = customHeaders ?? const <String, String>{},
        budgets = budgets ?? const <Budget>[];

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

  /// What each model on this provider costs. Per-provider rather than app-wide
  /// because the same model id is priced differently by different hosts.
  final List<ModelPrice> prices;

  /// Models to try, in order, when [model] fails — but only while nothing has
  /// streamed yet. Once text is on screen a retry would duplicate it.
  final List<String> fallbackModels;

  /// Extra headers merged into every request, last, so they can override the
  /// app's own. Sent verbatim.
  final Map<String, String> customHeaders;

  /// Send the headers Claude Code identifies itself with.
  final bool claudeCodeHeaders;

  /// Spending ceilings the user has set on this provider.
  final List<Budget> budgets;

  /// The dialect this provider's kind speaks.
  WireFormat get wire => kind.wire;


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

  /// The price that applies to [forModel] (defaulting to the selected model), or
  /// null when this provider has no price for it. Null means unknown, not free.
  ModelPrice? priceOf([String? forModel]) =>
      priceFor(prices, (forModel ?? model).trim());

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
    List<ModelPrice>? prices,
    List<String>? fallbackModels,
    Map<String, String>? customHeaders,
    bool? claudeCodeHeaders,
    List<Budget>? budgets,
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
        prices: prices ?? this.prices,
        fallbackModels: fallbackModels ?? this.fallbackModels,
        customHeaders: customHeaders ?? this.customHeaders,
        claudeCodeHeaders: claudeCodeHeaders ?? this.claudeCodeHeaders,
        budgets: budgets ?? this.budgets,
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
        // Only written when set, so an untouched provider's entry stays as small
        // as it was before any of this existed.
        if (prices.isNotEmpty)
          'prices': [for (final price in prices) price.toJson()],
        if (fallbackModels.isNotEmpty) 'fallbackModels': fallbackModels,
        if (customHeaders.isNotEmpty) 'customHeaders': customHeaders,
        if (claudeCodeHeaders) 'claudeCodeHeaders': true,
        if (budgets.isNotEmpty)
          'budgets': [for (final budget in budgets) budget.toJson()],
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
        prices: (json['prices'] as List<dynamic>?)
            ?.whereType<Map<String, dynamic>>()
            .map(ModelPrice.fromJson)
            .toList(),
        fallbackModels: (json['fallbackModels'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList(),
        customHeaders: (json['customHeaders'] as Map<dynamic, dynamic>?)
            ?.map((k, v) => MapEntry(k.toString(), v.toString())),
        claudeCodeHeaders: json['claudeCodeHeaders'] as bool? ?? false,
        budgets: (json['budgets'] as List<dynamic>?)
            ?.whereType<Map<String, dynamic>>()
            .map(Budget.fromJson)
            .toList(),
      );
}
