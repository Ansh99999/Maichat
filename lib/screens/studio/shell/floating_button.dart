import 'package:flutter/material.dart';

import 'studio_chrome.dart';

/// One of the soft squares the Studio floats over its pages in place of an app
/// bar — the menu at the top left, the sub-agents button at the top right — in
/// the same shape the chat floats its own menu in: 48 dp, a corner that reads
/// as soft rather than as a box or a circle, a light shadow.
///
/// The fill is a plain colour, deliberately not a frosted `BackdropFilter`: a
/// button that is always on screen would re-run that blur on every frame of
/// every scroll, which is the cost the chat's own menu button was cured of.
class StudioFloatingButton extends StatelessWidget {
  const StudioFloatingButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.badge,
  });

  final Widget icon;
  final String tooltip;
  final VoidCallback onPressed;

  /// Drawn in the selected colours (the sub-agents panel is open).
  final bool selected;

  /// A small count in the corner, when there is one to show.
  final String? badge;

  static const double _radius = 15;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onSecondaryContainer : scheme.onSurface;
    return SizedBox.square(
      dimension: StudioChrome.buttonSize,
      child: Material(
        color: selected ? scheme.secondaryContainer : scheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(_radius)),
        ),
        elevation: 2,
        shadowColor: Colors.black.withValues(alpha: 0.3),
        child: IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          icon: Badge(
            isLabelVisible: badge != null,
            label: badge == null ? null : Text(badge!),
            child: IconTheme.merge(
              data: IconThemeData(color: fg),
              child: icon,
            ),
          ),
        ),
      ),
    );
  }
}
