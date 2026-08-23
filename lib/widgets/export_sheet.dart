import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'brand_mark.dart';

/// The two permission-free ways to get an export off the device: write it with
/// the system's own save dialog, or put it on the clipboard.
///
/// Shared so a download behaves the same wherever it is started from — and so
/// the "save dialog returned nothing" case is handled once. On Android the
/// picker can return null both when the user cancels and when the platform
/// declines to give a path, which is why the message says only that nothing was
/// written.
Future<void> offerExport(
  BuildContext context, {
  required String text,
  required String fileName,
  required String subtitle,
  String dialogTitle = 'Save file',
  List<String> extensions = const ['json'],
}) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.save_alt_outlined),
            title: Text('Save as .${extensions.first} file'),
            // The subtitle is the chosen format's name, so it carries the mark
            // when that format is ours.
            subtitle: BrandedText(subtitle),
            onTap: () => Navigator.of(context).pop('file'),
          ),
          ListTile(
            leading: const Icon(Icons.copy_all_outlined),
            title: const Text('Copy to clipboard'),
            onTap: () => Navigator.of(context).pop('clipboard'),
          ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;

  if (choice == 'clipboard') {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Copied to clipboard.')),
      );
    }
    return;
  }

  String? path;
  try {
    path = await FilePicker.saveFile(
      dialogTitle: dialogTitle,
      fileName: fileName,
      bytes: Uint8List.fromList(utf8.encode(text)),
      type: FileType.custom,
      allowedExtensions: extensions,
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

/// A file name with everything a file system might object to removed.
String safeFileName(String s) => s
    .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
    .trim()
    .replaceAll(RegExp(r'\s+'), '_');
