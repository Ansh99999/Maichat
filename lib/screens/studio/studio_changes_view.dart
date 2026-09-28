import 'package:flutter/material.dart';

import '../../models/studio.dart';
import '../../services/studio/studio_controller.dart';

/// Every change made to the draft, newest first, with a way back to before any
/// of them. Rewinding is to a point: that change and everything after it are
/// undone together, because a later change was made on top of the earlier one.
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
              child: Text(
                'Nothing has changed yet. Every edit — the Studio\'s or yours — '
                'shows up here, and you can rewind to before any of them.',
                textAlign: TextAlign.center,
                style: muted,
              ),
            ),
          );
        }
        return ListView.builder(
          padding: EdgeInsets.only(
            top: 8,
            bottom: 24 + MediaQuery.paddingOf(context).bottom,
          ),
          itemCount: ops.length,
          itemBuilder: (context, i) {
            final index = ops.length - 1 - i;
            final op = ops[index];
            final canRewind =
                !controller.running && controller.session.canRewindTo(index);
            return ListTile(
              leading: Icon(
                op.reverted ? Icons.undo : _icon(op),
                color: op.reverted ? theme.colorScheme.outline : null,
              ),
              title: Text(
                op.summary,
                style: op.reverted
                    ? TextStyle(
                        decoration: TextDecoration.lineThrough,
                        color: theme.colorScheme.outline,
                      )
                    : null,
              ),
              subtitle: Text(
                '${changeAuthor(op)} · ${_time(op.at)}'
                '${op.reverted ? ' · undone' : ''}',
                style: muted,
              ),
              trailing: op.reverted
                  ? null
                  : TextButton(
                      onPressed: canRewind ? () => _rewind(context, index) : null,
                      child: const Text('Rewind'),
                    ),
            );
          },
        );
      },
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

  static String _time(DateTime at) {
    final now = DateTime.now();
    final hm = '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
    if (now.year == at.year && now.month == at.month && now.day == at.day) {
      return hm;
    }
    return '${at.month}/${at.day} $hm';
  }
}
