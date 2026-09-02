/// Export and import of one chat-interface look, as a single self-contained file.
///
/// A look is worth carrying between installs, and worth handing to somebody else,
/// so the file has to include the pictures it refers to — a background or a
/// participant-bar picture live in the pictures directory, and a reference to a
/// file the other device has never seen means nothing. They ride along base64'd,
/// the way a character card carries its avatar.
///
/// That is not a breach of "pictures are files, never base64 in SharedPreferences":
/// the rule is about the store, whose parser once OOM'd on accumulated blobs. This
/// is an export, held for as long as it takes to write it, and a look holds one or
/// two pictures rather than a gallery.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../models/chat_interface.dart';
import '../models/interface_preset.dart';
import 'avatar_store.dart';

/// What the `format` key says, so a file that is not one of these can be turned
/// away with a sentence rather than a stack trace.
const String kInterfacePresetFormat = 'maichat.interface-preset';
const int kInterfacePresetFormatVersion = 1;

/// Thrown when a file is not a look this version can read. The message is written
/// to be shown to the user as-is.
class InterfacePresetFormatException implements Exception {
  const InterfacePresetFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reads the bytes behind a `local:` picture reference, or null when it cannot be
/// found. Injected so the codec never touches the filesystem itself.
typedef PictureReader = Uint8List? Function(String ref);

/// Files picture bytes and returns the reference they were stored under, or null
/// when storing failed. Injected for the same reason — and because on the way in
/// the pictures must be written *before* the look that names them.
typedef PictureWriter = Future<String?> Function(Uint8List bytes);
/// [preset] as a file: its look, plus every picture the look refers to.
///
/// A reference whose file has gone missing is dropped from the look rather than
/// exported as a dangling name — a look that quietly points at nothing on the
/// other device is worse than one that visibly has no background.
Map<String, dynamic> exportInterfacePreset(
  InterfacePreset preset, {
  required PictureReader read,
}) {
  final pictures = <String, String>{};
  var ui = preset.ui;
  for (final ref in preset.ui.pictureRefs) {
    if (avatarRefName(ref) == null) continue; // a URL needs no carrying
    final bytes = read(ref);
    if (bytes != null && bytes.isNotEmpty) {
      pictures[ref] = base64Encode(bytes);
      continue;
    }
    if (ui.groupBarImage == ref) ui = ui.copyWith(groupBarImage: null);
    if (ui.backgroundImage == ref) ui = ui.copyWith(backgroundImage: null);
  }
  return {
    'format': kInterfacePresetFormat,
    'formatVersion': kInterfacePresetFormatVersion,
    'name': preset.name,
    'ui': ui.lookOnly.toJson(),
    if (pictures.isNotEmpty) 'pictures': pictures,
  };
}

/// Whether [json] looks like one of our look files — used to tell one apart from
/// some other JSON the user picked by mistake, before trying to read it.
bool looksLikeInterfacePreset(Object? json) =>
    json is Map && json['format'] == kInterfacePresetFormat;
/// Reads a look out of [json], filing its pictures through [store] first and
/// rewriting the look's references to whatever names they were filed under.
///
/// The id in the file is ignored — a look arrives as a new saved look, never as
/// something that can claim a built-in's identity or overwrite one already here.
Future<InterfacePreset> importInterfacePreset(
  Object? json, {
  required PictureWriter store,
}) async {
  if (json is! Map) {
    throw const InterfacePresetFormatException(
        'That file does not contain a chat-interface look.');
  }
  if (json['format'] != kInterfacePresetFormat) {
    throw const InterfacePresetFormatException(
        'That file is not a MaiChat chat-interface look.');
  }
  final version = (json['formatVersion'] as num?)?.toInt() ?? 1;
  if (version > kInterfacePresetFormatVersion) {
    throw InterfacePresetFormatException(
        'That look was saved by a newer version of MaiChat (format $version). '
        'Update the app and try again.');
  }
  final raw = json['ui'];
  if (raw is! Map<String, dynamic>) {
    throw const InterfacePresetFormatException(
        'That look has no settings in it.');
  }

  // Pictures first: the look can only name them once they are on disk.
  final rewritten = <String, String>{};
  final pictures = json['pictures'];
  if (pictures is Map) {
    for (final entry in pictures.entries) {
      final encoded = entry.value;
      if (encoded is! String || encoded.isEmpty) continue;
      final Uint8List bytes;
      try {
        bytes = base64Decode(encoded);
      } catch (_) {
        continue; // a picture that will not decode is simply not carried
      }
      final ref = await store(bytes);
      if (ref != null) rewritten[entry.key.toString()] = ref;
    }
  }
  var ui = ChatInterface.fromJson(raw);
  // A reference the file did not carry is cleared rather than left pointing at a
  // name that means something else on this device.
  ui = ui.copyWith(
    groupBarImage: _resolve(ui.groupBarImage, rewritten),
    backgroundImage: _resolve(ui.backgroundImage, rewritten),
  );

  final name = (json['name'] as String?)?.trim();
  return InterfacePreset(
    id: 'look-${DateTime.now().microsecondsSinceEpoch}',
    name: name == null || name.isEmpty ? 'Imported look' : name,
    ui: ui.lookOnly,
    createdAt: DateTime.now(),
  );
}

/// A picture reference as it should read on this device: the name it was filed
/// under, an untouched URL, or nothing.
String? _resolve(String? ref, Map<String, String> rewritten) {
  if (ref == null || ref.isEmpty) return null;
  final filed = rewritten[ref];
  if (filed != null) return filed;
  // A local reference nobody carried cannot be honoured; a URL always can.
  return avatarRefName(ref) == null ? ref : null;
}



