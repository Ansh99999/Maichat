import 'package:flutter/material.dart';

import '../../../models/home_layout.dart';
import '../home_icon_shape.dart';
import '../home_spec.dart';
import '../quick_targets.dart';

/// A folder of quick-open shortcuts — Android's "app folder" on Home: a 1x1
/// icon that opens a scaled-up popup grid, or inline icons on a bigger span.
class AppFolderSpec extends HomeWidgetSpec {
  const AppFolderSpec();

  @override
  HomeWidgetKind get kind => HomeWidgetKind.appFolder;

  @override
  String get title => 'App folder';

  @override
  String get description => 'A folder of shortcuts';

  @override
  IconData get icon => Icons.folder_special_outlined;

  @override
  Map<String, Object?> get initialConfig => const {'name': 'Folder'};

  @override
  List<HomeOption> options(HomeTile tile) => const [
        HomeTextOption(key: 'name', label: 'Name', hint: 'Folder'),
        HomePickOption(
          key: 'targets',
          label: 'Shortcuts',
          pick: HomePickKind.target,
          multiple: true,
          allowNone: true,
          noneLabel: 'Empty',
        ),
      ];

  @override
  String describe(BuildContext context, HomeTile tile) {
    final name = tile.str('name')?.trim();
    final targets = HomeLayout.folderTargets(tile);
    final label = (name == null || name.isEmpty) ? 'Folder' : name;
    return 'App folder · $label (${targets.length})';
  }

  @override
  Widget build(BuildContext context, HomeTileContext tile) =>
      _AppFolderCard(key: ValueKey(tile.tile.id), tile: tile);
}

List<QuickTarget> _targetsOf(HomeTile tile) => [
      for (final name in HomeLayout.folderTargets(tile)) QuickTarget.byName(name),
    ];

class _AppFolderCard extends StatelessWidget {
  const _AppFolderCard({super.key, required this.tile});

  final HomeTileContext tile;

  String get _name {
    final name = tile.tile.str('name')?.trim();
    return (name == null || name.isEmpty) ? 'Folder' : name;
  }

  Future<void> _openPopup(BuildContext context, List<QuickTarget> targets) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: _name,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (context, _, _) => _FolderPopup(name: _name, targets: targets),
      transitionBuilder: (context, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.82, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final targets = _targetsOf(tile.tile);

    void onTap() {
      if (tile.editing) return;
      _openPopup(context, targets);
    }

    if (tile.w == 1 && tile.h == 1) {
      return _FolderIcon(name: _name, targets: targets, onTap: onTap, shape: tile.layout.iconShape);
    }

    return HomeCard(
      semanticLabel: '$_name folder',
      onTap: onTap,
      builder: (context, inner) => _FolderPreview(
        name: _name,
        targets: targets,
        inner: inner,
      ),
    );
  }
}

/// The 1x1 look: a tonal container with a 2x2 preview of up to 4 shortcut
/// icons, like an Android home-screen folder.
class _FolderIcon extends StatelessWidget {
  const _FolderIcon({
    required this.name,
    required this.targets,
    required this.shape,
    required this.onTap,
  });

  final String name;
  final List<QuickTarget> targets;
  final HomeIconShape shape;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: name,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final side = constraints.biggest.shortestSide.isFinite
              ? constraints.biggest.shortestSide
              : 72.0;
          final border = homeIconBorder(shape, side);
          return HomeOutlined(
            shape: border,
            child: Material(
              color: scheme.surfaceContainerHighest,
              shape: border,
              child: InkWell(
                onTap: onTap,
                customBorder: border,
                child: Padding(
                  padding: EdgeInsets.all(side * 0.14),
                  child: targets.isEmpty
                      ? Icon(Icons.folder_special_outlined,
                          color: scheme.onSurfaceVariant)
                      : _MiniGrid(targets: targets, side: side * 0.72),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MiniGrid extends StatelessWidget {
  const _MiniGrid({required this.targets, required this.side});

  final List<QuickTarget> targets;
  final double side;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = targets.take(4).toList();
    return SizedBox(
      width: side,
      height: side,
      child: GridView.count(
        crossAxisCount: 2,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 3,
        crossAxisSpacing: 3,
        children: [
          for (final t in shown)
            Icon(
              quickTargetInfo(t).icon,
              size: side / 2 - 4,
              color: scheme.onSurfaceVariant,
            ),
        ],
      ),
    );
  }
}

/// A bigger span: the folder's name, and inline icons for the shortcuts it
/// holds (a trailing "+N" cell once more fit than there is room for).
class _FolderPreview extends StatelessWidget {
  const _FolderPreview({
    required this.name,
    required this.targets,
    required this.inner,
  });

  final String name;
  final List<QuickTarget> targets;
  final Size inner;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final nameStyle =
        theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600);
    final iconSize = inner.height >= 96 ? 28.0 : 22.0;
    final perRow = ((inner.width - 8) / (iconSize + 14)).floor().clamp(1, 6);
    final maxIcons = perRow * (inner.height >= 140 ? 2 : 1);
    final shown = targets.take(maxIcons).toList();
    final overflow = targets.length - shown.length;

    Widget iconChip(IconData icon) => Container(
          width: iconSize + 10,
          height: iconSize + 10,
          alignment: Alignment.center,
          decoration: ShapeDecoration(
            color: scheme.surfaceContainerHighest,
            shape: const CircleBorder(),
          ),
          child: Icon(icon, size: iconSize * 0.6, color: scheme.onSurfaceVariant),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(Icons.folder_special_outlined, size: 16, color: scheme.outline),
            const SizedBox(width: 6),
            Expanded(
              child: Text(name,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: nameStyle),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (targets.isEmpty)
          Text('No shortcuts yet',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant))
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in shown) iconChip(quickTargetInfo(t).icon),
              if (overflow > 0)
                Container(
                  width: iconSize + 10,
                  height: iconSize + 10,
                  alignment: Alignment.center,
                  decoration: ShapeDecoration(
                    color: scheme.secondaryContainer,
                    shape: const CircleBorder(),
                  ),
                  child: Text('+$overflow',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: scheme.onSecondaryContainer)),
                ),
            ],
          ),
      ],
    );
  }
}

/// The M3 Expressive scale-up folder window: a rounded panel listing every
/// shortcut in a 4-column grid, each opening its destination.
class _FolderPopup extends StatelessWidget {
  const _FolderPopup({required this.name, required this.targets});

  final String name;
  final List<QuickTarget> targets;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 72, left: 24, right: 24),
          child: Material(
            color: scheme.surfaceContainerHigh,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(32),
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 16),
                  if (targets.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        'This folder has no shortcuts yet. Add some from the '
                        'folder\'s settings.',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    )
                  else
                    GridView.count(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      crossAxisCount: 4,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      children: [
                        for (final t in targets)
                          _PopupIcon(
                            target: t,
                            onTap: () {
                              Navigator.of(context).pop();
                              openQuickTarget(context, t);
                            },
                          ),
                      ],
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

class _PopupIcon extends StatelessWidget {
  const _PopupIcon({required this.target, required this.onTap});

  final QuickTarget target;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final info = quickTargetInfo(target);
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: ShapeDecoration(
                color: scheme.primaryContainer,
                shape: const CircleBorder(),
              ),
              child: Icon(info.icon, color: scheme.onPrimaryContainer),
            ),
            const SizedBox(height: 6),
            Text(
              info.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}
