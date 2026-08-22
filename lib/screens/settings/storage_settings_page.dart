import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../services/storage_report.dart';
import '../../state/app_state.dart';
import '../../widgets/storage_bar.dart';
import '../library/embeddings_screen.dart';
import 'storage_category_screen.dart';

/// Settings ▸ Storage: how much room the app is using, split by category, with a
/// segmented bar + legend on top and a drill-in row per category. Replaces the
/// raw key-size readout that used to hide in About.
class StorageSettingsPage extends StatefulWidget {
  const StorageSettingsPage({super.key});

  @override
  State<StorageSettingsPage> createState() => _StorageSettingsPageState();
}

class _StorageSettingsPageState extends State<StorageSettingsPage> {
  late Future<StorageReport> _report = _load();

  Future<StorageReport> _load() => context.read<AppState>().storageReport();

  void _refresh() => setState(() => _report = _load());

  void _open(StorageCategory category) {
    final page = switch (category) {
      StorageCategory.images => const StorageImagesScreen(),
      StorageCategory.cache => const StorageCacheScreen(),
      StorageCategory.embeddings => const EmbeddingsScreen(),
      _ => StorageCategoryScreen(category: category),
    };
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => page))
        .then((_) => _refresh()); // reflect any deletions on return
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Storage'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Recalculate',
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<StorageReport>(
        future: _report,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final report = snapshot.data!;
          final present = report.nonEmpty;
          return ListView(
            padding: EdgeInsets.only(bottom: 16 + bottom),
            children: [
              _UsedCard(report: report, present: present),
              const Divider(height: 8, indent: 16, endIndent: 16),
              for (final usage in report.categories)
                _CategoryRow(
                  usage: usage,
                  onTap: usage.category.manageable
                      ? () => _open(usage.category)
                      : null,
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The "Used · X MB" hero card with the segmented bar and its legend.
class _UsedCard extends StatelessWidget {
  const _UsedCard({required this.report, required this.present});

  final StorageReport report;
  final List<StorageCategoryUsage> present;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      color: scheme.surfaceContainerHigh,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Used',
                style: theme.textTheme.labelLarge
                    ?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 4),
            Text(
              formatBytes(report.totalBytes),
              style: theme.textTheme.displaySmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            StorageBar(segments: present, total: report.totalBytes),
            const SizedBox(height: 14),
            StorageLegend(segments: present),
          ],
        ),
      ),
    );
  }
}

/// One category row: a colour-tinted icon, the name, and "size · N files" with a
/// chevron when there is a screen to open.
class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.usage, required this.onTap});

  final StorageCategoryUsage usage;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = storageColor(usage.category, theme.brightness);
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          shape: BoxShape.circle,
        ),
        child: Icon(usage.category.icon, color: color, size: 22),
      ),
      title: Text(usage.category.label),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${formatBytes(usage.bytes)} · ${usage.count} '
            '${usage.count == 1 ? 'file' : 'files'}',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
          ],
        ],
      ),
    );
  }
}
