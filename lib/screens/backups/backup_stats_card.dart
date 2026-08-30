import 'package:flutter/material.dart';

import '../../models/backup.dart';
import '../../services/storage_report.dart';
import '../chats_screen.dart' show relativeTime;

/// The statistics block on the Backups screen: one hero figure — how much has
/// been exported altogether — and a small grid of stat tiles around it.
///
/// Deliberately not a chart. Six independent numbers have no shape to read, so a
/// chart would only decorate them; the numbers themselves, in the app's own text
/// roles with no colour encoding, are the readable form.
class BackupStatsCard extends StatelessWidget {
  const BackupStatsCard({
    super.key,
    required this.stats,
    required this.keptBytes,
  });

  final BackupStats stats;

  /// How much room the copies the app is holding take, which is the number that
  /// answers "is this costing me anything?".
  final int keptBytes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tiles = <(String, String)>[
      ('Backups taken', '${stats.count}'),
      ('Newest', stats.newest == null ? '—' : relativeTime(stats.newest!)),
      ('Largest', formatBytes(stats.largestBytes)),
      ('Average', formatBytes(stats.averageBytes)),
      ('Kept in the app', formatBytes(keptBytes)),
      ('Taken on a schedule', '${stats.automatic}'),
      if (stats.messages > 0) ('Messages in the last one', '${stats.messages}'),
      if (stats.byDestination[BackupDestination.drive] != null)
        ('On Google Drive', '${stats.byDestination[BackupDestination.drive]}'),
    ];

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      color: scheme.surfaceContainerHigh,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Exported so far',
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(
              formatBytes(stats.totalBytes),
              style: theme.textTheme.displaySmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 18),
            LayoutBuilder(
              builder: (context, constraints) {
                // Two columns on a phone, more when there is room; the tiles are
                // independent numbers, so they wrap rather than scroll.
                final columns = constraints.maxWidth > 520 ? 3 : 2;
                final width =
                    (constraints.maxWidth - (columns - 1) * 12) / columns;
                return Wrap(
                  spacing: 12,
                  runSpacing: 16,
                  children: [
                    for (final tile in tiles)
                      SizedBox(
                        width: width,
                        child: _StatTile(label: tile.$1, value: tile.$2),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// One number with its name under it. Sentence-case label, semibold value, no
/// colour of its own — identity here comes from the words, not a hue.
class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
