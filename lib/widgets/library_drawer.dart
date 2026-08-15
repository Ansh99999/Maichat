import 'package:flutter/material.dart';

import '../screens/library/lorebooks_screen.dart';
import '../screens/section_screen.dart';

/// Which Library destination is currently on screen, so the drawer can show it
/// selected.
enum LibrarySection { home, lorebooks, scenarios, embeddings }

/// The navigation drawer for the Library area (lorebooks, scenarios,
/// embeddings).
///
/// The Library is a world of its own — three sibling collections that are only
/// ever reached from each other — so it carries its own drawer rather than
/// crowding the main app drawer with three more top-level entries. The styling is
/// deliberately identical to the main drawer's, so moving between the two never
/// feels like leaving the app: same rounded destinations, same selected tint,
/// with Home as the way back out to the landing screen.
class LibraryDrawer extends StatelessWidget {
  const LibraryDrawer({super.key, required this.selected});

  /// The destination the host screen represents, drawn selected.
  final LibrarySection selected;

  /// Returns to the landing Home screen (the first route).
  void _goHome(BuildContext context) {
    Navigator.of(context).pop();
    if (selected != LibrarySection.home) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  /// Closes the drawer, then pushes [screen] unless it is already the host.
  void _go(BuildContext context, LibrarySection section, Widget screen) {
    Navigator.of(context).pop();
    if (selected != section) {
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => screen));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 20, 16, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Library',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  _NavItem(
                    icon: Icons.home_outlined,
                    label: 'Home',
                    selected: selected == LibrarySection.home,
                    onTap: () => _goHome(context),
                  ),
                  _NavItem(
                    icon: Icons.auto_stories_outlined,
                    label: 'Lorebooks',
                    selected: selected == LibrarySection.lorebooks,
                    onTap: () => _go(context, LibrarySection.lorebooks,
                        const LorebooksScreen()),
                  ),
                  _NavItem(
                    icon: Icons.theater_comedy_outlined,
                    label: 'Scenarios',
                    selected: selected == LibrarySection.scenarios,
                    onTap: () => _go(
                      context,
                      LibrarySection.scenarios,
                      const SectionScreen(
                        title: 'Scenarios',
                        icon: Icons.theater_comedy_outlined,
                      ),
                    ),
                  ),
                  _NavItem(
                    icon: Icons.hub_outlined,
                    label: 'Embeddings',
                    selected: selected == LibrarySection.embeddings,
                    onTap: () => _go(
                      context,
                      LibrarySection.embeddings,
                      const SectionScreen(
                        title: 'Embeddings',
                        icon: Icons.hub_outlined,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A single rounded, pill-shaped destination in the drawer body — the same
/// widget the main app drawer uses, kept private to each drawer so neither can
/// drift the other's styling.
class _NavItem extends StatelessWidget {
  const _NavItem({
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
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ListTile(
        leading: Icon(icon,
            color:
                selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant),
        title: Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: selected ? scheme.onSecondaryContainer : scheme.onSurface,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
        ),
        selected: selected,
        selectedTileColor: scheme.secondaryContainer,
        shape: const StadiumBorder(),
        onTap: onTap,
      ),
    );
  }
}
