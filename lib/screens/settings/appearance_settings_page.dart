import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/appearance.dart';
import '../../state/app_state.dart';
import '../../widgets/color_picker.dart';
import 'setting_anchors.dart';
import 'setting_highlight.dart';

/// How the app colours itself: light/dark mode and whether to borrow the
/// system's Material You palette.
class AppearanceSettingsPage extends StatelessWidget {
  const AppearanceSettingsPage({super.key, this.highlight});

  final SettingAnchor? highlight;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final appearance = state.appearance;
    return Scaffold(
      appBar: AppBar(title: const Text('Appearance')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          8,
          8,
          8,
          16 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          SettingHighlight(
            active: highlight == SettingAnchor.systemColours,
            child: SwitchListTile(
              value: appearance.dynamicColor,
              onChanged: (value) => state.updateAppearance(
                appearance.copyWith(dynamicColor: value),
              ),
              secondary: const Icon(Icons.palette_outlined),
              title: const Text('Use system colours'),
              subtitle: const Text(
                'Follow the wallpaper palette on Android 12 and up. Off, or '
                'where the system has no palette, MaiChat uses its own purple.',
              ),
            ),
          ),
          const Divider(height: 8),
          SettingHighlight(
            active: highlight == SettingAnchor.theme,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.brightness_6_outlined),
                      const SizedBox(width: 16),
                      Text(
                        'Theme',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SegmentedButton<AppThemeMode>(
                    segments: [
                      for (final mode in AppThemeMode.values)
                        ButtonSegment<AppThemeMode>(
                          value: mode,
                          label: Text(mode.label),
                        ),
                    ],
                    selected: <AppThemeMode>{appearance.mode},
                    showSelectedIcon: false,
                    onSelectionChanged: (selection) => state.updateAppearance(
                      appearance.copyWith(mode: selection.first),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.color_lens_outlined),
                    const SizedBox(width: 16),
                    Text(
                      'Theme colour',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  appearance.dynamicColor
                      ? 'Turn off system colours to build a theme from your '
                          'own colour.'
                      : 'Pick a colour to generate the light and dark theme, '
                          'or tap the last swatch for a custom colour.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 16),
                ThemeColorPicker(
                  value: Color(appearance.seedColor),
                  enabled: !appearance.dynamicColor,
                  onChanged: (color) => state.updateAppearance(
                    appearance.copyWith(seedColor: color.toARGB32()),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
