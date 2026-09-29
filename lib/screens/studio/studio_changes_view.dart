import 'package:flutter/material.dart';

import '../../models/studio.dart';
import '../../services/studio/studio_controller.dart';
import 'draft/draft_widgets.dart';
import 'shell/studio_apply.dart';
import 'shell/studio_chrome.dart';

/// Where the draft stands against the library, and every change made to it.
///
/// At the top, the one question this page exists to ask: save this character?
/// Its wording follows the state — never saved, changed since it was, or saved
/// as it is — and it is the only route by which the draft reaches the library.
/// Below it, the changes, newest first, each with a way back to before it.
/// Rewinding is to a point: that change and everything after it are undone
/// together, because a later change was made on top of the earlier one.
///
/// A page *body*: the Studio shell floats its menu over the top and the area
/// capsule over the foot, so this lays out underneath both.
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
        // Inside the shell the page starts under the status bar and the
        // floating menu square; on its own (a test) it starts at the top.
        final chrome = context
            .dependOnInheritedWidgetOfExactType<StudioChrome>();
        final items = <Widget>[
          SizedBox(height: chrome == null ? 16 : chrome.top + 4),
          // A blank new draft has nothing to save and no question to ask.
          if (ops.isNotEmpty ||
              controller.session.appliedSinceChange ||
              controller.session.appliedAt != null)
            _SaveCard(controller: controller),
        ];
        if (ops.isEmpty) {
          items.add(
            const DraftEmpty(
              icon: Icons.history,
              text:
                  'Nothing has changed yet. Every edit — the Studio\'s or '
                  'yours — shows up here, and you can rewind to before any of '
                  'them.',
            ),
          );
        } else {
          String? day;
          final rows = <Widget>[];
          void flush() {
            if (rows.isEmpty) return;
            items.add(DraftCard(children: List.of(rows)));
            rows.clear();
          }

          for (var i = ops.length - 1; i >= 0; i--) {
            final op = ops[i];
            final label = _dayLabel(op.at);
            if (label != day) {
              flush();
              day = label;
              items.add(DraftSectionLabel(label));
            }
            rows.add(
              _ChangeRow(
                key: ValueKey('change-${op.id}'),
                op: op,
                canRewind:
                    !controller.running && controller.session.canRewindTo(i),
                onRewind: () => _rewind(context, i),
              ),
            );
          }
          flush();
        }
        return ListView(
          key: const PageStorageKey('studio-changes'),
          padding: draftListPadding(context, top: 0),
          children: [
            DefaultTextStyle.merge(
              style: theme.textTheme.bodyMedium,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: items,
              ),
            ),
          ],
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
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June', 'July', //
      'August', 'September', 'October', 'November', 'December',
    ];
    return '${at.day} ${months[at.month - 1]}'
        '${at.year == now.year ? '' : ' ${at.year}'}';
  }
}

/// Where the draft stands against the library, as one roomy card with one
/// action. Saved-and-unchanged is drawn quietly and has nothing to press;
/// either unsaved state is drawn in the primary container with Save.
class _SaveCard extends StatelessWidget {
  const _SaveCard({required this.controller});

  final StudioController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final session = controller.session;
    final name = session.workspace.character.name.trim();
    final saved = session.appliedSinceChange;
    final everSaved =
        session.appliedAt != null || session.sourceCharacterId != null;
    final running = controller.running;

    final String title;
    final String body;
    if (saved) {
      title = 'Saved to your library';
      body =
          'No changes since. Anything you or the Studio change next can be '
          'saved here.';
    } else if (everSaved) {
      title = 'Save the latest changes?';
      body = 'Your library still has the version from before them.';
    } else {
      title = 'Save this character?';
      body = name.isEmpty
          ? 'Adds the character to your library, with its lorebooks.'
          : 'Adds $name to your library, with its lorebooks.';
    }

    final background = saved
        ? scheme.surfaceContainer
        : scheme.primaryContainer;
    final foreground = saved
        ? scheme.onSurfaceVariant
        : scheme.onPrimaryContainer;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kDraftCardInset),
      child: AnimatedContainer(
        key: const ValueKey('studio-save-card'),
        duration: kDraftFoldDuration,
        curve: kDraftFoldCurve,
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(32),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: saved ? scheme.surfaceContainerHighest : scheme.primary,
                // A square-ish blob while there is something to save, a circle
                // once it is saved: the shape says the state before the words.
                borderRadius: BorderRadius.circular(saved ? 26 : 18),
              ),
              child: Icon(
                saved ? Icons.check : Icons.bookmark_add_outlined,
                color: saved ? scheme.onSurfaceVariant : scheme.onPrimary,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: saved ? scheme.onSurface : foreground,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              running ? 'Saving waits until the Studio finishes.' : body,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: foreground,
                height: 1.45,
              ),
            ),
            if (!saved) ...[
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  key: const ValueKey('studio-save-button'),
                  onPressed: running
                      ? null
                      : () => showStudioApplyFlow(context, controller),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 52),
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                  ),
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Save'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One change: what it did, who and when underneath, and Rewind.
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
      padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: badgeBg,
              // You are a circle, the Studio a soft square.
              borderRadius: BorderRadius.circular(byUser ? 22 : 14),
            ),
            child: Icon(
              op.reverted ? Icons.undo : _icon(op),
              size: 20,
              color: badgeFg,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  op.summary,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    decoration: op.reverted ? TextDecoration.lineThrough : null,
                    color: op.reverted ? scheme.outline : null,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$author · ${_time(op.at)}${op.reverted ? ' · undone' : ''}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (!op.reverted) ...[
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Rewind to before this',
              onPressed: canRewind ? onRewind : null,
              icon: const Icon(Icons.history),
            ),
          ],
        ],
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

String _time(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}';
