import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../models/studio.dart';

/// Where Character Studio sessions live: one JSON file each in a `studio/`
/// folder beside the pictures and vectors.
///
/// Files rather than preferences for the reason everything large in this app is
/// a file: the preferences store is read whole at every launch, and a
/// transcript full of tool output would grow it without limit.
class StudioStore {
  StudioStore(this.directory);

  final Directory directory;

  static StudioStore? _shared;

  /// The store [open] handed out, if it has been opened.
  static StudioStore? get shared => _shared;

  /// The app's store, opened (and the folder created) on first use. Null when
  /// the platform will not name a folder, in which case the Studio says so.
  static Future<StudioStore?> open() async {
    if (_shared != null) return _shared;
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/studio');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return _shared = StudioStore(dir);
    } catch (error) {
      debugPrint('MaiChat: no studio directory available ($error)');
      return null;
    }
  }

  File _fileFor(String id) {
    // Ids are made here and are numeric, but a stray character must never let
    // a write escape the folder.
    final safe = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return File('${directory.path}/$safe.json');
  }

  /// Every readable session, most recently touched first. A file that will not
  /// parse is skipped rather than failing the list.
  Future<List<StudioSession>> list() async {
    final out = <StudioSession>[];
    if (!directory.existsSync()) return out;
    for (final entity in directory.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final json = jsonDecode(await entity.readAsString());
        if (json is Map<String, dynamic>) out.add(StudioSession.fromJson(json));
      } catch (error) {
        debugPrint('MaiChat: skipped an unreadable studio session ($error)');
      }
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  Future<StudioSession?> read(String id) async {
    final file = _fileFor(id);
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(await file.readAsString());
      return json is Map<String, dynamic> ? StudioSession.fromJson(json) : null;
    } catch (_) {
      return null;
    }
  }

  /// Writes [session] through a temporary file and a rename, so a crash mid-
  /// write leaves the previous save rather than half a file.
  Future<void> save(StudioSession session) async {
    final file = _fileFor(session.id);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(session.toJson()), flush: true);
    await temp.rename(file.path);
  }

  /// Every picture ref a stored session names: the draft's portrait and its
  /// pool, its lorebooks' thumbnails, and every picture sent to the Studio or
  /// to one of its sub-agents. What the picture sweep must keep.
  Future<List<String>> pictureRefs() async {
    final refs = <String>[];
    for (final session in await list()) {
      final c = session.workspace.character;
      refs
        ..add(c.avatar)
        ..addAll(c.avatars)
        ..addAll(session.workspace.lorebooks.map((b) => b.thumbnail));
      for (final m in [
        ...session.transcript,
        for (final a in session.subagents) ...a.transcript,
      ]) {
        refs.addAll(m.images.map((i) => i.ref));
      }
      // Pictures sent with a message nobody has read yet are kept too.
      for (final q in [
        ...session.queued,
        for (final a in session.subagents) ...a.queued,
      ]) {
        refs.addAll(q.images.map((i) => i.ref));
      }
      // The Playground's chats are chats like any other, with pictures in
      // their turns, behind them and floating over them.
      for (final p in session.playtests) {
        refs.addAll(p.chat.pictureRefs);
      }
    }
    return refs;
  }

  Future<void> delete(String id) async {
    final file = _fileFor(id);
    if (file.existsSync()) await file.delete();
  }
}
