import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/view_prefs.dart';
import '../../state/app_state.dart';
import 'setting_anchors.dart';
import 'setting_highlight.dart';

/// Controls how image-heavy browse screens lay out their cards. Each section is
/// independent, and the fixed legacy layout remains the default.
class BrowseAppearanceSettingsPage extends StatelessWidget {
  const BrowseAppearanceSettingsPage({super.key, this.highlight});

  final SettingAnchor? highlight;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Browse appearance')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          8,
          8,
          8,
          16 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(
              'Free-size cards keep each picture’s natural shape. Wide artwork '
              'may span two spaces; other artwork packs around it in order.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          _FreeSizeSwitch(
            title: 'Characters',
            subtitle: 'Natural-size cards in the character grid',
            icon: Icons.people_outline,
            section: BrowseSection.characters,
            active: highlight == SettingAnchor.charactersFreeSize,
            state: state,
          ),
          SettingHighlight(
            active: highlight == SettingAnchor.characterImageOverlay,
            child: Padding(
              padding: const EdgeInsets.only(left: 40),
              child: SwitchListTile(
                dense: true,
                value: state.characterImageOverlay,
                onChanged: state.freeSizeCards(BrowseSection.characters)
                    ? state.setCharacterImageOverlay
                    : null,
                secondary: const Icon(Icons.gradient_outlined),
                title: const Text('Labels over artwork'),
                subtitle: const Text(
                  'Vignette, title, actions and swipeable avatars on the picture',
                ),
              ),
            ),
          ),
          _FreeSizeSwitch(
            title: 'Gallery',
            subtitle: 'Natural-size pictures at every zoom level',
            icon: Icons.photo_library_outlined,
            section: BrowseSection.gallery,
            active: highlight == SettingAnchor.galleryFreeSize,
            state: state,
          ),
          _FreeSizeSwitch(
            title: 'Discover',
            subtitle: 'Natural-size cards in character results',
            icon: Icons.explore_outlined,
            section: BrowseSection.discover,
            active: highlight == SettingAnchor.discoverFreeSize,
            state: state,
          ),
        ],
      ),
    );
  }
}

class _FreeSizeSwitch extends StatelessWidget {
  const _FreeSizeSwitch({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.section,
    required this.active,
    required this.state,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final String section;
  final bool active;
  final AppState state;

  @override
  Widget build(BuildContext context) => SettingHighlight(
    active: active,
    child: SwitchListTile(
      dense: true,
      value: state.freeSizeCards(section),
      onChanged: (enabled) => state.setFreeSizeCards(section, enabled),
      secondary: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
    ),
  );
}
