import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Repairing a preferences store the platform can no longer even read.
///
/// Character pictures are persisted as base64 *inside* the preferences store.
/// Let a few of those be camera-roll sized and the store grows past what
/// Android's own XML parser can load: `SharedPreferencesImpl.loadFromDisk`
/// builds each value in a `StringBuilder` and dies with an `OutOfMemoryError`
/// trying to allocate the char array. That happens before a single line of Dart
/// runs, so nothing inside the app can read, shrink or delete the offending
/// entry — the app simply cannot open, for good.
///
/// The only way back is to work on the file itself, without ever holding a
/// whole value in memory. That is all this does: stream the store through,
/// dropping runs of base64 that are far too large to be anything but an
/// embedded picture, and keep the original file as a backup.
///
/// Everything else — chats, character definitions, presets, settings — is
/// copied through byte for byte.

/// What a scan of the store found.
@immutable
class PrefsScan {
  const PrefsScan({
    required this.path,
    required this.totalBytes,
    required this.oversized,
  });

  /// The store file, or null when there is none (a fresh install).
  final String? path;
  final int totalBytes;

  /// Byte length of each embedded picture larger than the threshold, largest
  /// first.
  final List<int> oversized;

  bool get hasOversized => oversized.isNotEmpty;
  int get oversizedBytes => oversized.fold(0, (sum, b) => sum + b);
}

/// What a repair did.
@immutable
class PrefsRepair {
  const PrefsRepair({
    required this.removed,
    required this.bytesBefore,
    required this.bytesAfter,
    required this.backupPath,
  });

  final int removed;
  final int bytesBefore;
  final int bytesAfter;

  /// The untouched original, kept rather than deleted.
  final String backupPath;
}

/// Runs longer than this are an embedded image, not data anyone typed: no
/// ordinary value in this store is a megabyte of unbroken base64. Avatars below
/// it are left alone, so a repair costs only the outsized pictures.
const int kMaxEmbeddedRunBytes = 1024 * 1024;

/// The platform's preferences file, or null when it cannot be located (or does
/// not exist yet).
///
/// Android keeps it as `shared_prefs/FlutterSharedPreferences.xml` beside the
/// app's files directory; the desktop plugins keep a JSON file in the
/// application support directory. Both are plain text with the base64 embedded
/// verbatim, which is all the repair needs.
Future<File?> preferencesFile() async {
  try {
    final support = await getApplicationSupportDirectory();
    final candidates = <String>[
      // Android: /data/user/0/<pkg>/files -> /data/user/0/<pkg>/shared_prefs/…
      '${support.parent.path}/shared_prefs/FlutterSharedPreferences.xml',
      '${support.path}/shared_prefs/FlutterSharedPreferences.xml',
      // Linux/Windows/macOS: a JSON file in the support directory itself.
      '${support.path}/shared_preferences.json',
    ];
    for (final path in candidates) {
      final file = File(path);
      if (file.existsSync()) return file;
    }
  } catch (error) {
    debugPrint('MaiChat: could not locate the preferences file ($error)');
  }
  return null;
}

/// Measures the store without loading it: how big it is, and how much of that
/// is oversized embedded pictures.
Future<PrefsScan> scanPreferences({File? file}) async {
  final store = file ?? await preferencesFile();
  if (store == null || !store.existsSync()) {
    return const PrefsScan(path: null, totalBytes: 0, oversized: <int>[]);
  }
  final oversized = <int>[];
  var run = 0;
  await for (final chunk in store.openRead()) {
    for (final byte in chunk) {
      if (_isBase64Byte(byte)) {
        run++;
      } else {
        if (run > kMaxEmbeddedRunBytes) oversized.add(run);
        run = 0;
      }
    }
  }
  if (run > kMaxEmbeddedRunBytes) oversized.add(run);
  oversized.sort((a, b) => b.compareTo(a));
  return PrefsScan(
    path: store.path,
    totalBytes: store.lengthSync(),
    oversized: oversized,
  );
}

/// Streams the store through, dropping every base64 run longer than
/// [maxRunBytes], and swaps the result into place. The original is kept beside
/// it as `<name>.oversized-<timestamp>`, so nothing is destroyed.
///
/// The platform caches the store the first time it is read, so the app has to be
/// restarted before the repaired file takes effect.
Future<PrefsRepair?> repairPreferences({
  File? file,
  int maxRunBytes = kMaxEmbeddedRunBytes,
}) async {
  final store = file ?? await preferencesFile();
  if (store == null || !store.existsSync()) return null;

  final before = store.lengthSync();
  final temp = File('${store.path}.repairing');
  if (temp.existsSync()) temp.deleteSync();
  final out = temp.openWrite();
  var removed = 0;

  // Bytes of the run currently being read. A run is only written out once we
  // know it is short enough to keep, so a huge one never lands in memory whole:
  // past the threshold it is counted and discarded as it streams.
  var run = BytesBuilder(copy: false);
  var runLength = 0;
  var dropping = false;

  void endRun() {
    if (dropping) {
      removed++;
    } else if (runLength > 0) {
      out.add(run.takeBytes());
    }
    run = BytesBuilder(copy: false);
    runLength = 0;
    dropping = false;
  }

  try {
    await for (final chunk in store.openRead()) {
      var start = 0;
      for (var i = 0; i < chunk.length; i++) {
        if (_isBase64Byte(chunk[i])) {
          if (runLength == 0) {
            // Flush the plain bytes seen since the last run.
            if (i > start) out.add(chunk.sublist(start, i));
            start = i;
          }
          runLength++;
          if (!dropping && runLength > maxRunBytes) {
            // Only now does it count as a picture: throw away what was buffered.
            dropping = true;
            run.clear();
          }
        } else {
          if (runLength > 0) {
            if (!dropping) run.add(chunk.sublist(start, i));
            endRun();
            start = i;
          }
        }
      }
      if (runLength > 0) {
        if (!dropping) run.add(chunk.sublist(start));
      } else if (start < chunk.length) {
        out.add(chunk.sublist(start));
      }
    }
    endRun();
    await out.flush();
    await out.close();
  } catch (error) {
    await out.close();
    if (temp.existsSync()) temp.deleteSync();
    debugPrint('MaiChat: storage repair failed ($error)');
    rethrow;
  }

  final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
  final backup = '${store.path}.oversized-$stamp';
  store.renameSync(backup);
  temp.renameSync(store.path);
  return PrefsRepair(
    removed: removed,
    bytesBefore: before,
    bytesAfter: File(store.path).lengthSync(),
    backupPath: backup,
  );
}

/// The base64 alphabet (plus its padding). Deliberately excludes whitespace and
/// quotes, so any run this long is one embedded blob rather than prose.
bool _isBase64Byte(int byte) =>
    (byte >= 0x41 && byte <= 0x5A) || // A-Z
    (byte >= 0x61 && byte <= 0x7A) || // a-z
    (byte >= 0x30 && byte <= 0x39) || // 0-9
    byte == 0x2B || // +
    byte == 0x2F || // /
    byte == 0x3D; // =

