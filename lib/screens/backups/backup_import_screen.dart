import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/backup.dart';
import '../../services/backup_codec.dart';
import '../../services/drive_client.dart';
import '../../services/foreign_backup.dart';
import '../../services/storage_report.dart';
import '../../state/app_state.dart';
import '../chats_screen.dart' show relativeTime;
import 'backup_restore.dart';

/// Bringing everything in: a MaiChat backup, or a backup another app wrote.
///
/// The tiles are descriptions, not parsers — routing is by *content*, because a
/// SillyTavern card and a Chub card are the same file and the user should not
/// have to know which tile to press. What each tile really says is "here is what
/// this app's export looks like, and yes, it is understood".
class BackupImportScreen extends StatefulWidget {
  const BackupImportScreen({super.key});

  @override
  State<BackupImportScreen> createState() => _BackupImportScreenState();
}

/// One row under "Import from": what it is, what it accepts, and the words a
/// search for it might use.
class _Source {
  const _Source({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.keywords,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String keywords;

  bool matches(String needle) {
    final n = needle.trim().toLowerCase();
    if (n.isEmpty) return true;
    return title.toLowerCase().contains(n) ||
        subtitle.toLowerCase().contains(n) ||
        keywords.contains(n);
  }
}

const List<_Source> _sources = <_Source>[
  _Source(
    icon: Icons.restore,
    title: 'A MaiChat backup',
    subtitle: 'A .zip or .json from Export. Everything goes back exactly where '
        'it was — chats, messages, providers, presets, lorebooks, scenarios, '
        'embeddings and pictures.',
    keywords: 'maichat native zip json restore everything full snapshot',
  ),
  _Source(
    icon: Icons.auto_stories_outlined,
    title: 'SillyTavern',
    subtitle: 'Its data folder as a .zip (characters, chats, worlds, presets), '
        'or single files: a card .png, a chat .jsonl, a world .json.',
    keywords: 'sillytavern silly tavern st jsonl world info png card preset',
  ),
  _Source(
    icon: Icons.forum_outlined,
    title: 'Agnai / Agnaistic',
    subtitle: 'Its backup — the .zip with backup.json and assets, or the guest '
        'export .json. Characters, chats, memory books, scenarios and presets.',
    keywords: 'agnai agnaistic guest backup memory book scenario gallery',
  ),
  _Source(
    icon: Icons.travel_explore_outlined,
    title: 'Chub / Venus',
    subtitle: 'Character cards and lorebooks, one at a time or a .zip of them.',
    keywords: 'chub venus characterhub card lorebook charx',
  ),
  _Source(
    icon: Icons.folder_open_outlined,
    title: 'Any file or archive',
    subtitle: 'Anything else worth a try: every file inside is read on its own '
        'merits, and whatever is recognised comes in.',
    keywords: 'other unknown risu kobold ooba cai text generation webui zip',
  ),
];
class _BackupImportScreenState extends State<BackupImportScreen> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  bool _busy = false;

  /// The Drive listing, once it has been asked for. Not fetched on open: a
  /// screen that hits the network before the user asks for it is a screen that
  /// fails to open on a train.
  Future<List<DriveFile>>? _drive;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Picks files and reads them. A MaiChat backup takes the restore path (exact,
  /// with a replace-or-merge question); anything else is folded together and
  /// applied once.
  Future<void> _pick(AppState state) async {
    if (_busy) return;
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        dialogTitle: 'Import a backup',
        // FileType.any, not custom: exports arrive named .zip, .json, .jsonl,
        // .png and sometimes nothing at all, and Android's picker greys out
        // whatever a custom filter did not list. The content decides.
        type: FileType.any,
        allowMultiple: true,
        withData: true,
      );
    } catch (_) {
      result = null;
    }
    final files = result?.files ?? const <PlatformFile>[];
    if (files.isEmpty || !mounted) return;

    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    ForeignBackup? foreign;
    String? firstError;
    for (final file in files) {
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) continue;
      if (looksLikeMaiChatBackup(bytes)) {
        setState(() => _busy = false);
        if (!mounted) return;
        await restoreMaiChatBackup(context, bytes, name: file.name);
        return;
      }
      try {
        final read = readForeignBackup(bytes, fileName: file.name);
        if (foreign == null) {
          foreign = read;
        } else {
          foreign.absorb(read);
        }
      } on FormatException catch (error) {
        firstError ??= error.message;
      } catch (error) {
        firstError ??= 'Could not read ${file.name} ($error).';
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (foreign == null) {
      messenger.showSnackBar(SnackBar(
        content: Text(firstError ?? 'Nothing in there could be imported.'),
      ));
      return;
    }
    await _confirmForeign(state, foreign, firstError);
  }
  /// Shows what was recognised before anything is written, then writes it.
  Future<void> _confirmForeign(
    AppState state,
    ForeignBackup backup,
    String? error,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Import from ${backup.source.label}?'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(backup.summary()),
              const SizedBox(height: 12),
              Text(
                'These are added to what you already have; nothing is replaced. '
                'A chat whose character is in the same file arrives attached to '
                'it.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              for (final note in backup.notes) ...[
                const SizedBox(height: 8),
                Text(
                  note,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await state.applyForeignBackup(backup);
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(
        content: Text('Imported ${backup.summary()}'
            '${error == null ? '' : ' · one file was skipped'}'),
      ));
      Navigator.of(context).pop();
    } on BackupFormatException catch (failure) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text(failure.message)));
    } catch (failure) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(content: Text('The import did not finish ($failure).')),
      );
    }
  }

  /// Restores one of the app's own kept backups, or one sitting in Drive.
  Future<void> _restoreRecord(AppState state, BackupRecord record) async {
    final messenger = ScaffoldMessenger.of(context);
    final bytes = await state.readBackup(record);
    if (bytes == null) {
      messenger.showSnackBar(const SnackBar(
        content: Text('That backup is no longer where it was.'),
      ));
      return;
    }
    if (!mounted) return;
    await restoreMaiChatBackup(context, bytes, name: record.name);
  }

  Future<void> _restoreDrive(AppState state, DriveFile file) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    Uint8List bytes;
    try {
      bytes = await state.downloadDriveBackup(file.id);
    } on DriveException catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await restoreMaiChatBackup(context, bytes, name: file.name);
  }
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sources = _sources.where((s) => s.matches(_query)).toList();
    // Only the copies the app is holding itself: a Drive backup is offered under
    // the Drive fold, where it can actually be fetched, and a file the user saved
    // somewhere of their own has to come back through the picker.
    final kept = state.backups
        .where((record) =>
            record.destination == BackupDestination.device &&
            record.restorable &&
            record.matches(_query))
        .toList();
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          const SliverAppBar.large(title: Text('Import')),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SearchBar(
                controller: _search,
                hintText: 'Search imports',
                leading: const Icon(Icons.search),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
          ),
          if (_busy)
            const SliverToBoxAdapter(child: LinearProgressIndicator()),
          _Header(
            'IMPORT FROM',
            trailing: sources.isEmpty ? 'nothing matches' : null,
          ),
          SliverList.builder(
            itemCount: sources.length,
            itemBuilder: (context, index) {
              final source = sources[index];
              return ListTile(
                enabled: !_busy,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(source.icon,
                      color: scheme.onSecondaryContainer, size: 22),
                ),
                title: Text(source.title),
                subtitle: Text(source.subtitle),
                onTap: _busy ? null : () => _pick(state),
              );
            },
          ),
          if (state.backupPrefs.drive.isConnected)
            SliverToBoxAdapter(
              child: ExpansionTile(
                leading: Icon(Icons.cloud_outlined, color: scheme.primary),
                title: const Text('Google Drive'),
                subtitle: const Text('Backups from this or another device'),
                onExpansionChanged: (open) {
                  if (open && _drive == null) {
                    setState(() => _drive = state.driveBackups());
                  }
                },
                children: [_DriveList(
                  request: _drive,
                  onRestore: (file) => _restoreDrive(state, file),
                )],
              ),
            ),
          if (kept.isNotEmpty) ...[
            const _Header('ALREADY ON THIS DEVICE'),
            SliverList.builder(
              itemCount: kept.length,
              itemBuilder: (context, index) {
                final record = kept[index];
                return ListTile(
                  enabled: !_busy,
                  leading: const Icon(Icons.inventory_2_outlined),
                  title: Text(record.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${relativeTime(record.createdAt)} · '
                      '${formatBytes(record.bytes)} · '
                      '${record.counts.summary()}'),
                  onTap: _busy ? null : () => _restoreRecord(state, record),
                );
              },
            ),
          ],
          SliverToBoxAdapter(child: SizedBox(height: 24 + bottom)),
        ],
      ),
    );
  }
}
/// A section label in the list.
class _Header extends StatelessWidget {
  const _Header(this.label, {this.trailing});

  final String label;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
        child: Text(
          trailing == null ? label : '$label · $trailing',
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
      ),
    );
  }
}

/// What is in the Drive folder, once asked for.
class _DriveList extends StatelessWidget {
  const _DriveList({required this.request, required this.onRestore});

  final Future<List<DriveFile>>? request;
  final ValueChanged<DriveFile> onRestore;

  @override
  Widget build(BuildContext context) {
    final request = this.request;
    if (request == null) return const SizedBox.shrink();
    return FutureBuilder<List<DriveFile>>(
      future: request,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          final error = snapshot.error;
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              error is DriveException
                  ? error.message
                  : 'Drive could not be reached ($error).',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          );
        }
        final files = snapshot.data ?? const <DriveFile>[];
        if (files.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No backups in the Drive folder yet.'),
          );
        }
        return Column(
          children: [
            for (final file in files)
              ListTile(
                leading: const Icon(Icons.cloud_download_outlined),
                title:
                    Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text([
                  if (file.createdAt != null) relativeTime(file.createdAt!),
                  if (file.bytes > 0) formatBytes(file.bytes),
                ].join(' · ')),
                onTap: () => onRestore(file),
              ),
          ],
        );
      },
    );
  }
}
