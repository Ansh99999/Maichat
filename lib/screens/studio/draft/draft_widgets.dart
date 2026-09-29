import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../shell/studio_chrome.dart';
import '../studio_text_dialog.dart';

/// How long a fold takes to open or close, and how it moves. A spring would be
/// wrong here — text that overshoots its own height reads as a glitch — so the
/// folds use M3's emphasized decelerate: quick off the mark, soft landing.
const Duration kDraftFoldDuration = Duration(milliseconds: 320);
const Curve kDraftFoldCurve = Curves.easeOutCubic;

/// The page's side margin. Wide on purpose: the Draft is read far more than it
/// is edited, and a column with air on both sides reads at a glance where an
/// edge-to-edge one reads as a form.
const double kDraftGutter = 24;

/// How far the grouped surfaces sit in from the edge; their own padding makes
/// up the rest of [kDraftGutter].
const double kDraftCardInset = 16;

/// The corner of a group's outer ends, and of the seams between its rows.
const double kDraftOuterRadius = 28;
const double kDraftInnerRadius = 6;

/// A scrolling page's padding: a little air at the top, and at the bottom
/// enough to scroll the last row clear of whatever the Studio floats over the
/// page's foot (the capsule) or the system's gesture bar.
EdgeInsets draftListPadding(BuildContext context, {double top = 12}) {
  final chrome = StudioChrome.of(context);
  final safe = MediaQuery.paddingOf(context).bottom;
  return EdgeInsets.only(top: top, bottom: math.max(chrome.bottom, safe) + 32);
}

/// A section's heading: a quiet sentence-case title with room above it, so the
/// page falls into a few calm groups rather than one long list. A [count] is
/// drawn beside it, muted — there if wanted, never shouted.
class DraftSectionLabel extends StatelessWidget {
  const DraftSectionLabel(
    this.text, {
    super.key,
    this.count,
    this.first = false,
  });

  final String text;
  final int? count;

  /// The first section of a page sits closer to the top.
  final bool first;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        kDraftGutter + 4,
        first ? 8 : 32,
        kDraftGutter,
        12,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Flexible(
            child: Text(
              text,
              style: theme.textTheme.titleMedium?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 8),
            Text(
              '$count',
              style: theme.textTheme.labelLarge?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A group of rows the Material 3 Expressive way: each row its own rounded
/// surface, the group's two ends rounded generously and the seams between rows
/// barely rounded, with a hairline of page showing between them — so a group
/// reads as one thing without its rows running together.
class DraftCard extends StatelessWidget {
  const DraftCard({super.key, required this.children, this.padding});

  final List<Widget> children;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final n = children.length;
    return Padding(
      padding:
          padding ?? const EdgeInsets.symmetric(horizontal: kDraftCardInset),
      child: Column(
        children: [
          for (var i = 0; i < n; i++)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 2),
              child: Material(
                color: scheme.surfaceContainer,
                clipBehavior: Clip.antiAlias,
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(
                    i == 0 ? kDraftOuterRadius : kDraftInnerRadius,
                  ),
                  bottom: Radius.circular(
                    i == n - 1 ? kDraftOuterRadius : kDraftInnerRadius,
                  ),
                ),
                child: children[i],
              ),
            ),
        ],
      ),
    );
  }
}

/// One text of the draft as a row: its name, a one-line glimpse of the words,
/// a chevron that folds the whole text open, and a pencil that edits it.
///
/// Folded, the row is two quiet lines, so a page of rows can be taken in at a
/// glance. What only matters once you are reading the text — how many tokens
/// it costs, a note on what it is for — appears when it is opened. The fold
/// animates its height; the words are uncovered, not faded in.
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

  /// A note on what the text is for, shown once the row is opened.
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
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final text = widget.value.trim();
    final empty = text.isEmpty;
    final canFold = widget.foldable && !empty;
    final folded = canFold && !_open;
    final body = Text(
      empty ? 'Empty' : text,
      maxLines: folded ? 1 : null,
      overflow: folded ? TextOverflow.ellipsis : null,
      style: empty
          ? theme.textTheme.bodyMedium?.copyWith(
              color: scheme.outline,
              fontStyle: FontStyle.italic,
            )
          : theme.textTheme.bodyMedium?.copyWith(
              color: folded ? scheme.onSurfaceVariant : scheme.onSurface,
              height: 1.5,
            ),
    );
    final details = <String>[
      if (widget.subtitle != null) widget.subtitle!,
      if (widget.tokens != null && !empty) 'About ${widget.tokens} tokens',
    ];
    return InkWell(
      onTap: canFold ? () => setState(() => _open = !_open) : widget.onEdit,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 8, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.label,
                    style: theme.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
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
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: AnimatedSize(
                duration: kDraftFoldDuration,
                curve: kDraftFoldCurve,
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: double.infinity,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      body,
                      if ((_open || !canFold) && details.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(details.join(' · '), style: muted),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
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
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        kDraftCardInset,
        8,
        kDraftCardInset,
        0,
      ),
      child: Material(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(kDraftOuterRadius),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
          child: Row(
            children: [
              Icon(
                Icons.lock_clock_outlined,
                size: 20,
                color: scheme.onSecondaryContainer,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  'Hand edits wait until the Studio finishes.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSecondaryContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
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
    padding: const EdgeInsets.fromLTRB(kDraftGutter, 20, kDraftGutter, 0),
    child: Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.tonalIcon(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 52),
          padding: const EdgeInsets.symmetric(horizontal: 24),
        ),
        icon: Icon(icon),
        label: Text(label),
      ),
    ),
  );
}

/// What a tab says when it has nothing in it yet: a large soft icon and one
/// sentence, with room around them.
class DraftEmpty extends StatelessWidget {
  const DraftEmpty({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 32, 40, 8),
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Icon(icon, size: 32, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Text(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}
