import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/appearance.dart';
import '../models/character.dart';
import '../models/conversation.dart';
import '../models/provider.dart';
import '../models/settings.dart';

/// The persisted provider list plus which one is active.
class ProviderState {
  const ProviderState(this.providers, this.activeId);
  final List<Provider> providers;
  final String? activeId;
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
  static const _conversationsKey = 'conversations';
  static const _charactersKey = 'characters';
  static const _activeKey = 'activeConversation';

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
}
