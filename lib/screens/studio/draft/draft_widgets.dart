import 'package:flutter/material.dart';

import '../studio_text_dialog.dart';

/// How long a fold takes to open or close, and how it moves. A spring would be
/// wrong here — text that overshoots its own height reads as a glitch — so the
/// folds use M3's emphasized decelerate: quick off the mark, soft landing.
const Duration kDraftFoldDuration = Duration(milliseconds: 320);
const Curve kDraftFoldCurve = Curves.easeOutCubic;

/// A small uppercase heading between groups of rows.
class DraftSectionLabel extends StatelessWidget {
  const DraftSectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

/// A rounded group of rows on the page surface — M3 Expressive's grouped list:
/// rows share one container, with the container's corners generous and the
/// seams between rows slim.
class DraftCard extends StatelessWidget {
  const DraftCard({super.key, required this.children, this.padding});

  final List<Widget> children;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: padding ?? const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(24),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 1,
                  thickness: 1,
                  indent: 16,
                  endIndent: 16,
                  color: scheme.outlineVariant.withValues(alpha: 0.5),
                ),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// One text of the draft as a row: its name and token count, a chevron that
/// folds the text open and shut, and a pencil that edits it.
///
/// Folded, the row shows a single line of the text so a page of rows can be
/// read at a glance; opened, the whole of it. The fold animates its height
/// only — the words do not fade in, they are uncovered.
class DraftFieldRow extends StatefulWidget {
  const DraftFieldRow({
    super.key,
    required this.label,
    required this.value,
    this.tokens,
    this.subtitle,
    this.onEdit,
    this.foldable = true,
    this.initiallyOpen = false,
    this.trailing,
  });

  final String label;
  final String value;
  final int? tokens;
  final String? subtitle;

  /// Opens the editor; null while the draft is locked (the agent is working).
  final VoidCallback? onEdit;

  /// Short values (a name, a version) are shown whole and have no chevron.
  final bool foldable;
  final bool initiallyOpen;

  /// Anything else the row carries beside the pencil (a menu, say).
  final Widget? trailing;

  @override
  State<DraftFieldRow> createState() => _DraftFieldRowState();
}

class _DraftFieldRowState extends State<DraftFieldRow> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted =
        theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final text = widget.value.trim();
    final empty = text.isEmpty;
    final canFold = widget.foldable && !empty;
    final body = Text(
      empty ? 'Empty' : text,
      maxLines: canFold && !_open ? 1 : null,
      overflow: canFold && !_open ? TextOverflow.ellipsis : null,
      style: empty
          ? muted?.copyWith(fontStyle: FontStyle.italic)
          : theme.textTheme.bodyMedium?.copyWith(
              color: canFold && !_open ? scheme.onSurfaceVariant : null,
              height: 1.4,
            ),
    );
    return InkWell(
      onTap: canFold
          ? () => setState(() => _open = !_open)
          : widget.onEdit,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.label,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (widget.tokens != null && !empty) ...[
                        const SizedBox(width: 8),
                        _TokenPill(tokens: widget.tokens!),
                      ],
                    ],
                  ),
                ),
                if (canFold)
                  IconButton(
                    tooltip: _open
                        ? 'Fold ${widget.label.toLowerCase()}'
                        : 'Show ${widget.label.toLowerCase()}',
                    onPressed: () => setState(() => _open = !_open),
                    icon: AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: kDraftFoldDuration,
                      curve: kDraftFoldCurve,
                      child: const Icon(Icons.keyboard_arrow_down),
                    ),
                  ),
                IconButton(
                  tooltip: 'Edit ${widget.label.toLowerCase()}',
                  onPressed: widget.onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 20),
                ),
                ?widget.trailing,
              ],
            ),
            if (widget.subtitle != null)
              Padding(
                padding: const EdgeInsets.only(right: 12, bottom: 4),
                child: Text(widget.subtitle!, style: muted),
              ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: AnimatedSize(
                duration: kDraftFoldDuration,
                curve: kDraftFoldCurve,
                alignment: Alignment.topLeft,
                child: SizedBox(width: double.infinity, child: body),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TokenPill extends StatelessWidget {
  const _TokenPill({required this.tokens});

  final int tokens;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$tokens tok',
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: scheme.onSecondaryContainer),
      ),
    );
  }
}

/// Edits [value] in a tall fixed box (or a single line when [tall] is off) and
/// returns the new text, or null when cancelled or unchanged.
Future<String?> editDraftText(
  BuildContext context, {
  required String label,
  required String value,
  bool tall = true,
}) async {
  final next = await showStudioTextDialog(
    context,
    title: label,
    initial: value,
    tall: tall,
  );
  if (next == null || next == value) return null;
  return next;
}

/// A line under a tab's rows saying edits wait for the Studio, shown while it
/// works — so a greyed-out pencil explains itself.
class DraftLockedNote extends StatelessWidget {
  const DraftLockedNote({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
      child: Row(
        children: [
          Icon(Icons.lock_clock_outlined,
              size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Hand edits wait until the Studio finishes.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// A tonal "add" button at the foot of a tab's list.
class DraftAddButton extends StatelessWidget {
  const DraftAddButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon = Icons.add,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            onPressed: onPressed,
            icon: Icon(icon),
            label: Text(label),
          ),
        ),
      );
}

/// What a tab says when it has nothing in it yet.
class DraftEmpty extends StatelessWidget {
  const DraftEmpty({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Column(
        children: [
          Icon(icon, size: 36, color: theme.colorScheme.outline),
          const SizedBox(height: 10),
          Text(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
