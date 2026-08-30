import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/backup.dart';
import '../../services/backup_codec.dart';
import '../../services/drive_client.dart';
import '../../services/storage_report.dart';
import '../../state/app_state.dart';
import 'drive_settings_page.dart';

/// Opens the export window over the Backups screen: the settings for how
/// backups are taken, then the places one can go.
///
/// A sheet rather than a page because exporting is a decision taken *about* the
/// list behind it — the list stays visible, and backing out leaves nothing half
/// done.
Future<void> showBackupExportSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.92,
      ),
      builder: (_) => const BackupExportSheet(),
    );

class BackupExportSheet extends StatefulWidget {
  const BackupExportSheet({super.key});

  @override
  State<BackupExportSheet> createState() => _BackupExportSheetState();
}

class _BackupExportSheetState extends State<BackupExportSheet> {
  bool _busy = false;
  String? _error;

  /// Writes the archive wherever the system save dialog points. Returns null
  /// both when the user cancels and when Android declines to give a path, which
  /// are indistinguishable from here — the message says only that nothing was
  /// written.
  Future<String?> _saveToFile(String name, Uint8List bytes) async {
    try {
      return await FilePicker.saveFile(
        dialogTitle: 'Save backup',
        fileName: name,
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: const ['zip'],
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _export(AppState state, BackupDestination destination) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final record = await state.exportBackup(
        destination: destination,
        save: destination == BackupDestination.file
            ? (name, bytes) => _saveToFile(name, bytes)
            : null,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      final messenger = ScaffoldMessenger.of(context);
      if (record == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Nothing was written.')),
        );
        return;
      }
      Navigator.of(context).pop();
      messenger.showSnackBar(SnackBar(
        content: Text('Exported ${record.name} · '
            '${formatBytes(record.bytes)} · ${record.counts.summary()}'),
      ));
    } on BackupFormatException catch (error) {
      _fail(error.message);
    } on DriveException catch (error) {
      _fail(error.message);
    } catch (error) {
      _fail('The export did not finish ($error).');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = message;
    });
  }
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final prefs = state.backupPrefs;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The same shape the section header has: the way back top left, the
        // title big underneath it.
        Padding(
          padding: const EdgeInsets.only(left: 4, top: 8),
          child: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back',
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(
            'Export',
            style: theme.textTheme.headlineMedium
                ?.copyWith(fontWeight: FontWeight.w500),
          ),
        ),
        if (_busy) const LinearProgressIndicator(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              _SettingsFold(
                prefs: prefs,
                busy: _busy,
                onChanged: state.updateBackupPrefs,
                onDrive: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const DriveSettingsPage(),
                  ),
                ),
              ),
              const Divider(height: 8),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                  child: Text(
                    _error!,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: scheme.error),
                  ),
                ),
              _DestinationTile(
                icon: Icons.folder_zip_outlined,
                title: 'Save a zip file',
                subtitle: 'Everything in one file, wherever you point the save '
                    'dialog. Import it on any device.',
                enabled: !_busy,
                onTap: () => _export(state, BackupDestination.file),
              ),
              _DestinationTile(
                icon: Icons.cloud_upload_outlined,
                title: 'Google Drive',
                subtitle: prefs.drive.isConnected
                    ? 'Uploads to "MaiChat Backups"'
                        '${prefs.drive.email.isEmpty ? '' : ' · '
                            '${prefs.drive.email}'}'
                    : 'Not connected yet — set it up first',
                enabled: !_busy,
                onTap: prefs.drive.isConnected
                    ? () => _export(state, BackupDestination.drive)
                    : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const DriveSettingsPage(),
                          ),
                        ),
              ),
              _DestinationTile(
                icon: Icons.inventory_2_outlined,
                title: 'Keep a copy in the app',
                subtitle: state.canKeepBackups
                    ? 'Restore it straight from this screen later. This is where '
                        'scheduled backups go.'
                    : 'Unavailable on this device',
                enabled: !_busy && state.canKeepBackups,
                onTap: () => _export(state, BackupDestination.device),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
/// One place a backup can go.
class _DestinationTile extends StatelessWidget {
  const _DestinationTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      enabled: enabled,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: scheme.onSecondaryContainer, size: 22),
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      onTap: enabled ? onTap : null,
    );
  }
}

