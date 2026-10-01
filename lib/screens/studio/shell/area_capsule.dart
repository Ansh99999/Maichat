import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// The places a Studio session can show: the conversation, the draft, the
/// Playground (the draft played as a chat) and the draft's changes.
enum StudioArea {
  interface('Interface', Icons.forum_outlined),
  draft('Draft', Icons.edit_document),
  playground('Playground', Icons.sports_esports_outlined),
  changes('Changes', Icons.history);

  const StudioArea(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// The capsule that sits above the composer and switches between the areas: a
/// pill with a filled indicator that springs to whichever area is chosen,
/// stretching toward its destination as it goes (Material 3 Expressive's
/// "shape morph" on a spring), rather than sliding at a constant pace.
///
/// When every label does not fit side by side (four areas on a phone), the
/// chosen area's slot grows to hold its label and the others give way to
/// their icons — the slots' widths ride the same spring as the indicator, so
/// the label is carried open rather than swapped in.
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

  /// What each label needs beside its icon, measured once per text style.
  final Map<String, double> _labelWidth = <String, double>{};
  TextStyle? _measuredWith;

  double _need(StudioArea area, String label, TextStyle? style) {
    if (_measuredWith != style) {
      _labelWidth.clear();
      _measuredWith = style;
    }
    return _labelWidth.putIfAbsent(label, () {
      final painter = TextPainter(
        text: TextSpan(text: label, style: style),
        maxLines: 1,
        textDirection: TextDirection.ltr,
      )..layout();
      final w = painter.width;
      painter.dispose();
      // Icon, gap, and a little air on each side.
      return 18 + 6 + w + 20;
    });
  }

  String _label(StudioArea area) =>
      area == StudioArea.changes && widget.changes > 0
          ? '${area.label} ${widget.changes}'
          : area.label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme.labelLarge;
    const areas = StudioArea.values;
    final count = areas.length;
    return Container(
      key: const Key('studio-area-capsule'),
      height: 52,
      padding: const EdgeInsets.all(4),
      // It floats over the page on the frost behind it; a shadow would be cut
      // off by the reveal's clip, and the tonal fill is lift enough.
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(26),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final needs = [for (final a in areas) _need(a, _label(a), text)];
          final widest = needs.reduce((a, b) => a > b ? a : b);
          // How much the chosen slot grows (as a share of a plain slot) so the
          // widest label fits in it — but never past leaving every other slot
          // room for its icon. None when every label fits as it is.
          const iconSlot = 44.0;
          var grow = 0.0;
          if (widest * count > width) {
            final chosen = widest.clamp(0.0, width - (count - 1) * iconSlot);
            final others = (width - chosen) / (count - 1);
            grow = others <= 0 ? 0.0 : (chosen / others - 1).clamp(0.0, 6.0);
          }
          return AnimatedBuilder(
            animation: _position,
            builder: (context, _) {
              final p = _position.value;
              final weights = [
                for (var i = 0; i < count; i++)
                  1 + grow * (1 - (p - i).abs()).clamp(0.0, 1.0),
              ];
              final unit = width / weights.fold<double>(0, (a, b) => a + b);
              final slots = [for (final w in weights) w * unit];
              final lefts = <double>[0];
              for (var i = 0; i < count - 1; i++) {
                lefts.add(lefts[i] + slots[i]);
              }
              // The indicator: its left edge and right edge follow the spring
              // at different rates, so it stretches toward where it is going
              // and pulls its tail in after — a pill that moves like a drop.
              final f = p.floor().clamp(0, count - 1);
              final next = (f + 1).clamp(0, count - 1);
              final frac = (p - f).clamp(0.0, 1.0);
              final v = _position.velocity;
              final stretch = (v.abs() * 10).clamp(0.0, unit * 0.45);
              var left = lefts[f] + frac * slots[f];
              var right = left + slots[f] * (1 - frac) + slots[next] * frac;
              if (v > 0) {
                right += stretch;
              } else if (v < 0) {
                left -= stretch;
              }
              left = left.clamp(0.0, width);
              right = right.clamp(0.0, width);
              return Stack(
                children: [
                  Positioned(
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
                  ),
                  Row(
                    children: [
                      for (var i = 0; i < count; i++)
                        SizedBox(
                          width: slots[i],
                          child: _Slot(
                            area: areas[i],
                            label: _label(areas[i]),
                            // The chosen area is always named (cut short only
                            // where even the grown slot cannot hold it); the
                            // others only when they fit whole.
                            showLabel: areas[i] == widget.area ||
                                slots[i] >= needs[i],
                            selected: areas[i] == widget.area,
                            style: text,
                            onTap: () => widget.onChanged(areas[i]),
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// One area in the capsule: its icon, and its label when there is room.
class _Slot extends StatelessWidget {
  const _Slot({
    required this.area,
    required this.label,
    required this.showLabel,
    required this.selected,
    required this.style,
    required this.onTap,
  });

  final StudioArea area;
  final String label;
  final bool showLabel;
  final bool selected;
  final TextStyle? style;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color =
        selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      label: area.label,
      excludeSemantics: true,
      child: _maybeTooltip(
        showLabel ? null : area.label,
        InkWell(
          key: Key('studio-area-${area.name}'),
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: ClipRect(
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(area.icon, size: 18, color: color),
                  if (showLabel) ...[
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: style?.copyWith(color: color),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static Widget _maybeTooltip(String? message, Widget child) =>
      message == null ? child : Tooltip(message: message, child: child);
}
