import 'lorebook.dart';
import 'preset.dart';
import 'scenario.dart';

/// The kinds of thing a folder can hold, used by the generic
/// `AppState.addToFolder`/`removeFromFolder` and the "Add to folder" sheet so
/// one code path serves every essential.
enum FolderItemKind {
  character,
  lorebook,
  scenario,
  preset,
  provider,
  document,
  gallery,
}

/// A **folder**: a named bundle of characters and the "essentials" they share —
/// lorebooks, scenarios, presets, providers, embedding documents and gallery
/// pictures — plus a look (a seed [color]) and a set of opt-in behaviours that
/// tie the folder's chats together.
///
/// Membership is held here, by id, rather than on the character: a character can
/// belong to several folders at once (they are just listed in each). Everything
/// in a folder is a **reference** into an existing global collection; the folder
/// only names the ids and, where wanted, keeps a folder-scoped **override** copy
/// that shadows the library original inside this folder alone (the same trick as
/// a per-chat override). A chat is bound to exactly one governing folder, so no
/// two folders ever fight over a chat's defaults — see `Conversation.folderId`.
class Folder {
  Folder({
    required this.id,
    this.name = '',
    this.color = 0,
    this.avatar = '',
    List<String>? tags,
    this.description = '',
    List<String>? characterIds,
    List<String>? lorebookIds,
    List<String>? scenarioIds,
    List<String>? presetIds,
    List<String>? providerIds,
    List<String>? documentIds,
    List<String>? galleryImageIds,
    this.defaultPresetId,
    this.defaultProviderId,
    Map<String, Preset>? presetOverrides,
    Map<String, Lorebook>? lorebookOverrides,
    Map<String, Scenario>? scenarioOverrides,
    this.autoLorebooks = false,
    this.propagateLorebookEdits = false,
    this.sharedSummary = false,
    this.sharedEmbeddings = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : tags = tags ?? <String>[],
        characterIds = characterIds ?? <String>[],
        lorebookIds = lorebookIds ?? <String>[],
        scenarioIds = scenarioIds ?? <String>[],
        presetIds = presetIds ?? <String>[],
        providerIds = providerIds ?? <String>[],
        documentIds = documentIds ?? <String>[],
        galleryImageIds = galleryImageIds ?? <String>[],
        presetOverrides = presetOverrides ?? <String, Preset>{},
        lorebookOverrides = lorebookOverrides ?? <String, Lorebook>{},
        scenarioOverrides = scenarioOverrides ?? <String, Scenario>{},
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;

  /// What the folder is called. Never sent to a model.
  String name;

  /// The folder's look — an ARGB seed colour driving a Material 3 expressive
  /// theme on the folder's own screens. 0 means "no colour picked; use the app
  /// theme".
  int color;

  /// The folder's picture, as an [avatarRef]-style `local:<file>` reference (or
  /// an `http(s)` URL, or empty). The "avatar for file" box in the editor.
  String avatar;

  List<String> tags;
  String description;

  // --- Essentials: references by id into the global collections. ---
  final List<String> characterIds;
  final List<String> lorebookIds;
  final List<String> scenarioIds;
  final List<String> presetIds;
  final List<String> providerIds;
  final List<String> documentIds;
  final List<String> galleryImageIds;

  /// Which referenced preset / provider is this folder's default — seeded onto a
  /// chat opened under the folder. Null means "fall back to the app default".
  String? defaultPresetId;
  String? defaultProviderId;

  // --- Optional folder-scoped override copies, keyed by the item's id. ---
  /// A shadow that replaces the library original *inside this folder only*, read
  /// through `AppState.folderPreset`/`folderLorebook`/`folderScenario` so the
  /// fallback to the library item happens in exactly one place.
  final Map<String, Preset> presetOverrides;
  final Map<String, Lorebook> lorebookOverrides;
  final Map<String, Scenario> scenarioOverrides;

  // --- Ecosystem behaviours. All default OFF; opt-in per folder. ---
  /// Auto-select the folder's lorebooks in a chat opened under the folder.
  bool autoLorebooks;

  /// When a folder lorebook is edited, apply the edit to every chat in the
  /// folder (writes the shared library book rather than a per-chat copy).
  bool propagateLorebookEdits;

  /// Share the rolling summary / semantic-recall documents across the folder's
  /// chats (auto-attached when a chat is opened under the folder).
  bool sharedSummary;
  bool sharedEmbeddings;

  final DateTime createdAt;
  DateTime updatedAt;

  factory Folder.empty() => Folder(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
      );

  String get displayName =>
      name.trim().isEmpty ? 'Untitled folder' : name.trim();

  /// Every picture this folder points at directly (its avatar and any override
  /// copies' pictures), for the avatar-sweep keep-list.
  List<String> get pictureRefs => <String>[
        if (avatar.trim().isNotEmpty) avatar.trim(),
      ];

  /// Whether [query] matches this folder by name, tag, or description.
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) ||
        description.toLowerCase().contains(q) ||
        tags.any((t) => t.toLowerCase().contains(q));
  }

  /// Whether this folder holds [characterId].
  bool holds(String characterId) => characterIds.contains(characterId);