/// The "export settings" fold: how often a backup is taken by itself, where
/// those go, what goes in one, and how many to keep.
class _SettingsFold extends StatelessWidget {
  const _SettingsFold({
    required this.prefs,
    required this.busy,
    required this.onChanged,
    required this.onDrive,
  });

  final BackupPrefs prefs;
  final bool busy;
  final ValueChanged<BackupPrefs> onChanged;
  final VoidCallback onDrive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      leading: const Icon(Icons.tune),
      title: const Text('Export settings'),
      subtitle: Text(
        '${prefs.schedule.label}'
        '${prefs.automatic ? ' · ${prefs.autoDestination.label}' : ''}',
      ),
      childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      children: [
        DropdownButtonFormField<BackupSchedule>(
          initialValue: prefs.schedule,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Automatic backups'),
          items: [
            for (final schedule in BackupSchedule.values)
              DropdownMenuItem(value: schedule, child: Text(schedule.label)),
          ],
          onChanged: busy
              ? null
              : (value) => onChanged(
                    prefs.copyWith(schedule: value ?? BackupSchedule.off),
                  ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            prefs.schedule.detail,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        if (prefs.automatic) ...[
          const SizedBox(height: 16),
          DropdownButtonFormField<BackupDestination>(
            initialValue: prefs.autoDestination == BackupDestination.file
                ? BackupDestination.device
                : prefs.autoDestination,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Where they go',
              // A save dialog needs somebody in front of the screen, so it is
              // not a choice a schedule can make.
              helperText: 'A scheduled backup cannot open a save dialog',
            ),
            items: const [
              DropdownMenuItem(
                value: BackupDestination.device,
                child: Text('In the app'),
              ),
              DropdownMenuItem(
                value: BackupDestination.drive,
                child: Text('Google Drive'),
              ),
            ],
            onChanged: busy
                ? null
                : (value) {
                    if (value == BackupDestination.drive &&
                        !prefs.drive.isConnected) {
                      onDrive();
                      return;
                    }
                    onChanged(prefs.copyWith(
                      autoDestination: value ?? BackupDestination.device,
                    ));
                  },
          ),
        ],
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: prefs.includeKeys,
          title: const Text('Include API keys'),
          subtitle: const Text(
            'Written in plain text, so the app can send again straight after a '
            'restore. Keep the file somewhere safe.',
          ),
          onChanged: busy
              ? null
              : (value) => onChanged(prefs.copyWith(includeKeys: value)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: prefs.includePictures,
          title: const Text('Include pictures'),
          subtitle: const Text(
            'Avatars, gallery and chat backgrounds. Much the largest part of a '
            'backup, and what puts a picture back in the message it was sent in.',
          ),
          onChanged: busy
              ? null
              : (value) => onChanged(prefs.copyWith(includePictures: value)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: prefs.includeVectors,
          title: const Text('Include embeddings'),
          subtitle: const Text(
            'The vectors behind semantic recall. Left out, they are rebuilt on '
            'demand after a restore.',
          ),
          onChanged: busy
              ? null
              : (value) => onChanged(prefs.copyWith(includeVectors: value)),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<int>(
          initialValue: const [3, 5, 10, 20].contains(prefs.keep)
              ? prefs.keep
              : 5,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'How many to keep',
            helperText: 'Older ones in the app and on Drive are deleted',
          ),
          items: const [
            DropdownMenuItem(value: 3, child: Text('3 backups')),
            DropdownMenuItem(value: 5, child: Text('5 backups')),
            DropdownMenuItem(value: 10, child: Text('10 backups')),
            DropdownMenuItem(value: 20, child: Text('20 backups')),
          ],
          onChanged: busy
              ? null
              : (value) => onChanged(prefs.copyWith(keep: value ?? 5)),
        ),
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.cloud_outlined),
          title: const Text('Google Drive'),
          subtitle: Text(prefs.drive.isConnected
              ? prefs.drive.email.isEmpty ? 'Connected' : prefs.drive.email
              : 'Not connected'),
          trailing: const Icon(Icons.chevron_right),
          onTap: busy ? null : onDrive,
        ),
      ],
    );
  }
}
