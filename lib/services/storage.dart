import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/appearance.dart';
import '../models/backup.dart';
import '../models/character.dart';
import '../models/chat_interface.dart';
import '../models/conversation.dart';
import '../models/discover.dart';
import '../models/embedding.dart';
import '../models/gallery_image.dart';
import '../models/image_gen.dart';
import '../models/lorebook.dart';
import '../models/preset.dart';
import '../models/provider.dart';
import '../models/scenario.dart';
import '../models/settings.dart';
import '../models/view_prefs.dart';
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
  static const _scenariosKey = 'scenarios';
  static const _galleryKey = 'gallery';
  static const _activeKey = 'activeConversation';
  static const _defaultPersonaKey = 'defaultPersona';
  static const _presetsKey = 'presets';
  static const _globalVarsKey = 'macroGlobals';
  static const _modelCacheKey = 'modelCache';
  static const _tokenizerKey = 'tokenizer';
  static const _discoverKey = 'discover';
  static const _embeddingKey = 'embeddings';
  static const _documentsKey = 'documents';
  static const _viewPrefsKey = 'viewPrefs';
  static const _imageGenKey = 'imageGen';
  static const _summaryFoldsKey = 'summaryFolds';
  static const _backupPrefsKey = 'backupPrefs';
  static const _backupsKey = 'backups';

  /// The usage/cost ledger. Its own entry, kept apart from `providers`, because
  /// it is written after every reply where a provider is written almost never —
  /// and a save rewrites the whole entry.
  static const _usageKey = 'usage';

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

  /// The character id new chats adopt as the user's persona ("default persona"),
  /// or null when the user speaks as themselves by default. Its own scalar entry
  /// — the same lightweight shape as the active-conversation id — so changing it
  /// never rewrites the roster or the conversation list.
  Future<String?> loadDefaultPersonaId() async =>
      (await _prefs).getString(_defaultPersonaKey);

  Future<void> saveDefaultPersonaId(String? id) async {
    final prefs = await _prefs;
    if (id == null) {
      await prefs.remove(_defaultPersonaKey);
    } else {
      await prefs.setString(_defaultPersonaKey, id);
    }
  }

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

  /// The reusable scenarios the user has written or imported. Its own entry, like
  /// the lorebooks beside it, so editing one opening does not rewrite the roster.
  Future<List<Scenario>> loadScenarios() async {
    final raw = (await _prefs).getString(_scenariosKey);
    if (raw == null) return <Scenario>[];
    try {
      final json = jsonDecode(raw);
      if (json is List) {
        return json
            .whereType<Map<String, dynamic>>()
            .map(Scenario.fromJson)
            .toList();
      }
    } catch (_) {
      // Same as everywhere else: never let bad data wedge the app.
    }
    return <Scenario>[];
  }

  Future<void> saveScenarios(List<Scenario> scenarios) async =>
      (await _prefs).setString(
        _scenariosKey,
        jsonEncode(scenarios.map((s) => s.toJson()).toList()),
      );

  /// Which shape each browsable section (characters, lorebooks, scenarios) was
  /// last left in. A tiny entry of its own, so flipping the cards/rows toggle
  /// never rewrites anything large.
  Future<ViewPrefs> loadViewPrefs() async {
    final raw = (await _prefs).getString(_viewPrefsKey);
    if (raw == null) return const ViewPrefs();
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) return ViewPrefs.fromJson(json);
    } catch (_) {
      // Defaults beat a startup failure, as everywhere else here.
    }
    return const ViewPrefs();
  }

  Future<void> saveViewPrefs(ViewPrefs prefs) async =>
      (await _prefs).setString(_viewPrefsKey, jsonEncode(prefs.toJson()));

  /// How the image studio talks to its endpoint. Its own small entry, so opening
  /// the studio's settings never rewrites anything large.
  Future<ImageGenConfig> loadImageGen() async {
    final raw = (await _prefs).getString(_imageGenKey);
    if (raw == null) return const ImageGenConfig();
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) return ImageGenConfig.fromJson(json);
    } catch (_) {
      // Defaults beat a startup failure, as everywhere else here.
    }
    return const ImageGenConfig();
  }

  Future<void> saveImageGen(ImageGenConfig config) async =>
      (await _prefs).setString(_imageGenKey, jsonEncode(config.toJson()));

  /// Which memory blocks are folded shut, as `{conversationId: [segmentId, …]}`.
  ///
  /// This is a *view* preference and it lives in its own tiny entry for one
  /// concrete reason: it used to ride on the segment inside `conversations`, so
  /// folding one block re-encoded and rewrote every message of every chat. On a
  /// large store that is tens of milliseconds of JSON on the UI thread — the
  /// micro-freeze on opening a memory block. A fold now costs a few dozen bytes.
  Future<Map<String, Set<String>>> loadSummaryFolds() async {
    final raw = (await _prefs).getString(_summaryFoldsKey);
    if (raw == null) return <String, Set<String>>{};
    try {
      final json = jsonDecode(raw);
      if (json is Map) {
        final out = <String, Set<String>>{};
        for (final entry in json.entries) {
          final ids = entry.value;
          if (ids is! List) continue;
          final set = ids.map((e) => e.toString()).where((s) => s.isNotEmpty);
          if (set.isNotEmpty) out[entry.key.toString()] = set.toSet();
        }
        return out;
      }
    } catch (_) {
      // An unreadable entry just means nothing is remembered folded.
    }
    return <String, Set<String>>{};
  }

  Future<void> saveSummaryFolds(Map<String, Set<String>> folds) async {
    final prefs = await _prefs;
    if (folds.isEmpty) {
      await prefs.remove(_summaryFoldsKey);
      return;
    }
    await prefs.setString(
      _summaryFoldsKey,
      jsonEncode(folds.map((id, ids) => MapEntry(id, ids.toList()))),
    );
  }

  /// The pictures the user keeps in the app's gallery — the records only; the
  /// images themselves are files in the pictures directory, referenced by
  /// [GalleryImage.image]. Its own entry so adding a photo does not rewrite the
  /// character roster, which is the largest thing in the store.
  Future<List<GalleryImage>> loadGallery() async {
    final raw = (await _prefs).getString(_galleryKey);
    if (raw == null) return <GalleryImage>[];
    try {
      final json = jsonDecode(raw);
      if (json is List) {
        return json
            .whereType<Map<String, dynamic>>()
            .map(GalleryImage.fromJson)
            // A record whose picture reference went missing draws nothing and
            // cannot be exported, so it is dropped rather than shown as a hole.
            .where((image) => image.image.isNotEmpty)
            .toList();
      }
    } catch (_) {
      // Same as everywhere else: never let bad data wedge the app.
    }
    return <GalleryImage>[];
  }

  Future<void> saveGallery(List<GalleryImage> images) async =>
      (await _prefs).setString(
        _galleryKey,
        jsonEncode(images.map((i) => i.toJson()).toList()),
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

  /// The raw usage ledger, decoded by [UsageLedger.decode] rather than here, so
  /// the shape lives with the thing that understands it.
  Future<String?> loadUsage() async => (await _prefs).getString(_usageKey);

  Future<void> saveUsage(String encoded) async =>
      (await _prefs).setString(_usageKey, encoded);

  /// Drops the entries that are only a performance cache and cost nothing to
  /// rebuild: the per-provider model lists and the Discover browsing state. The
  /// "Clear cache" action on the Storage screen calls this.
  Future<void> clearCache() async {
    final prefs = await _prefs;
    await prefs.remove(_modelCacheKey);
    await prefs.remove(_discoverKey);
  }

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

  /// The app-wide embedding settings; defaults on a fresh install (feature off).
  Future<EmbeddingConfig> loadEmbeddingConfig() async {
    final raw = (await _prefs).getString(_embeddingKey);
    if (raw != null) {
      try {
        final json = jsonDecode(raw);
        if (json is Map<String, dynamic>) return EmbeddingConfig.fromJson(json);
      } catch (_) {
        // Never let bad data wedge the app.
      }
    }
    return const EmbeddingConfig();
  }

  Future<void> saveEmbeddingConfig(EmbeddingConfig config) async =>
      (await _prefs).setString(_embeddingKey, jsonEncode(config.toJson()));

  /// The Data Bank documents — records only; each document's chunk text and
  /// vectors are a file-backed collection (see [EmbeddingStore]), not here.
  Future<List<EmbeddingDocument>> loadDocuments() async {
    final raw = (await _prefs).getString(_documentsKey);
    if (raw == null) return <EmbeddingDocument>[];
    try {
      final json = jsonDecode(raw);
      if (json is List) {
        return json
            .whereType<Map<String, dynamic>>()
            .map(EmbeddingDocument.fromJson)
            .toList();
      }
    } catch (_) {
      // Never let bad data wedge the app.
    }
    return <EmbeddingDocument>[];
  }

  Future<void> saveDocuments(List<EmbeddingDocument> documents) async =>
      (await _prefs).setString(
        _documentsKey,
        jsonEncode(documents.map((d) => d.toJson()).toList()),
      );

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

  /// The export settings (schedule, destination, what goes in a backup, the
  /// Google Drive grant). Its own small entry, and one a backup never carries —
  /// see `kBackupExcludedKeys`.
  Future<BackupPrefs> loadBackupPrefs() async {
    final raw = (await _prefs).getString(_backupPrefsKey);
    if (raw == null) return const BackupPrefs();
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) return BackupPrefs.fromJson(json);
    } catch (_) {
      // Defaults beat a startup failure, as everywhere else here.
    }
    return const BackupPrefs();
  }

  Future<void> saveBackupPrefs(BackupPrefs prefs) async =>
      (await _prefs).setString(_backupPrefsKey, jsonEncode(prefs.toJson()));

  /// The backups taken so far, newest first — what the Backups screen lists and
  /// its search bar searches.
  Future<List<BackupRecord>> loadBackupRecords() async {
    final raw = (await _prefs).getString(_backupsKey);
    if (raw == null) return <BackupRecord>[];
    try {
      final json = jsonDecode(raw);
      if (json is List) {
        return json
            .whereType<Map<String, dynamic>>()
            .map(BackupRecord.fromJson)
            .where((record) => record.id.isNotEmpty)
            .toList();
      }
    } catch (_) {
      // Same as everywhere else: never let bad data wedge the app.
    }
    return <BackupRecord>[];
  }

  Future<void> saveBackupRecords(List<BackupRecord> records) async =>
      (await _prefs).setString(
        _backupsKey,
        jsonEncode(records.map((r) => r.toJson()).toList()),
      );

  /// Every stored entry, by key — the raw material a backup is made of.
  ///
  /// Deliberately untyped and not enumerated: a backup copies the store as it
  /// stands, so an entry a later version of the app adds is carried out and put
  /// back without this file having to learn about it.
  Future<Map<String, Object?>> dump() async {
    final prefs = await _prefs;
    return <String, Object?>{
      for (final key in prefs.getKeys()) key: prefs.get(key),
    };
  }

  /// Writes [entries] back into the store.
  ///
  /// With [replace] every key that the snapshot does not mention is removed
  /// first — that is what "put this backup back exactly" means, and without it a
  /// character deleted after the backup was taken would survive the restore.
  /// [protect] names the keys a restore must never touch either way.
  Future<void> writeEntries(
    Map<String, Object?> entries, {
    bool replace = false,
    Set<String> protect = const <String>{},
  }) async {
    final prefs = await _prefs;
    if (replace) {
      for (final key in prefs.getKeys().toList()) {
        if (entries.containsKey(key) || protect.contains(key)) continue;
        await prefs.remove(key);
      }
    }
    for (final entry in entries.entries) {
      if (protect.contains(entry.key)) continue;
      final value = entry.value;
      if (value == null) {
        await prefs.remove(entry.key);
      } else if (value is String) {
        await prefs.setString(entry.key, value);
      } else if (value is bool) {
        await prefs.setBool(entry.key, value);
      } else if (value is int) {
        await prefs.setInt(entry.key, value);
      } else if (value is double) {
        await prefs.setDouble(entry.key, value);
      } else if (value is List) {
        await prefs.setStringList(
          entry.key,
          value.map((e) => e.toString()).toList(),
        );
      } else {
        await prefs.setString(entry.key, value.toString());
      }
    }
  }

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
