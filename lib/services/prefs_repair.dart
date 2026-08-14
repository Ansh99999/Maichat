import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'avatar_store.dart';

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
    required this.recovered,
    required this.removed,
    required this.bytesBefore,
    required this.bytesAfter,
    required this.backupPath,
  });

  /// Pictures moved out to their own file and still attached to their character.
  final int recovered;

  /// Blobs too large to leave in place that could not be attributed to a
  /// character, and so were dropped.
  final int removed;

  final int bytesBefore;
  final int bytesAfter;

  /// The untouched original, kept rather than deleted.
  final String backupPath;
}

/// Runs longer than this are treated as an embedded image rather than anything
/// anyone typed: no ordinary value in this store is a megabyte of unbroken
/// base64. This is a detection threshold, not a size limit — an oversized
/// picture is moved into a file at whatever size it is, never shrunk.
const int kMaxEmbeddedRunBytes = 1024 * 1024;

/// How much context before a run is kept, to tell a character's picture from
/// some other giant blob.
const int _lookbehind = 40;

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

/// Streams the store through, moving every embedded picture longer than
/// [maxRunBytes] out into its own file in [pictures] and leaving a `local:`
/// reference in its place, then swaps the result in. The original is kept beside
/// it as `<name>.oversized-<timestamp>`, so nothing is destroyed.
///
/// The picture stays attached to its character: the reference is substituted at
/// exactly the position the base64 occupied, so the surrounding JSON is
/// otherwise untouched. A giant blob that is *not* a character's picture cannot
/// be attributed to anything, and is dropped so the store can be read again.
///
/// Nothing is ever held whole in memory — the base64 is decoded to the file as
/// it streams — and nothing is resized: a picture is moved at whatever size it
/// is.
///
/// The platform caches the store the first time it is read, so the app has to be
/// restarted before the repaired file takes effect.
Future<PrefsRepair?> repairPreferences({
  File? file,
  Directory? pictures,
  int maxRunBytes = kMaxEmbeddedRunBytes,
}) async {
  final store = file ?? await preferencesFile();
  if (store == null || !store.existsSync()) return null;
  final dir = pictures ?? avatarDirectory ?? (await AvatarStore.open())?.directory;

  final before = store.lengthSync();
  final temp = File('${store.path}.repairing');
  if (temp.existsSync()) temp.deleteSync();
  final out = temp.openWrite();
  var recovered = 0;
  var removed = 0;

  // The run being read. While it is short enough to keep it is buffered, so it
  // can be written back verbatim; once it crosses the threshold the buffer is
  // handed to an extractor (which decodes it into a file as it streams) or
  // discarded. Either way a huge run never sits in memory whole.
  var run = BytesBuilder(copy: false);
  var runLength = 0;
  var dropping = false;
  _RunExtractor? extractor;

  // The bytes just before the current run, so a character's picture can be told
  // apart from any other large blob.
  var tail = <int>[];
  void remember(List<int> bytes) {
    tail = <int>[...tail, ...bytes];
    if (tail.length > _lookbehind) {
      tail = tail.sublist(tail.length - _lookbehind);
    }
  }

  Future<void> endRun() async {
    if (extractor != null) {
      final name = await extractor!.finish();
      out.add(utf8.encode(avatarRef(name)));
      recovered++;
    } else if (dropping) {
      removed++;
    } else if (runLength > 0) {
      final bytes = run.takeBytes();
      out.add(bytes);
      remember(bytes);
    }
    run = BytesBuilder(copy: false);
    runLength = 0;
    dropping = false;
    extractor = null;
  }

  try {
    await for (final chunk in store.openRead()) {
      var start = 0;
      for (var i = 0; i < chunk.length; i++) {
        if (_isBase64Byte(chunk[i])) {
          if (runLength == 0) {
            if (i > start) {
              final plain = chunk.sublist(start, i);
              out.add(plain);
              remember(plain);
            }
            start = i;
          }
          runLength++;
          if (extractor == null && !dropping && runLength > maxRunBytes) {
            // Past the threshold: this is a picture. Move it out if we can see
            // whose it is and have somewhere to put it.
            final buffered = run.takeBytes();
            if (dir != null && _tailNamesAnAvatar(tail)) {
              extractor = _RunExtractor(dir, recovered);
              await extractor!.add(buffered);
            } else {
              dropping = true;
            }
          }
        } else {
          if (runLength > 0) {
            final rest = chunk.sublist(start, i);
            if (extractor != null) {
              await extractor!.add(rest);
            } else if (!dropping) {
              run.add(rest);
            }
            await endRun();
            start = i;
          }
        }
      }
      if (runLength > 0) {
        final rest = chunk.sublist(start);
        if (extractor != null) {
          await extractor!.add(rest);
        } else if (!dropping) {
          run.add(rest);
        }
      } else if (start < chunk.length) {
        final plain = chunk.sublist(start);
        out.add(plain);
        remember(plain);
      }
    }
    await endRun();
    await out.flush();
    await out.close();
  } catch (error) {
    await extractor?.abandon();
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
    recovered: recovered,
    removed: removed,
    bytesBefore: before,
    bytesAfter: File(store.path).lengthSync(),
    backupPath: backup,
  );
}

/// Whether the bytes just before a run look like a character's `avatar` field.
/// Covers both stores: `&quot;avatar&quot;:&quot;` in Android's XML and
/// `\"avatar\":\"` in the desktop JSON.
bool _tailNamesAnAvatar(List<int> tail) =>
    String.fromCharCodes(tail).toLowerCase().contains('avatar');

/// Decodes one base64 run straight into a file, 4 characters at a time, so a
/// picture of any size costs a few kilobytes of memory.
class _RunExtractor {
  _RunExtractor(this.directory, int index)
      : _part = File('${directory.path}/recovered-'
            '${DateTime.now().microsecondsSinceEpoch}-$index.part') {
    _sink = _part.openWrite();
  }

  final Directory directory;
  final File _part;
  late final IOSink _sink;

  /// Base64 characters not yet part of a complete 4-character group.
  var _carry = '';

  /// The first decoded bytes, kept only to sniff the format for the extension.
  final _head = <int>[];

  Future<void> add(List<int> base64Chunk) async {
    _carry += String.fromCharCodes(base64Chunk);
    final aligned = _carry.length - (_carry.length % 4);
    if (aligned <= 0) return;
    final bytes = base64Decode(_carry.substring(0, aligned));
    _carry = _carry.substring(aligned);
    if (_head.length < 12) _head.addAll(bytes.take(12 - _head.length));
    _sink.add(bytes);
  }

  /// Flushes what is left, names the file by its format, and returns that name.
  Future<String> finish() async {
    if (_carry.isNotEmpty) {
      // A trailing group, padding included.
      final padded = _carry.padRight((_carry.length + 3) ~/ 4 * 4, '=');
      _sink.add(base64Decode(padded));
    }
    await _sink.flush();
    await _sink.close();
    final name = _part.uri.pathSegments.last
        .replaceAll('.part', avatarExtensionFor(_head));
    _part.renameSync('${directory.path}/$name');
    return name;
  }

  Future<void> abandon() async {
    try {
      await _sink.close();
      if (_part.existsSync()) _part.deleteSync();
    } catch (_) {
      // Nothing to do: this is already the error path.
    }
  }
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

