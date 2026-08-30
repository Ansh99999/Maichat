import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/backup.dart';
import '../../services/backup_codec.dart';
import '../../services/storage_report.dart';
import '../../state/app_state.dart';

/// Restoring a MaiChat backup: read what is in the archive, say so, ask how it
/// should land, then do it. Shared by the Backups list and the Import screen so
/// the question is asked the same way wherever a restore starts.
///
/// The archive is decoded *before* the question, so the dialog can name what is
/// actually inside rather than what the file is called.
Future<bool> restoreMaiChatBackup(
  BuildContext context,
  Uint8List bytes, {
  String name = '',
}) async {
  final state = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  BackupSnapshot snapshot;
  try {
    snapshot = decodeBackup(bytes);
  } on BackupFormatException catch (error) {
    messenger.showSnackBar(SnackBar(content: Text(error.message)));
    return false;
  } catch (error) {
    messenger.showSnackBar(
      SnackBar(content: Text('That backup could not be read ($error).')),
    );
    return false;
  }

  final replace = await showDialog<bool>(
    context: context,
    builder: (context) => _RestoreDialog(
      name: name.isEmpty ? 'this backup' : name,
      snapshot: snapshot,
    ),
  );
  if (replace == null || !context.mounted) return false;

  messenger.showSnackBar(const SnackBar(
    content: Text('Restoring…'),
    duration: Duration(seconds: 2),
  ));
  try {
    final counts = await state.restoreSnapshot(snapshot, replace: replace);
    messenger.showSnackBar(SnackBar(
      content: Text('${replace ? 'Restored' : 'Merged in'} '
          '${counts.summary(limit: 4)}.'),
    ));
    if (context.mounted) {
      // Everything behind this screen is looking at objects the restore has
      // just replaced, so go back to the top rather than leaving a stale chat
      // on the stack.
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
    return true;
  } on BackupFormatException catch (error) {
    messenger.showSnackBar(SnackBar(content: Text(error.message)));
  } catch (error) {
    messenger.showSnackBar(
      SnackBar(content: Text('The restore did not finish ($error).')),
    );
  }
  return false;
}
/// Asks the one question a restore has: should the app become exactly what is in
/// the file, or should the file be added to what is here?
class _RestoreDialog extends StatelessWidget {
  const _RestoreDialog({required this.name, required this.snapshot});

  final String name;
  final BackupSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final counts = snapshot.counts;
    return AlertDialog(
      title: const Text('Restore this backup?'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(name, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Taken ${_when(snapshot.createdAt)}'
              '${snapshot.appVersion.isEmpty ? '' : ' · MaiChat '
                  '${snapshot.appVersion}'}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            for (final part in counts.parts.where((p) => p.$2 > 0))
              Text('${part.$2} ${part.$1}'),
            if (!snapshot.includesKeys) ...[
              const SizedBox(height: 12),
              Text(
                'No API keys in this one — the keys on this device are left '
                'alone.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              'Restore everything puts the app back exactly as it was: anything '
              'made since this backup was taken is removed. Add to what is here '
              'keeps your current data and merges the backup into it.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Add to what is here'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Restore everything'),
        ),
      ],
    );
  }

  static String _when(DateTime at) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${at.year}-${two(at.month)}-${two(at.day)} '
        '${two(at.hour)}:${two(at.minute)}';
  }
}

/// "12 characters · 3.4 MB" for a row that lists a backup.
String backupSubtitle(BackupRecord record) =>
    '${formatBytes(record.bytes)} · ${record.counts.summary()}';
