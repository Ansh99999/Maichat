import 'package:flutter/material.dart';

import '../../../models/home_layout.dart';
import '../home_icon_shape.dart';
import '../home_spec.dart';
import '../quick_targets.dart';

/// One tap to a screen or an action — an app icon, in launcher terms.
class QuickOpenSpec extends HomeWidgetSpec {
  const QuickOpenSpec();

  @override
  HomeWidgetKind get kind => HomeWidgetKind.quickOpen;

  @override
  String get title => 'Quick open';

  @override
  String get description => 'One tap to a screen or an action';

  @override
  IconData get icon => Icons.apps_outlined;

  @override
  Map<String, Object?> get initialConfig => const {'target': 'newChat'};

  @override
  List<HomeOption> options(HomeTile tile) => [
        HomePickOption(
          key: 'target',
          label: 'Opens',
          pick: HomePickKind.target,
          allowNone: false,
        ),
        const HomeChoiceOption(
          key: 'label',
          label: 'Label',
          choices: {'auto': 'Match layout', 'show': 'Show', 'hide': 'Hide'},
        ),
        const HomeTextOption(
          key: 'customLabel',
          label: 'Custom label',
          hint: 'Leave blank to use the default name',
        ),
      ];

  @override
  String describe(BuildContext context, HomeTile tile) {
    final target = QuickTarget.byName(tile.str('target'));
    return 'Quick open · ${quickTargetInfo(target).label}';
  }

  @override
  Widget build(BuildContext context, HomeTileContext tile) {
    final target = QuickTarget.byName(tile.tile.str('target'));
    final info = quickTargetInfo(target);
    final labelMode = tile.tile.str('label') ?? 'auto';
    final customLabel = tile.tile.str('customLabel');
    final showLabel = switch (labelMode) {
      'show' => true,
      'hide' => false,
      _ => tile.layout.showLabels,
    };
    final label = (customLabel != null && customLabel.trim().isNotEmpty)
        ? customLabel.trim()
        : info.label;

    void onTap() {
      if (tile.editing) return;
      openQuickTarget(context, target);
    }

    final isCompactIcon = tile.w <= 1 && tile.h <= 1;
    // A 1×2 or 2×1 shortcut stays an icon only when the user asked for no
    // label; otherwise the extra room becomes a card with its name.
    return Semantics(
      button: true,
      label: label,
      child: isCompactIcon
          ? _IconTile(
              studio: _isStudio(target),
              icon: info.icon,
              label: label,
              showLabel: showLabel,
              shape: tile.layout.iconShape,
              onTap: onTap,
            )
          : _ShortcutCard(
              studio: _isStudio(target),
              icon: info.icon,
              label: label,
              description: info.description,
              shape: tile.layout.iconShape,
              compact: tile.compact,
              onTap: onTap,
            ),
    );
  }
}

/// The Studio's shortcuts wear tertiary rather than primary, the same as
/// the Studio widget, so the agent harness reads as its own thing on the dock.
bool _isStudio(QuickTarget t) =>
    t == QuickTarget.studio || t == QuickTarget.newStudioSession;

/// The lone app-icon look: a shaped tile with the icon centred, label below.
class _IconTile extends StatefulWidget {
  const _IconTile({
    required this.studio,
    required this.icon,
    required this.label,
    required this.showLabel,
    required this.shape,
    required this.onTap,
  });

  final bool studio;
  final IconData icon;
  final String label;
  final bool showLabel;
  final HomeIconShape shape;
  final VoidCallback onTap;

  @override
  State<_IconTile> createState() => _IconTileState();
}

class _IconTileState extends State<_IconTile> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final labelRoom = widget.showLabel ? 20.0 : 0.0;
        final side = (constraints.maxWidth < constraints.maxHeight - labelRoom
                ? constraints.maxWidth
                : constraints.maxHeight - labelRoom)
            // A launcher icon: about 56 dp, whatever the cell.
            .clamp(24.0, 58.0);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapCancel: () => setState(() => _pressed = false),
          onTapUp: (_) => setState(() => _pressed = false),
          child: HomeShrink(
            size: constraints.biggest,
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedScale(
                  scale: _pressed ? 0.9 : 1.0,
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutBack,
                  child: HomeOutlined(
                    shape: homeIconBorder(widget.shape, side),
                    child: Container(
                      width: side,
                      height: side,
                      decoration: ShapeDecoration(
                        color: widget.studio
                            ? scheme.tertiaryContainer
                            : scheme.primaryContainer,
                        shape: homeIconBorder(widget.shape, side),
                      ),
                      child: Icon(
                        widget.icon,
                        size: side * 0.45,
                        color: widget.studio
                            ? scheme.onTertiaryContainer
                            : scheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                ),
                if (widget.showLabel) ...[
                  const SizedBox(height: 4),
                  Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Bigger spans: a card-style shortcut with icon, label and description.
class _ShortcutCard extends StatefulWidget {
  const _ShortcutCard({
    required this.studio,
    required this.icon,
    required this.label,
    required this.description,
    required this.shape,
    required this.compact,
    required this.onTap,
  });

  final bool studio;
  final IconData icon;
  final String label;
  final String description;
  final HomeIconShape shape;
  final bool compact;
  final VoidCallback onTap;

  @override
  State<_ShortcutCard> createState() => _ShortcutCardState();
}

class _ShortcutCardState extends State<_ShortcutCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AnimatedScale(
      scale: _pressed ? 0.97 : 1.0,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: HomeCard(
        onTap: widget.onTap,
        color: (widget.studio ? scheme.tertiaryContainer : scheme.primaryContainer)
            .withValues(alpha: 0.6),
        builder: (context, inner) {
          final labelStyle =
              theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600);
          final descStyle =
              theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
          final side = inner.height.clamp(20.0, 48.0);
          final tall = inner.height >= 96 && inner.width < inner.height * 1.6;
          final icon = Container(
            width: tall ? 52 : side,
            height: tall ? 52 : side,
            decoration: ShapeDecoration(
              color: widget.studio ? scheme.tertiary : scheme.primary,
              shape: homeIconBorder(widget.shape, tall ? 52 : side),
            ),
            child: Icon(widget.icon,
                size: (tall ? 52 : side) * 0.5,
                color: widget.studio ? scheme.onTertiary : scheme.onPrimary),
          );
          final showDesc = !widget.compact &&
              inner.height >=
                  homeLineHeight(context, labelStyle) +
                      homeLineHeight(context, descStyle) +
                      2;
          final words = Column(
            crossAxisAlignment:
                tall ? CrossAxisAlignment.center : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: labelStyle,
              ),
              if (showDesc) ...[
                const SizedBox(height: 2),
                Text(
                  widget.description,
                  maxLines: tall ? 2 : 1,
                  textAlign: tall ? TextAlign.center : TextAlign.start,
                  overflow: TextOverflow.ellipsis,
                  style: descStyle,
                ),
              ],
            ],
          );
          return Listener(
            onPointerDown: (_) => setState(() => _pressed = true),
            onPointerUp: (_) => setState(() => _pressed = false),
            onPointerCancel: (_) => setState(() => _pressed = false),
            child: tall
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [icon, const SizedBox(height: 10), words],
                  )
                : Row(
                    children: [
                      icon,
                      const SizedBox(width: 12),
                      Expanded(child: words),
                    ],
                  ),
          );
        },
      ),
    );
  }
}