  /// A deep copy under the same id, bumping [updatedAt] — the editor's starting
  /// point (so edits can be discarded) and the target of every mutation.
  Folder clone() => Folder(
        id: id,
        name: name,
        color: color,
        avatar: avatar,
        tags: List<String>.of(tags),
        description: description,
        characterIds: List<String>.of(characterIds),
        lorebookIds: List<String>.of(lorebookIds),
        scenarioIds: List<String>.of(scenarioIds),
        presetIds: List<String>.of(presetIds),
        providerIds: List<String>.of(providerIds),
        documentIds: List<String>.of(documentIds),
        galleryImageIds: List<String>.of(galleryImageIds),
        defaultPresetId: defaultPresetId,
        defaultProviderId: defaultProviderId,
        presetOverrides: presetOverrides
            .map((k, v) => MapEntry(k, Preset.fromJson(v.toJson()))),
        lorebookOverrides: lorebookOverrides
            .map((k, v) => MapEntry(k, Lorebook.fromJson(v.toJson()))),
        scenarioOverrides: scenarioOverrides
            .map((k, v) => MapEntry(k, Scenario.fromJson(v.toJson()))),
        autoLorebooks: autoLorebooks,
        propagateLorebookEdits: propagateLorebookEdits,
        sharedSummary: sharedSummary,
        sharedEmbeddings: sharedEmbeddings,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        if (color != 0) 'color': color,
        if (avatar.trim().isNotEmpty) 'avatar': avatar,
        if (tags.isNotEmpty) 'tags': tags,
        if (description.isNotEmpty) 'description': description,
        if (characterIds.isNotEmpty) 'characterIds': characterIds,
        if (lorebookIds.isNotEmpty) 'lorebookIds': lorebookIds,
        if (scenarioIds.isNotEmpty) 'scenarioIds': scenarioIds,
        if (presetIds.isNotEmpty) 'presetIds': presetIds,
        if (providerIds.isNotEmpty) 'providerIds': providerIds,
        if (documentIds.isNotEmpty) 'documentIds': documentIds,
        if (galleryImageIds.isNotEmpty) 'galleryImageIds': galleryImageIds,
        if (defaultPresetId != null) 'defaultPresetId': defaultPresetId,
        if (defaultProviderId != null) 'defaultProviderId': defaultProviderId,
        if (presetOverrides.isNotEmpty)
          'presetOverrides':
              presetOverrides.map((k, v) => MapEntry(k, v.toJson())),
        if (lorebookOverrides.isNotEmpty)
          'lorebookOverrides':
              lorebookOverrides.map((k, v) => MapEntry(k, v.toJson())),
        if (scenarioOverrides.isNotEmpty)
          'scenarioOverrides':
              scenarioOverrides.map((k, v) => MapEntry(k, v.toJson())),
        if (autoLorebooks) 'autoLorebooks': true,
        if (propagateLorebookEdits) 'propagateLorebookEdits': true,
        if (sharedSummary) 'sharedSummary': true,
        if (sharedEmbeddings) 'sharedEmbeddings': true,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory Folder.fromJson(Map<String, dynamic> json) => Folder(
        id: json['id'] as String? ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        name: json['name'] as String? ?? '',
        color: (json['color'] as num?)?.toInt() ?? 0,
        avatar: json['avatar'] as String? ?? '',
        tags: _folderStrings(json['tags']),
        description: json['description'] as String? ?? '',
        characterIds: _folderStrings(json['characterIds']),
        lorebookIds: _folderStrings(json['lorebookIds']),
        scenarioIds: _folderStrings(json['scenarioIds']),
        presetIds: _folderStrings(json['presetIds']),
        providerIds: _folderStrings(json['providerIds']),
        documentIds: _folderStrings(json['documentIds']),
        galleryImageIds: _folderStrings(json['galleryImageIds']),
        defaultPresetId: (json['defaultPresetId'] as String?)?.trim().isEmpty ??
                true
            ? null
            : (json['defaultPresetId'] as String).trim(),
        defaultProviderId:
            (json['defaultProviderId'] as String?)?.trim().isEmpty ?? true
                ? null
                : (json['defaultProviderId'] as String).trim(),
        presetOverrides: _presetMap(json['presetOverrides']),
        lorebookOverrides: _lorebookMap(json['lorebookOverrides']),
        scenarioOverrides: _scenarioMap(json['scenarioOverrides']),
        autoLorebooks: json['autoLorebooks'] as bool? ?? false,
        propagateLorebookEdits:
            json['propagateLorebookEdits'] as bool? ?? false,
        sharedSummary: json['sharedSummary'] as bool? ?? false,
        sharedEmbeddings: json['sharedEmbeddings'] as bool? ?? false,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
      );

  static Map<String, Preset>? _presetMap(Object? value) {
    if (value is! Map) return null;
    final out = <String, Preset>{};
    for (final entry in value.entries) {
      final v = entry.value;
      if (v is Map<String, dynamic>) {
        out[entry.key.toString()] = Preset.fromJson(v);
      }
    }
    return out;
  }

  static Map<String, Lorebook>? _lorebookMap(Object? value) {
    if (value is! Map) return null;
    final out = <String, Lorebook>{};
    for (final entry in value.entries) {
      final v = entry.value;
      if (v is Map<String, dynamic>) {
        out[entry.key.toString()] = Lorebook.fromJson(v);
      }
    }
    return out;
  }

  static Map<String, Scenario>? _scenarioMap(Object? value) {
    if (value is! Map) return null;
    final out = <String, Scenario>{};
    for (final entry in value.entries) {
      final v = entry.value;
      if (v is Map<String, dynamic>) {
        out[entry.key.toString()] = Scenario.fromJson(v);
      }
    }
    return out;
  }
}

/// Reads a string-id list, tolerating a comma-joined string and dropping blanks
/// — the same leniency the other model readers apply.
List<String> _folderStrings(Object? value) {
  if (value is String) {
    return value
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }
  if (value is! List) return <String>[];
  return value
      .map((e) => e?.toString().trim() ?? '')
      .where((s) => s.isNotEmpty)
      .toList();
}
