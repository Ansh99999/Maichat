import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/character.dart';
import '../models/folder.dart';
import '../models/gallery_image.dart';
import '../models/lorebook.dart';
import '../models/preset.dart';
import '../models/provider.dart';
import '../models/scenario.dart';
import '../state/app_state.dart';
import 'avatar_store.dart';

const String _folderFormat = 'maichat.folder';
const int _folderFormatVersion = 1;

/// Imports and exports one portable, self-contained folder document.
class FolderIO {
  const FolderIO._();

  /// Bundles the folder, every referenced global model, and local picture bytes.
  static Map<String, dynamic> encode(Folder folder, AppState state) {
    final characters = <Character>[
      for (final id in folder.characterIds) ?state.characterById(id),
    ];
    final lorebooks = <Lorebook>[
      for (final id in folder.lorebookIds) ?state.lorebookById(id),
    ];
    final scenarios = <Scenario>[
      for (final id in folder.scenarioIds) ?state.scenarioById(id),
    ];
    final presets = <Preset>[
      for (final id in folder.presetIds) ?state.presetById(id),
    ];
    final providers = <Provider>[
      for (final id in folder.providerIds) ?state.providerById(id),
    ];
    final documents = [
      for (final id in folder.documentIds) ?state.documentById(id),
    ];
    final gallery = <GalleryImage>[
      for (final id in folder.galleryImageIds) ?state.galleryImageById(id),
    ];

    final refs = <String>{folder.avatar};
    for (final character in characters) {
      refs
        ..add(character.avatar)
        ..addAll(character.avatars);
    }
    for (final book in lorebooks) {
      refs.add(book.thumbnail);
    }
    for (final book in folder.lorebookOverrides.values) {
      refs.add(book.thumbnail);
    }
    for (final image in gallery) {
      refs.add(image.image);
    }

    final pictures = <String, String>{};
    for (final ref in refs.where((ref) => ref.trim().isNotEmpty)) {
      final file = avatarRefFile(ref);
      if (file == null) continue;
      try {
        final bytes = file.readAsBytesSync();
        if (bytes.isNotEmpty) pictures[ref] = base64Encode(bytes);
      } catch (_) {
        // Missing local pictures are omitted; URLs remain usable as-is.
      }
    }

    return <String, dynamic>{
      'format': _folderFormat,
      'formatVersion': _folderFormatVersion,
      'folder': folder.toJson(),
      'items': <String, dynamic>{
        'characters': characters.map((item) => item.toJson()).toList(),
        'lorebooks': lorebooks.map((item) => item.toJson()).toList(),
        'scenarios': scenarios.map((item) => item.toJson()).toList(),
        'presets': presets.map((item) => item.toJson()).toList(),
        'providers': providers.map((item) => item.toJson()).toList(),
        'documents': documents.map((item) => item.toJson()).toList(),
        'gallery': gallery.map((item) => item.toJson()).toList(),
      },
      if (pictures.isNotEmpty) 'pictures': pictures,
    };
  }

  static bool looksLikeFolderFile(String jsonText) {
    try {
      final decoded = jsonDecode(jsonText);
      return decoded is Map && decoded['format'] == _folderFormat;
    } catch (_) {
      return false;
    }
  }

