import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../../models/message_image.dart';
import '../../../state/app_state.dart';
import '../../gallery/gallery_picker_sheet.dart';

/// A picture from the gallery for the next Studio message, as the ref the
/// gallery already holds — or null when nothing was picked.
Future<MessageImage?> pickStudioGalleryPicture(
  BuildContext context, {
  required String characterId,
}) async {
  final ref = await showGalleryPickerSheet(
    context,
    title: 'Add a picture',
    characterId: characterId,
  );
  if (ref == null) return null;
  return MessageImage(ref: ref, mime: mimeForRef(ref));
}

/// Pictures off the device for the next Studio message. Each is written into
/// the pictures directory first, so the message holds refs and never a blob —
/// pictures are files, everywhere in the app.
Future<List<MessageImage>> pickStudioDevicePictures(BuildContext context) async {
  final state = context.read<AppState>();
  FilePickerResult? result;
  try {
    result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
    );
  } catch (_) {
    result = null;
  }
  if (result == null || result.files.isEmpty) return const <MessageImage>[];
  final chosen = <MessageImage>[];
  for (final file in result.files) {
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) continue;
    final image = await state.storeAttachment(bytes);
    if (image != null) chosen.add(image);
  }
  if (chosen.isEmpty && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Those pictures could not be read.'),
    ));
  }
  return chosen;
}
