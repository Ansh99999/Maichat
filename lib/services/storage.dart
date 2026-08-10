import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/appearance.dart';
import '../models/conversation.dart';
import '../models/settings.dart';

/// Persists settings and conversations in app-private storage.
///
/// The API key lives in SharedPreferences, which on Android is private to the
/// app but is not encrypted at rest — adequate for a personal build, not for a
/// shared or rooted device.
class Storage {
  static const _settingsKey = 'settings';
  static const _appearanceKey = 'appearance';
  static const _conversationsKey = 'conversations';
  static const _activeKey = 'activeConversation';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

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
}
