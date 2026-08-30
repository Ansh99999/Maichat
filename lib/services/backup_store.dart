/// Where backups the app keeps for itself live: files in an app-private
/// `backups` directory, one zip per snapshot.
///
/// This is the destination an *automatic* backup can actually use. The system
/// save dialog needs somebody in front of the screen to point at a folder, so a
/// scheduled backup has nowhere to write unless the app has a folder of its own;
/// "Save a copy" then hands one of these to the save dialog whenever the user
/// wants it off the device.
///
/// Same shape as [AvatarStore] on purpose: a directory resolved once, a
/// best-effort `open` that returns null rather than throwing, and a sweep that
/// keeps the directory from growing without bound.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// One kept backup file: its name, where it is, how big and when it was written.
typedef BackupFileStat = ({
  String name,
  String path,
  int bytes,
  DateTime modified,
});

class BackupStore {
  BackupStore(this.directory);

  final Directory directory;

  /// Opens (creating if needed) the backups directory. Returns null when the
  /// platform will not say where to put it, in which case the in-app
  /// destination is simply unavailable and exporting to a file still works.
  static Future<BackupStore?> open() async {
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/backups');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return BackupStore(dir);
    } catch (error) {
      debugPrint('MaiChat: no backups directory available ($error)');
      return null;
    }
  }

  /// Writes [bytes] as [name] and returns the file.
  ///
  /// A name already taken is stepped aside rather than clobbered: two backups
  /// taken in the same second are still two backups, and a record must never end
  /// up pointing at a file another record also claims.
  Future<File> write(String name, Uint8List bytes) async {
    final file = File('${directory.path}/${_unique(_safe(name))}');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  String _unique(String name) {
    if (!File('${directory.path}/$name').existsSync()) return name;
    final dot = name.lastIndexOf('.');
    final stem = dot <= 0 ? name : name.substring(0, dot);
    final extension = dot <= 0 ? '' : name.substring(dot);
    for (var n = 2; n < 1000; n++) {
      final candidate = '$stem-$n$extension';
      if (!File('${directory.path}/$candidate').existsSync()) return candidate;
    }
    return name;
  }

  /// Moves [file] into the folder under [name] and returns where it landed.
  ///
  /// A rename where the platform allows one, a copy where it does not: an export
  /// is built in a temporary file and this is how it becomes a kept backup
  /// without the bytes ever passing through memory.
  Future<File> adopt(File file, String name) async {
    final target = '${directory.path}/${_unique(_safe(name))}';
    try {
      return await file.rename(target);
    } catch (_) {
      // A different filesystem (or a platform that will not rename): copy.
      final copy = await file.copy(target);
      try {
        await file.delete();
      } catch (_) {
        // The temporary file is swept up by the caller either way.
      }
      return copy;
    }
  }

  /// Reads a backup by the path recorded against it, or null when it is gone —
  /// the user may have cleared the app's storage since.
  Future<Uint8List?> readPath(String path) async {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      return await file.readAsBytes();
    } catch (error) {
      debugPrint('MaiChat: could not read a backup file ($error)');
      return null;
    }
  }

  /// Every kept backup, newest first.
  List<BackupFileStat> list() {
    final files = <BackupFileStat>[];
    try {
      for (final entity in directory.listSync()) {
        if (entity is! File) continue;
        final stat = entity.statSync();
        files.add((
          name: entity.uri.pathSegments.last,
          path: entity.path,
          bytes: stat.size,
          modified: stat.modified,
        ));
      }
    } catch (error) {
      debugPrint('MaiChat: could not list backups ($error)');
    }
    files.sort((a, b) => b.modified.compareTo(a.modified));
    return files;
  }

  Future<void> deletePath(String path) async {
    try {
      final file = File(path);
      if (file.existsSync()) await file.delete();
    } catch (error) {
      debugPrint('MaiChat: could not delete a backup file ($error)');
    }
  }

  /// Deletes all but the [keep] newest files, and returns the paths it removed
  /// so the records pointing at them can go too. A backup folder that grows for
  /// ever is a storage bug, not a safety feature.
  Future<List<String>> pruneToNewest(int keep) async {
    final removed = <String>[];
    if (keep < 1) return removed;
    final files = list();
    for (final file in files.skip(keep)) {
      await deletePath(file.path);
      removed.add(file.path);
    }
    return removed;
  }

  /// Total bytes the kept backups occupy.
  int sizeBytes() => list().fold(0, (sum, file) => sum + file.bytes);

  /// Never let a name climb out of the directory.
  static String _safe(String name) {
    final cleaned = name.replaceAll(RegExp(r'[/\\]'), '_').trim();
    return cleaned.isEmpty ? 'backup.zip' : cleaned;
  }
}

/// The file name a new backup gets: sortable, unambiguous, and obviously ours.
String backupFileName(DateTime at, {bool automatic = false}) {
  String two(int value) => value.toString().padLeft(2, '0');
  final stamp = '${at.year}-${two(at.month)}-${two(at.day)}'
      '-${two(at.hour)}${two(at.minute)}${two(at.second)}';
  return 'maichat-backup-$stamp${automatic ? '-auto' : ''}.zip';
}

/// A backup within reach on this device: a file the app is holding, or a
/// temporary copy pulled down from Drive that goes away once it has been read.
///
/// It exists so that restoring never means "hold the whole archive in memory":
/// whatever the source, the restore reads a path.
class LocalBackup {
  LocalBackup(this.path, {this.temporary = false, this.folder});

  final String path;

  /// Whether [dispose] should delete it again.
  final bool temporary;

  /// The scratch directory to remove with it, when there is one.
  final Directory? folder;

  Future<void> dispose() async {
    if (!temporary) return;
    try {
      final directory = folder;
      if (directory != null && directory.existsSync()) {
        await directory.delete(recursive: true);
        return;
      }
      final file = File(path);
      if (file.existsSync()) await file.delete();
    } catch (error) {
      debugPrint('MaiChat: a temporary backup copy was left behind ($error)');
    }
  }
}
