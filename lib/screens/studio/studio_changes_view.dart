import 'package:flutter/material.dart';

import '../../models/studio.dart';
import '../../services/studio/studio_controller.dart';

/// Every change made to the draft, newest first, with a way back to before any
/// of them. Rewinding is to a point: that change and everything after it are
/// undone together, because a later change was made on top of the earlier one.
///
/// A page *body* under the Studio shell's app bar, drawn in the Draft page's
/// language: a summary card, then the changes as rounded rows grouped by day,
/// each with a tonal badge for who made it.
class StudioChangesView extends StatelessWidget {
  const StudioChangesView({super.key, required this.controller});

  final StudioController controller;

  Future<void> _rewind(BuildContext context, int index) async {
    final ops = controller.session.ops;
    final undone = [
      for (var i = index; i < ops.length; i++)
        if (!ops[i].reverted) ops[i],
    ];
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.history),
        title: const Text('Rewind the draft?'),
        content: Text(
          undone.length == 1
              ? 'Undoes "${undone.single.summary}".'
              : 'Undoes "${ops[index].summary}" and the ${undone.length - 1} '
                  'change${undone.length == 2 ? '' : 's'} after it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Rewind'),
          ),
        ],
      ),
    );
    if (ok == true) await controller.rewindTo(index);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final ops = controller.session.ops;
        final theme = Theme.of(context);
        final muted = theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
        if (ops.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.history, size: 40, color: theme.colorScheme.outline),
                  const SizedBox(height: 12),
                  Text(
                    'Nothing has changed yet. Every edit — the Studio\'s or '
                    'yours — shows up here, and you can rewind to before any '
                    'of them.',
                    textAlign: TextAlign.center,
                    style: muted,
                  ),
                ],
              ),
            ),
          );
        }
        final live = ops.where((o) => !o.reverted).length;
        final items = <Widget>[
          _Summary(total: ops.length, live: live, last: ops.last.at),
        ];
        String? day;
        for (var i = ops.length - 1; i >= 0; i--) {
          final op = ops[i];
          final label = _dayLabel(op.at);
          if (label != day) {
            day = label;
            items.add(Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Text(
                label.toUpperCase(),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ));
          }
          items.add(_ChangeRow(
            key: ValueKey('change-${op.id}'),
            op: op,
            canRewind: !controller.running && controller.session.canRewindTo(i),
            onRewind: () => _rewind(context, i),
          ));
        }
        return ListView(
          key: const PageStorageKey('studio-changes'),
          padding: EdgeInsets.only(
            top: 8,
            bottom: 24 + MediaQuery.paddingOf(context).bottom,
          ),
          children: items,
        );
      },
    );
  }

  static String _dayLabel(DateTime at) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(at.year, at.month, at.day);
    final days = today.difference(that).inDays;
    if (days == 0) return 'Today';
    if (days == 1) return 'Yesterday';
    return '${at.year}-${at.month.toString().padLeft(2, '0')}-'
        '${at.day.toString().padLeft(2, '0')}';
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.total, required this.live, required this.last});

  final int total;
  final int live;
  final DateTime last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final undone = total - live;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Material(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(28),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: scheme.secondary,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(Icons.history, color: scheme.onSecondary),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$live change${live == 1 ? '' : 's'} in the draft',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                    Text(
                      '${undone == 0 ? 'Nothing undone' : '$undone undone'} · '
                      'last at ${_time(last)}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSecondaryContainer),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChangeRow extends StatelessWidget {
  const _ChangeRow({
    super.key,
    required this.op,
    required this.canRewind,
    required this.onRewind,
  });

  final StudioOp op;
  final bool canRewind;
  final VoidCallback onRewind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final author = changeAuthor(op);
    final byUser = op.tool == 'manual';
    final (badgeBg, badgeFg) = op.reverted
        ? (scheme.surfaceContainerHighest, scheme.outline)
        : byUser
            ? (scheme.tertiaryContainer, scheme.onTertiaryContainer)
            : (scheme.primaryContainer, scheme.onPrimaryContainer);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: op.reverted ? 0.25 : 0.55),
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: badgeBg,
                  borderRadius: BorderRadius.circular(byUser ? 20 : 13),
                ),
                child: Icon(
                  op.reverted ? Icons.undo : _icon(op),
                  size: 20,
                  color: badgeFg,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      op.summary,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        decoration:
                            op.reverted ? TextDecoration.lineThrough : null,
                        color: op.reverted ? scheme.outline : null,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$author · ${_time(op.at)}'
                      '${op.reverted ? ' · undone' : ''}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (!op.reverted)
                FilledButton.tonal(
                  onPressed: canRewind ? onRewind : null,
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  child: const Text('Rewind'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static IconData _icon(StudioOp op) {
    if (op.tool == 'manual') return Icons.edit_outlined;
    final tool = op.tool.contains(' · ')
        ? op.tool.substring(op.tool.indexOf(' · ') + 3)
        : op.tool;
    if (tool.contains('lore')) return Icons.menu_book_outlined;
    if (tool.contains('document')) return Icons.description_outlined;
    if (tool.contains('avatar')) return Icons.palette_outlined;
    if (tool.contains('greeting')) return Icons.waving_hand_outlined;
    if (tool.contains('scenario')) return Icons.theaters_outlined;
    return Icons.auto_awesome;
  }
}

String _time(DateTime at) => '${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}';
