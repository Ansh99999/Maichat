import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/appearance.dart';
import '../state/app_state.dart';
import '../screens/section_screen.dart';
import '../screens/settings/about_settings_page.dart';
import '../screens/settings_screen.dart';

/// The navigation drawer behind the home screen's hamburger.
///
/// Follows the Material 3 navigation-drawer spec: a rounded sheet of
/// pill-shaped destinations up top (Profile … Presets), and a quiet utility
/// row pinned to the bottom (settings, theme, notifications) with the app
/// version tucked beside it. Destinations push their own detail screen; the
/// current one — Chats, i.e. this home hub — is shown selected.
class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});

  void _go(BuildContext context, Widget screen) {
    Navigator.of(context).pop(); // close the drawer first
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
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
                  'MaiChat',
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
                    icon: Icons.person_outline,
                    label: 'Profile',
                    onTap: () => _go(context,
                        const SectionScreen(title: 'Profile', icon: Icons.person_outline)),
                  ),
                  _NavItem(
                    icon: Icons.people_alt_outlined,
                    label: 'Characters',
                    onTap: () => _go(
                        context,
                        const SectionScreen(
                            title: 'Characters', icon: Icons.people_alt_outlined)),
                  ),
                  _NavItem(
                    icon: Icons.chat_bubble_outline,
                    label: 'Chats',
                    selected: true,
                    onTap: () => Navigator.of(context).pop(), // already home
                  ),
                  _NavItem(
                    icon: Icons.local_library_outlined,
                    label: 'Library',
                    onTap: () => _go(
                        context,
                        const SectionScreen(
                            title: 'Library', icon: Icons.local_library_outlined)),
                  ),
                  _NavItem(
                    icon: Icons.photo_library_outlined,
                    label: 'Gallery',
                    onTap: () => _go(
                        context,
                        const SectionScreen(
                            title: 'Gallery', icon: Icons.photo_library_outlined)),
                  ),
                  _NavItem(
                    icon: Icons.tune_outlined,
                    label: 'Presets',
                    onTap: () => _go(context,
                        const SectionScreen(title: 'Presets', icon: Icons.tune_outlined)),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            _DrawerFooter(onNavigate: _go),
          ],
        ),
      ),
    );
  }
}

/// A single rounded, pill-shaped destination in the drawer body.
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
            color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant),
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

/// The utility strip pinned to the bottom-left of the drawer: icon-only
/// shortcuts for settings, light/dark mode and notifications, with the app
/// version sitting quietly on the right.
class _DrawerFooter extends StatelessWidget {
  const _DrawerFooter({required this.onNavigate});

  final void Function(BuildContext, Widget) onNavigate;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;

    // Resolve what "dark" means right now so the toggle can flip to the
    // opposite explicit mode, even when currently following the system.
    final mode = state.appearance.mode;
    final isDark = mode == AppThemeMode.dark ||
        (mode == AppThemeMode.system &&
            MediaQuery.platformBrightnessOf(context) == Brightness.dark);

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 16, 6),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => onNavigate(context, const SettingsScreen()),
          ),
          IconButton(
            tooltip: isDark ? 'Switch to light mode' : 'Switch to dark mode',
            icon: Icon(isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
            onPressed: () => state.updateAppearance(
              state.appearance.copyWith(
                mode: isDark ? AppThemeMode.light : AppThemeMode.dark,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Notifications',
            icon: const Icon(Icons.notifications_outlined),
            onPressed: () => onNavigate(
              context,
              const SectionScreen(
                  title: 'Notifications', icon: Icons.notifications_outlined),
            ),
          ),
          const Spacer(),
          Text(
            'v${AboutSettingsPage.version}',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}
