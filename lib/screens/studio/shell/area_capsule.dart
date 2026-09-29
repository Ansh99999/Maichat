import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// The three places a Studio session can show: the conversation, the draft and
/// its changes.
enum StudioArea {
  interface('Interface', Icons.forum_outlined),
  draft('Draft', Icons.edit_document),
  changes('Changes', Icons.history);

  const StudioArea(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// The capsule that sits above the composer and switches between the areas: a
/// pill with a filled indicator that springs to whichever area is chosen,
/// stretching toward its destination as it goes (Material 3 Expressive's
/// "shape morph" on a spring), rather than sliding at a constant pace.
class AreaCapsule extends StatefulWidget {
  const AreaCapsule({
    super.key,
    required this.area,
    required this.onChanged,
    this.changes = 0,
  });

  final StudioArea area;
  final ValueChanged<StudioArea> onChanged;

  /// How many changes the draft carries, shown beside "Changes".
  final int changes;

  @override
  State<AreaCapsule> createState() => _AreaCapsuleState();
}

class _AreaCapsuleState extends State<AreaCapsule>
    with SingleTickerProviderStateMixin {
  late final AnimationController _position = AnimationController.unbounded(
    vsync: this,
    value: widget.area.index.toDouble(),
  );

  static const SpringDescription _spring =
      SpringDescription(mass: 1, stiffness: 420, damping: 26);

  @override
  void didUpdateWidget(AreaCapsule old) {
    super.didUpdateWidget(old);
    if (old.area == widget.area) return;
    _position.animateWith(SpringSimulation(
      _spring,
      _position.value,
      widget.area.index.toDouble(),
      _position.velocity,
    ));
  }

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme.labelLarge;
    const count = 3;
    return Container(
      key: const Key('studio-area-capsule'),
      height: 52,
      padding: const EdgeInsets.all(4),
      // It floats over the page, so it carries its own lift — the page's text
      // runs on behind it and fades under the frost.
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final slot = constraints.maxWidth / count;
          return Stack(
            children: [
              // The indicator: its left edge and right edge follow the spring
              // at different rates, so it stretches toward where it is going
              // and pulls its tail in after — a pill that moves like a drop.
              AnimatedBuilder(
                animation: _position,
                builder: (context, _) {
                  final p = _position.value;
                  final v = _position.velocity;
                  final stretch = (v.abs() * 10).clamp(0.0, slot * 0.45);
                  var left = p * slot;
                  var right = left + slot;
                  if (v > 0) {
                    right += stretch;
                  } else if (v < 0) {
                    left -= stretch;
                  }
                  left = left.clamp(0.0, constraints.maxWidth);
                  right = right.clamp(0.0, constraints.maxWidth);
                  return Positioned(
                    left: left,
                    width: right - left,
                    top: 0,
                    bottom: 0,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(22),
                      ),
                    ),
                  );
                },
              ),
              Row(
                children: [
                  for (final area in StudioArea.values)
                    Expanded(
                      child: InkWell(
                        key: Key('studio-area-${area.name}'),
                        borderRadius: BorderRadius.circular(22),
                        onTap: () => widget.onChanged(area),
                        child: Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                area.icon,
                                size: 18,
                                color: area == widget.area
                                    ? scheme.onSecondaryContainer
                                    : scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  area == StudioArea.changes && widget.changes > 0
                                      ? '${area.label} ${widget.changes}'
                                      : area.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text?.copyWith(
                                    color: area == widget.area
                                        ? scheme.onSecondaryContainer
                                        : scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