  static Future<void> exportFolder(
    BuildContext context,
    Folder folder,
    AppState state,
  ) async {
    final text = const JsonEncoder.withIndent(
      '  ',
    ).convert(encode(folder, state));
    String? path;
    try {
      path = await FilePicker.saveFile(
        dialogTitle: 'Save folder',
        fileName: '${_safeName(folder.displayName)}.folder.json',
        bytes: Uint8List.fromList(utf8.encode(text)),
        type: FileType.custom,
        allowedExtensions: const <String>['json'],
      );
    } catch (_) {
      path = null;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(path == null ? 'Export cancelled.' : 'Saved to $path'),
      ),
    );
  }

  /// Picks, validates and imports a folder. The caller decides whether to save it.
  static Future<Folder?> importFolder(
    BuildContext context,
    AppState state,
  ) async {
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        dialogTitle: 'Import folder',
        type: FileType.any,
        allowMultiple: false,
        withData: false,
      );
    } catch (_) {
      result = null;
    }
    final picked = result?.files.singleOrNull;
    if (picked == null) return null;

    try {
      final String text;
      if (picked.path != null) {
        text = await File(picked.path!).readAsString();
      } else if (picked.bytes != null) {
        text = utf8.decode(picked.bytes!);
      } else {
        throw const FormatException('The selected file could not be read.');
      }
      final folder = await _decodeAndStore(text, state);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Imported ${folder.displayName}.')),
        );
      }
      return folder;
    } on FormatException catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
      return null;
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not import that folder.')),
        );
      }
      return null;
    }
  }

  static Future<Folder> _decodeAndStore(String text, AppState state) async {
    final decoded = jsonDecode(text);
    if (decoded is! Map || decoded['format'] != _folderFormat) {
      throw const FormatException('That file is not a MaiChat folder.');
    }
    final version = (decoded['formatVersion'] as num?)?.toInt() ?? 1;
    if (version > _folderFormatVersion) {
      throw const FormatException(
        'That folder was saved by a newer version of MaiChat.',
      );
    }
    final rawFolder = _jsonMap(decoded['folder']);
    if (rawFolder == null) {
      throw const FormatException('That folder file has no folder in it.');
    }

    final rewritten = await _restorePictures(decoded['pictures']);
    _rewriteFolderPictures(rawFolder, rewritten);
    final items = _jsonMap(decoded['items']) ?? <String, dynamic>{};

    for (final raw in _jsonList(items['characters'])) {
      _rewriteCharacterPictures(raw, rewritten);
      final item = Character.fromJson(raw);
      if (state.characterById(item.id) == null) await state.addCharacter(item);
    }
    for (final raw in _jsonList(items['lorebooks'])) {
      _rewriteKey(raw, 'thumbnail', rewritten);
      final item = Lorebook.fromJson(raw);
      if (state.lorebookById(item.id) == null) await state.addLorebook(item);
    }
    for (final raw in _jsonList(items['scenarios'])) {
      final item = Scenario.fromJson(raw);
      if (state.scenarioById(item.id) == null) await state.addScenario(item);
    }
    for (final raw in _jsonList(items['presets'])) {
      final item = Preset.fromJson(raw);
      if (state.presetById(item.id) == null) await state.addPreset(item);
    }
    for (final raw in _jsonList(items['providers'])) {
      final item = Provider.fromJson(raw);
      if (state.providerById(item.id) == null) await state.addProvider(item);
    }

    final galleryIdMap = <String, String>{};
    for (final raw in _jsonList(items['gallery'])) {
      final original = GalleryImage.fromJson(raw);
      if (state.galleryImageById(original.id) != null) continue;
      final encoded = (decoded['pictures'] as Map?)?[original.image];
      if (encoded is! String) continue;
      Uint8List bytes;
      try {
        bytes = base64Decode(encoded);
      } catch (_) {
        continue;
      }
      final added = await state.addGalleryImages(
        <Uint8List>[bytes],
        characterId: original.characterId,
        title: original.title,
        tags: original.tags,
      );
      if (added.isNotEmpty) galleryIdMap[original.id] = added.single.id;
    }

    if (galleryIdMap.isNotEmpty && rawFolder['galleryImageIds'] is List) {
      rawFolder['galleryImageIds'] = <String>[
        for (final id in rawFolder['galleryImageIds'] as List)
          galleryIdMap[id.toString()] ?? id.toString(),
      ];
    }
    if (state.folderById(rawFolder['id']?.toString()) != null) {
      rawFolder['id'] = DateTime.now().microsecondsSinceEpoch.toString();
      rawFolder['createdAt'] = DateTime.now().toIso8601String();
      rawFolder['updatedAt'] = rawFolder['createdAt'];
    }
    return Folder.fromJson(rawFolder);
  }

  static Future<Map<String, String>> _restorePictures(Object? raw) async {
    final out = <String, String>{};
    if (raw is! Map) return out;
    final store = await AvatarStore.open();
    if (store == null) return out;
    for (final entry in raw.entries) {
      if (entry.value is! String) continue;
      try {
        final bytes = base64Decode(entry.value as String);
        if (bytes.isNotEmpty) {
          out[entry.key.toString()] = await store.write(bytes);
        }
      } catch (_) {
        // One damaged picture does not make the folder's text data unusable.
      }
    }
    return out;
  }

  static void _rewriteFolderPictures(
    Map<String, dynamic> folder,
    Map<String, String> rewritten,
  ) {
    _rewriteKey(folder, 'avatar', rewritten);
    final overrides = folder['lorebookOverrides'];
    if (overrides is Map) {
      for (final value in overrides.values) {
        if (value is Map) _rewriteKey(value, 'thumbnail', rewritten);
      }
    }
  }

  static void _rewriteCharacterPictures(
    Map<String, dynamic> character,
    Map<String, String> rewritten,
  ) {
    _rewriteKey(character, 'avatar', rewritten);
    final avatars = character['avatars'];
    if (avatars is List) {
      character['avatars'] = <String>[
        for (final ref in avatars)
          rewritten[ref.toString()] ?? _portableRef(ref.toString()),
      ].where((ref) => ref.isNotEmpty).toList();
    }
  }

  static void _rewriteKey(
    Map<dynamic, dynamic> json,
    String key,
    Map<String, String> rewritten,
  ) {
    final old = json[key]?.toString() ?? '';
    json[key] = rewritten[old] ?? _portableRef(old);
  }

  static String _portableRef(String ref) {
    if (ref.startsWith('http://') || ref.startsWith('https://')) return ref;
    return avatarIsLocal(ref) ? '' : ref;
  }

  static Map<String, dynamic>? _jsonMap(Object? value) => value is Map
      ? value.map((key, value) => MapEntry(key.toString(), value))
      : null;

  static List<Map<String, dynamic>> _jsonList(Object? value) => value is List
      ? value.map(_jsonMap).whereType<Map<String, dynamic>>().toList()
      : <Map<String, dynamic>>[];

  static String _safeName(String value) {
    final safe = value
        .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_');
    return safe.isEmpty ? 'folder' : safe;
  }
}
