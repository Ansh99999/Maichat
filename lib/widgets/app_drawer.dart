import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/appearance.dart';
import '../services/discover/discover_sources.dart';
import '../services/update_service.dart';
import '../state/app_state.dart';
import '../screens/characters_screen.dart';
import '../screens/chats_screen.dart';
import '../screens/discover/discover_screen.dart';
import '../screens/library/library_screen.dart';
import '../screens/presets/presets_screen.dart';
import '../screens/section_screen.dart';
import '../screens/settings/about_settings_page.dart';
import '../screens/settings_screen.dart';

/// Which top-level destination is currently on screen, so the drawer can show
/// it selected.
enum DrawerSection { home, chats, characters, discover, library, presets }

/// The navigation drawer shared by the top-level sections (Home and Chats).
///
/// Follows the Material 3 navigation-drawer spec: a rounded sheet of
/// pill-shaped destinations up top (Home … Presets), and a quiet utility
/// row pinned to the bottom (settings, theme, notifications) with the app
/// version tucked beside it. Home is the landing section; the others push
/// their own detail screen.
///
/// Inside Discover the body changes job: instead of the app's sections it lists
/// the catalogues being browsed — Home to leave, then Chub, JannyAI, Character
/// Tavern and the rest. Pass [catalogues] to get that shape. The list outgrew
/// the row of chips it used to live in, and a catalogue behaves like a place you
/// go rather than a filter you apply.
class AppDrawer extends StatelessWidget {
  const AppDrawer({
    super.key,
    this.selected = DrawerSection.home,
    this.catalogues,
    this.selectedCatalogueId,
    this.onCatalogue,
  });

  /// The destination the host screen represents, drawn selected.
  final DrawerSection selected;

  /// The catalogues to list instead of the app's sections. Null everywhere but
  /// Discover.
  final List<DiscoverSource>? catalogues;

  /// Which catalogue is being browsed, drawn selected.
  final String? selectedCatalogueId;

  /// Called with a catalogue's id when one is picked.
  final void Function(String id)? onCatalogue;

  /// Closes the drawer, then pushes [screen] on top.
  void _go(BuildContext context, Widget screen) {
    Navigator.of(context).pop();
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  /// Returns to the landing Home screen (the first route).
  void _goHome(BuildContext context) {
    Navigator.of(context).pop();
    if (selected != DrawerSection.home) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  /// Opens the Chats list, unless it is already the host screen.
  void _goChats(BuildContext context) {
    Navigator.of(context).pop();
    if (selected != DrawerSection.chats) {
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => const ChatsScreen()));
    }
  }

  /// Opens the Characters roster, unless it is already the host screen.
  void _goCharacters(BuildContext context) {
    Navigator.of(context).pop();
    if (selected != DrawerSection.characters) {
      Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const CharactersScreen()));
    }
  }

  /// Opens Discover — the browser for other people's catalogues.
  void _goDiscover(BuildContext context) {
    Navigator.of(context).pop();
    if (selected != DrawerSection.discover) {
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => const DiscoverScreen()));
    }
  }

  /// Opens the Library, unless it is already the host screen.
  void _goLibrary(BuildContext context) {    Navigator.of(context).pop();
    if (selected != DrawerSection.library) {
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => const LibraryScreen()));
    }
  }

  /// Opens the Presets area, unless it is already the host screen.
  void _goPresets(BuildContext context) {
    Navigator.of(context).pop();
    if (selected != DrawerSection.presets) {
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => const PresetsScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sites = catalogues;
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 20, 16, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  sites == null ? 'MaiChat' : 'Discover',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            ),
            Expanded(
              child: sites == null
                  ? _sections(context)
                  : _catalogueList(context, sites),
            ),
            const Divider(height: 1),
            _DrawerFooter(onNavigate: _go),
          ],
        ),
      ),
    );
  }

  /// The catalogue picker: Home to leave Discover, then one entry per site.
  Widget _catalogueList(BuildContext context, List<DiscoverSource> sites) {
    final current = selectedCatalogueId;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      children: [
        _NavItem(
          icon: Icons.home_outlined,
          label: 'Home',
          onTap: () => _goHome(context),
        ),
        const Divider(height: 12, indent: 16, endIndent: 16),
        for (final site in sites)
          _NavItem(
            icon: site.id == current ? Icons.public : Icons.public_outlined,
            label: site.label,
            selected: site.id == current,
            onTap: () {
              Navigator.of(context).pop();
              onCatalogue?.call(site.id);
            },
          ),
      ],
    );
  }

  Widget _sections(BuildContext context) => ListView(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          _NavItem(
            icon: Icons.home_outlined,
            label: 'Home',
            selected: selected == DrawerSection.home,
            onTap: () => _goHome(context),
          ),
          _NavItem(
            icon: Icons.people_alt_outlined,
            label: 'Characters',
            selected: selected == DrawerSection.characters,
            onTap: () => _goCharacters(context),
          ),
          _NavItem(
            icon: Icons.public_outlined,
            label: 'Discover',
            selected: selected == DrawerSection.discover,
            onTap: () => _goDiscover(context),
          ),
          _NavItem(
            icon: Icons.chat_bubble_outline,
            label: 'Chats',
            selected: selected == DrawerSection.chats,
            onTap: () => _goChats(context),
          ),
          _NavItem(
            icon: Icons.local_library_outlined,
            label: 'Library',
            selected: selected == DrawerSection.library,
            onTap: () => _goLibrary(context),
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
            selected: selected == DrawerSection.presets,
            onTap: () => _goPresets(context),
          ),
        ],
      );
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
    final isDark = mode.isDark ||
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
          if (state.availableUpdate != null)
            IconButton(
              tooltip: 'Update available',
              icon: Icon(Icons.system_update, color: scheme.primary),
              onPressed: () => _showUpdate(context, state.availableUpdate!),
            ),
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

  /// A little dialog describing the newer release, with a button that opens the
  /// APK download (or the release page) in the browser so the user can install.
  Future<void> _showUpdate(BuildContext context, UpdateInfo update) async {
    final notes = update.notes.trim();
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Update available'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Version ${update.version} is available '
                '(you have ${AboutSettingsPage.version}).'),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: SingleChildScrollView(
                  child: Text(
                    notes,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Update'),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return;
    final uri = Uri.tryParse(update.downloadUrl);
    final ok = uri != null &&
        await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open ${update.downloadUrl}')),
      );
    }
  }
}
