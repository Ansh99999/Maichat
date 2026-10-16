import 'package:flutter/material.dart';

/// What the tile menu offers.
enum HomeTileAction {
  edit('Edit', Icons.tune_rounded),
  replace('Replace', Icons.swap_horiz_rounded),
  duplicate('Duplicate', Icons.content_copy_rounded),
  move('Move to…', Icons.drive_file_move_outline),
  remove('Remove', Icons.delete_outline_rounded);

  const HomeTileAction(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// The small menu a held or tapped tile opens, anchored at the tile's
/// top-left corner — the launcher pattern the user asked for, in place of a
/// toolbar along the bottom that squeezed the whole page.
///
/// It sits in the page's own overlay layer and never moves the grid. It opens
/// above the tile when there is room, else below its top edge; it slides in
/// from the corner it is pinned to, with a quick spring. Carrying the tile
/// closes it (the home screen just stops drawing it).
class HomeTileMenu extends StatefulWidget {
  const HomeTileMenu({
    super.key,
    required this.anchor,
    required this.area,
    required this.title,
    required this.actions,
    required this.onAction,
  });

  /// The tile's surface rect, in the coordinates of the stack this menu is in.
  final Rect anchor;

  /// The room the menu may use (the same stack's size).
  final Size area;

  final String title;
  final List<HomeTileAction> actions;
  final ValueChanged<HomeTileAction> onAction;

  static const double width = 228;
  static const double cellHeight = 64;
  static const int columns = 3;

  /// The menu's height for [count] actions.
  static double heightFor(int count) =>
      40 + ((count + columns - 1) ~/ columns) * cellHeight + 8;

  @override
  State<HomeTileMenu> createState() => _HomeTileMenuState();
}

class _HomeTileMenuState extends State<HomeTileMenu>
    with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..forward();

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final height = HomeTileMenu.heightFor(widget.actions.length);
    const gap = 8.0;
    // Above the tile's top-left corner when it fits, else below the tile, else
    // beside it — never over the tile it is about, which has to stay grabbable.
    // A tile too big for any of those gets the menu over its top edge, where
    // the least of it is covered. Clamped into the area either way.
    final a = widget.anchor;
    final area = widget.area;
    const w = HomeTileMenu.width;
    final above = a.top - gap >= height;
    var left = a.left;
    double top;
    var growsUp = false;
    if (above) {
      top = a.top - gap - height;
      growsUp = true;
    } else if (area.height - a.bottom - gap >= height) {
      top = a.bottom + gap;
    } else if (area.width - a.right - gap >= w) {
      top = a.top;
      left = a.right + gap;
    } else if (a.left - gap >= w) {
      top = a.top;
      left = a.left - gap - w;
    } else {
      top = a.top + gap;
      left = a.left + gap;
    }
    top = top.clamp(0.0, (area.height - height).clamp(0.0, double.infinity));
    left = left.clamp(0.0, (area.width - w).clamp(0.0, double.infinity));
    final curve = CurvedAnimation(parent: _in, curve: Curves.easeOutBack);
    return Positioned(
      left: left,
      top: top,
      width: HomeTileMenu.width,
      child: FadeTransition(
        opacity: CurvedAnimation(parent: _in, curve: Curves.easeOut),
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.86, end: 1).animate(curve),
          alignment: growsUp ? Alignment.bottomLeft : Alignment.topLeft,
          child: Material(
            color: scheme.surfaceContainerHigh,
            elevation: 3,
            shadowColor: scheme.shadow.withValues(alpha: 0.4),
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 40,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Wrap(
                      children: [
                        for (final action in widget.actions)
                          _MenuCell(
                            action: action,
                            onTap: () => widget.onAction(action),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One action of [HomeTileMenu]: an icon over a short label, a compact
/// launcher-menu cell with an Expressive pill-shaped press highlight.
class _MenuCell extends StatelessWidget {
  const _MenuCell({required this.action, required this.onTap});

  final HomeTileAction action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final danger = action == HomeTileAction.remove;
    return SizedBox(
      width: (HomeTileMenu.width - 12) / HomeTileMenu.columns,
      height: HomeTileMenu.cellHeight,
      child: InkWell(
        key: ValueKey('home-menu-${action.name}'),
        onTap: onTap,
        customBorder: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              action.icon,
              size: 22,
              color: danger ? scheme.error : scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                action.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: danger ? scheme.error : scheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
