import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/appearance.dart';
import '../models/character.dart';
import '../models/chat_interface.dart';
import '../models/conversation.dart';
import '../models/discover.dart';
import '../models/lorebook.dart';
import '../models/preset.dart';
import '../models/provider.dart';
import '../models/settings.dart';
import 'tokenizer.dart';

/// The persisted provider list plus which one is active.
class ProviderState {
  const ProviderState(this.providers, this.activeId);
  final List<Provider> providers;
  final String? activeId;
}

/// The persisted preset list plus which one new chats default to.
class PresetState {
  const PresetState(this.presets, this.defaultId);
  final List<Preset> presets;
  final String? defaultId;
}

/// Persists settings and conversations in app-private storage.
///
/// The API key lives in SharedPreferences, which on Android is private to the
/// app but is not encrypted at rest — adequate for a personal build, not for a
/// shared or rooted device.
class Storage {
  static const _settingsKey = 'settings';
  static const _providersKey = 'providers';
  static const _appearanceKey = 'appearance';
  static const _chatInterfaceKey = 'chatInterface';
  static const _conversationsKey = 'conversations';
  static const _charactersKey = 'characters';
  static const _lorebooksKey = 'lorebooks';
  static const _activeKey = 'activeConversation';
  static const _presetsKey = 'presets';
  static const _globalVarsKey = 'macroGlobals';
  static const _modelCacheKey = 'modelCache';
  static const _tokenizerKey = 'tokenizer';
  static const _discoverKey = 'discover';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  /// Loads the configured providers. If none are stored yet, a legacy
  /// single-provider [AppSettings] entry (from before multi-provider support)
  /// is migrated into one active provider so upgrades keep working.
  Future<ProviderState> loadProviders() async {
    final prefs = await _prefs;
    final raw = prefs.getString(_providersKey);
    if (raw != null) {
      try {
        final json = jsonDecode(raw);
        if (json is Map<String, dynamic>) {
          final list = (json['providers'] as List<dynamic>? ?? <dynamic>[])
              .whereType<Map<String, dynamic>>()
              .map(Provider.fromJson)
              .toList();
          return ProviderState(list, json['activeId'] as String?);
        }
      } catch (_) {
        // Corrupt entry: fall back to migration/empty rather than blocking.
      }
    }
    return _migrateLegacy(prefs);
  }

  /// Turns a pre-multi-provider [AppSettings] blob into a single provider, or
  /// returns an empty state on a genuinely fresh install.
  Future<ProviderState> _migrateLegacy(SharedPreferences prefs) async {
    final legacyRaw = prefs.getString(_settingsKey);
    if (legacyRaw == null) return const ProviderState(<Provider>[], null);
    try {
      final json = jsonDecode(legacyRaw);
      if (json is Map<String, dynamic>) {
        final old = AppSettings.fromJson(json);
        final host = Uri.tryParse(old.baseUrl)?.host ?? '';
        final provider = Provider(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: host.isEmpty ? ProviderKind.openai.label : host,
          kind: ProviderKind.openai,
          baseUrl: old.baseUrl,
          apiKey: old.apiKey,
          model: old.model,
        );
        final state = ProviderState(<Provider>[provider], provider.id);
        await saveProviders(state);
        return state;
      }
    } catch (_) {
      // Unreadable legacy blob: start clean.
    }
    return const ProviderState(<Provider>[], null);
  }

  Future<void> saveProviders(ProviderState state) async =>
      (await _prefs).setString(
        _providersKey,
        jsonEncode({
          'providers': state.providers.map((p) => p.toJson()).toList(),
          'activeId': state.activeId,
        }),
      );

