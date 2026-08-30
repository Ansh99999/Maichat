import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/backup.dart';
import '../../services/backup_store.dart';
import '../../services/storage_report.dart';
import '../../state/app_state.dart';
import '../chats_screen.dart' show relativeTime;
import 'backup_export_sheet.dart';
import 'backup_import_screen.dart';
import 'backup_restore.dart';
import 'backup_stats_card.dart';

/// Settings ▸ Backups: everything the app has exported, what it adds up to, and
/// the two ways in and out.
///
/// The list is the point of the screen. A backup nobody can find is not a
/// backup, so every export leaves a record here — including the ones the
/// schedule took while nobody was looking.
class BackupsScreen extends StatefulWidget {
  const BackupsScreen({super.key});

  @override
  State<BackupsScreen> createState() => _BackupsScreenState();
}

class _BackupsScreenState extends State<BackupsScreen> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _restore(AppState state, BackupRecord record) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!record.restorable) {
      messenger.showSnackBar(const SnackBar(
        content: Text('This one is a file you saved yourself — import it from '
            'the Import screen.'),
      ));
      return;
    }
    messenger.showSnackBar(const SnackBar(
      content: Text('Reading the backup…'),
      duration: Duration(seconds: 2),
    ));
    final LocalBackup? local;
    try {
      local = await state.fetchBackup(record);
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('That backup could not be read ($error).')),
      );
      return;
    }
    if (local == null) {
      messenger.showSnackBar(const SnackBar(
        content: Text('That backup is no longer where it was.'),
      ));
      return;
    }
    try {
      if (!mounted) return;
      await restoreMaiChatBackupFile(context, local.path, name: record.name);
    } finally {
      await local.dispose();
    }
  }

  Future<void> _saveCopy(AppState state, BackupRecord record) async {
    final messenger = ScaffoldMessenger.of(context);
    final bytes = await state.readBackup(record);
    if (bytes == null) {
      messenger.showSnackBar(const SnackBar(
        content: Text('There is no copy of that one in the app to save.'),
      ));
      return;
    }
    String? path;
    try {
      path = await FilePicker.saveFile(
        dialogTitle: 'Save backup',
        fileName: record.name,
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: const ['zip'],
      );
    } catch (_) {
      path = null;
    }
    messenger.showSnackBar(SnackBar(
      content: Text(path == null ? 'Nothing was written.' : 'Saved to $path'),
    ));
  }

  Future<void> _delete(AppState state, BackupRecord record) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this backup?'),
        content: Text(record.destination == BackupDestination.file
            ? 'The record goes; the file you saved stays where you put it.'
            : 'The copy ${record.destination == BackupDestination.drive
                ? 'in Drive' : 'in the app'} is deleted too.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await state.deleteBackup(record.id);
  }
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final all = state.backups;
    final shown = all.where((record) => record.matches(_query)).toList();
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // The large top app bar: the way back top left, the title big
          // underneath it until the list is scrolled.
          const SliverAppBar.large(title: Text('Backups')),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SearchBar(
                controller: _search,
                hintText: 'Search backups',
                leading: const Icon(Icons.search),
                trailing: [
                  if (_query.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Clear',
                      onPressed: () {
                        _search.clear();
                        setState(() => _query = '');
                      },
                    ),
                ],
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => showBackupExportSheet(context),
                      icon: const Icon(Icons.upload_outlined),
                      label: const Text('Export'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const BackupImportScreen(),
                        ),
                      ),
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('Import'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: BackupStatsCard(
              stats: state.backupStats,
              keptBytes: state.keptBackupBytes,
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: Text(
                all.isEmpty
                    ? 'SNAPSHOTS'
                    : 'SNAPSHOTS · ${shown.length} of ${all.length}',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ),
          if (shown.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
                child: Text(
                  all.isEmpty
                      ? 'No backups yet. Export one and it is listed here, with '
                          'everything it holds.'
                      : 'No backup matches "$_query".',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            )
          else
            SliverList.builder(
              itemCount: shown.length,
              itemBuilder: (context, index) => _BackupRow(
                record: shown[index],
                onRestore: () => _restore(state, shown[index]),
                onSaveCopy: () => _saveCopy(state, shown[index]),
                onDelete: () => _delete(state, shown[index]),
              ),
            ),
          SliverToBoxAdapter(child: SizedBox(height: 24 + bottom)),
        ],
      ),
    );
  }
}
/// One snapshot in the list: what it is called, when it was taken and what is in
/// it, with the three things that can be done to it behind the overflow.
class _BackupRow extends StatelessWidget {
  const _BackupRow({
    required this.record,
    required this.onRestore,
    required this.onSaveCopy,
    required this.onDelete,
  });

  final BackupRecord record;
  final VoidCallback onRestore;
  final VoidCallback onSaveCopy;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final icon = switch (record.destination) {
      BackupDestination.file => Icons.folder_zip_outlined,
      BackupDestination.device => Icons.inventory_2_outlined,
      BackupDestination.drive => Icons.cloud_outlined,
    };
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: scheme.onSecondaryContainer, size: 22),
      ),
      title: Text(record.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${relativeTime(record.createdAt)} · '
            '${formatBytes(record.bytes)} · ${record.destination.label}'
            '${record.automatic ? ' · on a schedule' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            record.counts.summary(limit: 4),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
      isThreeLine: true,
      onTap: record.restorable ? onRestore : null,
      trailing: PopupMenuButton<String>(
        tooltip: 'More',
        onSelected: (value) => switch (value) {
          'restore' => onRestore(),
          'copy' => onSaveCopy(),
          _ => onDelete(),
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: 'restore',
            enabled: record.restorable,
            child: const Text('Restore'),
          ),
          PopupMenuItem(
            value: 'copy',
            enabled: record.restorable,
            child: const Text('Save a copy'),
          ),
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }
}
