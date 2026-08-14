import 'package:flutter/material.dart';

import '../../app_info.dart';
import '../../services/storage.dart';
import 'setting_anchors.dart';
import 'setting_highlight.dart';

/// App version and the plain truth about where data lives.
class AboutSettingsPage extends StatelessWidget {
  const AboutSettingsPage({super.key, this.highlight});

  final SettingAnchor? highlight;

  /// Kept in step with the `version:` line in pubspec.yaml.
  static const String version = kAppVersion;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          8,
          8,
          8,
          16 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          SettingHighlight(
            active: highlight == SettingAnchor.version,
            child: const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('MaiChat'),
              subtitle: Text('A minimal OpenAI-compatible chat client.'),
              trailing: Text(version),
            ),
          ),
          const Divider(height: 8),
          SettingHighlight(
            active: highlight == SettingAnchor.storage,
            child: ListTile(
              leading: const Icon(Icons.sd_storage_outlined),
              title: const Text('Storage'),
              subtitle: Text(
                'Settings and chats are stored in this app\'s private storage '
                'on the device, unencrypted. Use a scoped key you can revoke.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          ),
          const _StorageUsage(),
        ],
      ),
    );
  }
}

/// What the store actually holds, biggest entry first. The whole thing is read
/// at launch and rewritten on every save, so an entry that has grown out of
/// proportion (a huge character picture, most often) is worth seeing.
class _StorageUsage extends StatefulWidget {
  const _StorageUsage();

  @override
  State<_StorageUsage> createState() => _StorageUsageState();
}

class _StorageUsageState extends State<_StorageUsage> {
  late final Future<Map<String, int>> _usage = Storage().usage();

  static String _size(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<Map<String, int>>(
      future: _usage,
      builder: (context, snapshot) {
        final usage = snapshot.data;
        if (usage == null || usage.isEmpty) return const SizedBox.shrink();
        final total = usage.values.fold<int>(0, (sum, v) => sum + v);
        final biggest = usage.entries.take(3);
        return Padding(
          padding: const EdgeInsets.fromLTRB(72, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Using ${_size(total)}',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              for (final entry in biggest)
                Text(
                  '${entry.key} · ${_size(entry.value)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