  Future<AppSettings> loadSettings() async {
    final raw = (await _prefs).getString(_settingsKey);
    if (raw == null) return const AppSettings();
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) return AppSettings.fromJson(json);
    } catch (_) {
      // Corrupt entry: fall back to defaults rather than blocking startup.
    }
    return const AppSettings();
  }

  Future<void> saveSettings(AppSettings settings) async =>
      (await _prefs).setString(_settingsKey, jsonEncode(settings.toJson()));

  Future<Appearance> loadAppearance() async {
    final raw = (await _prefs).getString(_appearanceKey);
    if (raw == null) return const Appearance();
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) return Appearance.fromJson(json);
    } catch (_) {
      // Same as settings: defaults beat a startup failure.
    }
    return const Appearance();
  }

  Future<void> saveAppearance(Appearance appearance) async =>
      (await _prefs).setString(_appearanceKey, jsonEncode(appearance.toJson()));

  Future<ChatInterface> loadChatInterface() async {
    final raw = (await _prefs).getString(_chatInterfaceKey);
    if (raw == null) return const ChatInterface();
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) return ChatInterface.fromJson(json);
    } catch (_) {
      // Defaults beat a startup failure, as everywhere else here.
    }
    return const ChatInterface();
  }

  Future<void> saveChatInterface(ChatInterface ui) async =>
      (await _prefs).setString(_chatInterfaceKey, jsonEncode(ui.toJson()));

  Future<List<Conversation>> loadConversations() async {
    final raw = (await _prefs).getString(_conversationsKey);
    if (raw == null) return <Conversation>[];
    try {
      final json = jsonDecode(raw);
      if (json is List) {
        return json
            .whereType<Map<String, dynamic>>()
            .map(Conversation.fromJson)
            .toList();
      }
    } catch (_) {
      // Same as settings: never let bad data wedge the app.
    }
    return <Conversation>[];
  }

  Future<void> saveConversations(List<Conversation> conversations) async =>
      (await _prefs).setString(
        _conversationsKey,
        jsonEncode(conversations.map((c) => c.toJson()).toList()),
      );

  Future<String?> loadActiveId() async => (await _prefs).getString(_activeKey);

  Future<void> saveActiveId(String id) async =>
      (await _prefs).setString(_activeKey, id);

  Future<List<Character>> loadCharacters() async {
    final raw = (await _prefs).getString(_charactersKey);
    if (raw == null) return <Character>[];
    try {
      final json = jsonDecode(raw);
      if (json is List) {
        return json
            .whereType<Map<String, dynamic>>()
            .map(Character.fromJson)
            .toList();
      }
    } catch (_) {
      // Same as everywhere else: never let bad data wedge the app.
    }
    return <Character>[];
  }

  Future<void> saveCharacters(List<Character> characters) async =>
      (await _prefs).setString(
        _charactersKey,
        jsonEncode(characters.map((c) => c.toJson()).toList()),
      );

  /// The lorebooks (world info / memory books) the user has saved. Kept in its
  /// own entry rather than beside the characters so editing a book does not
  /// rewrite the roster, which is the largest thing in the store.
  Future<List<Lorebook>> loadLorebooks() async {
    final raw = (await _prefs).getString(_lorebooksKey);
    if (raw == null) return <Lorebook>[];
    try {
      final json = jsonDecode(raw);
      if (json is List) {
        return json
            .whereType<Map<String, dynamic>>()
            .map(Lorebook.fromJson)
            .toList();
      }
    } catch (_) {
      // Same as everywhere else: never let bad data wedge the app.
    }
    return <Lorebook>[];
  }

  Future<void> saveLorebooks(List<Lorebook> books) async =>
      (await _prefs).setString(
        _lorebooksKey,
        jsonEncode(books.map((b) => b.toJson()).toList()),
      );

  /// Loads stored presets and the default-preset id, or an empty state on a
  /// fresh install (the caller seeds a built-in default).
  Future<PresetState> loadPresets() async {
    final raw = (await _prefs).getString(_presetsKey);
    if (raw != null) {
      try {
        final json = jsonDecode(raw);
        if (json is Map<String, dynamic>) {
          final list = (json['presets'] as List<dynamic>? ?? <dynamic>[])
              .whereType<Map<String, dynamic>>()
              .map(Preset.fromJson)
              .toList();
          return PresetState(list, json['defaultId'] as String?);
        }
      } catch (_) {
        // Corrupt entry: start clean rather than blocking startup.
      }
    }
    return const PresetState(<Preset>[], null);
  }

  Future<void> savePresets(PresetState state) async =>
      (await _prefs).setString(
        _presetsKey,
        jsonEncode({
          'presets': state.presets.map((p) => p.toJson()).toList(),
          'defaultId': state.defaultId,
        }),
      );

  /// App-wide macro variables ({{setglobalvar}} scope).
  Future<Map<String, String>> loadGlobalVars() async {
    final raw = (await _prefs).getString(_globalVarsKey);
    if (raw == null) return <String, String>{};
    try {
      final json = jsonDecode(raw);
      if (json is Map) {
        return json.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
      }
    } catch (_) {
      // Same as everywhere else: never let bad data wedge the app.
    }
    return <String, String>{};
  }

  Future<void> saveGlobalVars(Map<String, String> vars) async =>
      (await _prefs).setString(_globalVarsKey, jsonEncode(vars));

  /// The last model list fetched per provider id, so the picker need not hit
  /// the network every time it opens.
  Future<Map<String, List<String>>> loadModelCache() async {
    final raw = (await _prefs).getString(_modelCacheKey);
    if (raw == null) return <String, List<String>>{};
    try {
      final json = jsonDecode(raw);
      if (json is Map) {
        return json.map((k, v) => MapEntry(
              k.toString(),
              (v as List?)?.map((e) => e.toString()).toList() ?? <String>[],
            ));
      }
    } catch (_) {
      // Same as everywhere else: never let bad data wedge the app.
    }
    return <String, List<String>>{};
  }

  Future<void> saveModelCache(Map<String, List<String>> cache) async =>
      (await _prefs).setString(_modelCacheKey, jsonEncode(cache));

  /// The app-wide tokenizer choice (OpenAI / Anthropic / Custom + encoding).
  Future<TokenizerConfig> loadTokenizerConfig() async {
    final raw = (await _prefs).getString(_tokenizerKey);
    if (raw == null) return const TokenizerConfig();
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) return TokenizerConfig.fromJson(json);
    } catch (_) {
      // Defaults beat a startup failure, as everywhere else here.
    }
    return const TokenizerConfig();
  }

  Future<void> saveTokenizerConfig(TokenizerConfig config) async =>
      (await _prefs).setString(_tokenizerKey, jsonEncode(config.toJson()));

  /// What Discover was left set to: the selected catalogue, whether adult
  /// results are allowed, and each section's ordering.
  Future<DiscoverPrefs> loadDiscoverPrefs() async {
    final raw = (await _prefs).getString(_discoverKey);
    if (raw == null) return const DiscoverPrefs();
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) return DiscoverPrefs.fromJson(json);
    } catch (_) {
      // Defaults beat a startup failure, as everywhere else here.
    }
    return const DiscoverPrefs();
  }

  Future<void> saveDiscoverPrefs(DiscoverPrefs prefs) async =>
      (await _prefs).setString(_discoverKey, jsonEncode(prefs.toJson()));

  /// How much room each stored entry takes, in bytes, largest first.
  ///
  /// The whole store is read into memory at every launch and rewritten whole on
  /// every save, so one oversized entry — a character avatar straight off the
  /// camera roll, say — slows down starting the app and sending a message. This
  /// is the readout behind Settings ▸ About ▸ Storage, so that is visible
  /// instead of merely felt.
  Future<Map<String, int>> usage() async {
    final prefs = await _prefs;
    final sizes = <String, int>{};
    for (final key in prefs.getKeys()) {
      final value = prefs.get(key);
      sizes[key] = value is String
          ? utf8.encode(value).length
          : value.toString().length;
    }
    final ordered = sizes.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Map<String, int>.fromEntries(ordered);
  }
}
