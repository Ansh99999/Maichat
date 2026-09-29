import 'package:flutter/material.dart';

/// The capsule the composer's ⋯ raises above it: the composer's own actions,
/// on a pill rather than in a menu.
///
/// Two actions — add a picture, and show (or hide) the other areas. Adding a
/// picture slides the pill over to where it comes from (the gallery or the
/// device) and back; nothing fades.
class ActionsCapsule extends StatefulWidget {
  const ActionsCapsule({
    super.key,
    required this.areasShown,
    required this.onToggleAreas,
    required this.onGallery,
    required this.onDevice,
  });

  /// Whether the Interface | Draft | Changes capsule is on, which the areas
  /// action shows by being filled.
  final bool areasShown;
  final VoidCallback onToggleAreas;
  final VoidCallback onGallery;
  final VoidCallback onDevice;

  @override
  State<ActionsCapsule> createState() => _ActionsCapsuleState();
}

class _ActionsCapsuleState extends State<ActionsCapsule> {
  bool _picking = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final main = Row(
      key: const ValueKey('actions-main'),
      children: [
        Expanded(
          child: _Action(
            key: const Key('studio-action-image'),
            icon: Icons.add_photo_alternate_outlined,
            label: 'Image',
            onTap: () => setState(() => _picking = true),
          ),
        ),
        Expanded(
          child: _Action(
            key: const Key('studio-toggle-areas'),
            icon: widget.areasShown
                ? Icons.view_carousel
                : Icons.view_carousel_outlined,
            label: 'Other areas',
            selected: widget.areasShown,
            onTap: widget.onToggleAreas,
          ),
        ),
      ],
    );
    final picking = Row(
      key: const ValueKey('actions-picking'),
      children: [
        IconButton(
          key: const Key('studio-action-back'),
          tooltip: 'Back',
          visualDensity: VisualDensity.compact,
          onPressed: () => setState(() => _picking = false),
          icon: const Icon(Icons.arrow_back),
        ),
        Expanded(
          child: _Action(
            key: const Key('studio-attach-gallery'),
            icon: Icons.photo_library_outlined,
            label: 'Gallery',
            onTap: widget.onGallery,
          ),
        ),
        Expanded(
          child: _Action(
            key: const Key('studio-attach-device'),
            icon: Icons.smartphone_outlined,
            label: 'Device',
            onTap: widget.onDevice,
          ),
        ),
      ],
    );
    return Container(
      key: const Key('studio-actions-capsule'),
      height: 52,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(26),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          switchInCurve: Easing.emphasizedDecelerate,
          switchOutCurve: Easing.emphasizedAccelerate,
          transitionBuilder: (child, animation) {
            final incoming = child.key == ValueKey(_picking ? 'actions-picking' : 'actions-main');
            // Choosing where a picture comes from slides in from the right;
            // going back slides the actions in from the left.
            final from = _picking ? 1.0 : -1.0;
            return SlideTransition(
              position: Tween<Offset>(
                begin: Offset(incoming ? from : -from, 0),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            );
          },
          child: _picking ? picking : main,
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 20, color: fg),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(color: fg),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
