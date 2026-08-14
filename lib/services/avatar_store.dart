import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Where character pictures live: files on disk, one per picture.
///
/// They used to be kept as base64 *inside* the preferences store, which is the
/// wrong place for an image by any measure. That store is read in full at every
/// launch and rewritten in full on every save, so a picture cost startup time
/// and write time on every single reply — and past roughly forty megabytes in
/// one entry, Android's own preference parser runs out of memory reading it and
/// the app can no longer open at all.
///
/// A file has none of those properties. Nothing reads it until something draws
/// it, the preferences store goes back to holding a few kilobytes of text, and a
/// picture can be exactly as large as it was imported — there is no size limit
/// here, and there should not be one.
///
/// A character's `avatar` field therefore holds one of three things: an
/// `http(s)` URL, a `local:<file>` reference into this directory, or — for a
/// store written before this existed — base64, which [AvatarStore.adopt] moves
/// into a file the first time it is seen.

/// Marks an avatar value as a file in the avatar directory.
const String kAvatarRefPrefix = 'local:';

/// Whether [avatar] names a file in the avatar directory.
bool avatarIsLocal(String avatar) =>
    avatar.trim().startsWith(kAvatarRefPrefix);

/// The reference to persist for [fileName].
String avatarRef(String fileName) => '$kAvatarRefPrefix$fileName';

/// The file name inside a `local:` reference, or null when it is not one.
String? avatarRefName(String avatar) {
  final trimmed = avatar.trim();
  if (!trimmed.startsWith(kAvatarRefPrefix)) return null;
  final name = trimmed.substring(kAvatarRefPrefix.length).trim();
  // Defend the directory against a reference that tries to climb out of it.
  if (name.isEmpty || name.contains('/') || name.contains('\\')) return null;
  return name;
}

/// The pictures directory, once [AvatarStore.open] has resolved it.
///
/// Resolving it needs a platform call, but drawing an avatar happens inside
/// `build`, so the resolved directory is kept here for synchronous use. It is
/// set during startup, before anything can be drawn.
Directory? avatarDirectory;

/// The file a `local:` avatar refers to, or null when the reference is not local
/// (or the directory is not resolved yet).
File? avatarRefFile(String avatar) {
  final dir = avatarDirectory;
  final name = avatarRefName(avatar);
  if (dir == null || name == null) return null;
  return File('${dir.path}/$name');
}

/// Reads and writes the pictures directory.
class AvatarStore {
  /// Publishes [directory] for [avatarRefFile] as a side effect: a store
  /// existing and the drawing code knowing where to look are the same fact.
  AvatarStore(this.directory) {
    avatarDirectory = directory;
  }

  final Directory directory;

  /// Opens (creating if needed) the app's pictures directory and publishes it
  /// for [avatarRefFile]. Returns null when the platform will not say where to
  /// put it, in which case the app carries on with base64 as before.
  static Future<AvatarStore?> open() async {
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/avatars');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      avatarDirectory = dir;
      return AvatarStore(dir);
    } catch (error) {
      debugPrint('MaiChat: no avatar directory available ($error)');
      return null;
    }
  }

  /// Writes [bytes] and returns the `local:` reference to persist.
  Future<String> write(Uint8List bytes, {String? basename}) async {
    final name = '${basename ?? _uniqueName()}${_extensionFor(bytes)}';
    final file = File('${directory.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    return avatarRef(name);
  }

  /// Moves a base64 avatar into a file, returning the reference to persist —
  /// or the value unchanged when it is empty, a URL, already local, or not
  /// decodable.
  Future<String> adopt(String avatar) async {
    final trimmed = avatar.trim();
    if (trimmed.isEmpty || avatarIsLocal(trimmed)) return avatar;
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return avatar;
    }
    try {
      final bytes = base64Decode(trimmed);
      if (bytes.isEmpty) return avatar;
      return await write(bytes);
    } catch (error) {
      debugPrint('MaiChat: could not adopt an avatar ($error)');
      return avatar;
    }
  }

  /// Deletes files in the directory that [keep] does not refer to. Called after
  /// a character is deleted, and once at startup to clear anything left behind
  /// by an interrupted write.
  Future<int> sweep(Iterable<String> keep) async {
    final referenced = keep.map(avatarRefName).whereType<String>().toSet();
    var removed = 0;
    try {
      for (final entity in directory.listSync()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (referenced.contains(name)) continue;
        entity.deleteSync();
        removed++;
      }
    } catch (error) {
      debugPrint('MaiChat: avatar sweep failed ($error)');
    }
    return removed;
  }

  static int _counter = 0;

  static String _uniqueName() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_counter++}';

  static String _extensionFor(Uint8List bytes) => avatarExtensionFor(bytes);
}

/// Sniffs the format so a picture file has an honest extension. Flutter detects
/// the format from the bytes either way, so this is for the human looking at the
/// directory. Only the first dozen bytes are read.
String avatarExtensionFor(List<int> bytes) {
  bool starts(List<int> magic, {int at = 0}) {
    if (bytes.length < at + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[at + i] != magic[i]) return false;
    }
    return true;
  }

  if (starts(const [0x89, 0x50, 0x4E, 0x47])) return '.png';
  if (starts(const [0xFF, 0xD8, 0xFF])) return '.jpg';
  if (starts(const [0x47, 0x49, 0x46])) return '.gif';
  if (starts(const [0x52, 0x49, 0x46, 0x46]) &&
      starts(const [0x57, 0x45, 0x42, 0x50], at: 8)) {
    return '.webp';
  }
  return '.img';
}
