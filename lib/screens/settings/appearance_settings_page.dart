import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/appearance.dart';
import '../../state/app_state.dart';
import '../../widgets/color_picker.dart';
import '../../widgets/font_picker_row.dart';
import 'setting_anchors.dart';
import 'setting_highlight.dart';

/// How the app colours itself: light/dark mode and whether to borrow the
/// system's Material You palette. Kept deliberately compact — each of the three
/// choices (system colours, theme, theme colour) is a single tight row.
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
          // System colours — one compact switch row.
          SettingHighlight(
            active: highlight == SettingAnchor.systemColours,
            child: SwitchListTile(
              dense: true,
              value: appearance.dynamicColor,
              onChanged: (value) => state.updateAppearance(
                appearance.copyWith(dynamicColor: value),
              ),
              secondary: const Icon(Icons.palette_outlined),
              title: const Text('Use system colours'),
              subtitle: const Text('Follow the wallpaper palette (Android 12+)'),
            ),
          ),
          // Theme mode — label + segmented control on one row.
          SettingHighlight(
            active: highlight == SettingAnchor.theme,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  const Icon(Icons.brightness_6_outlined),
                  const SizedBox(width: 16),
                  const Expanded(child: Text('Theme')),
                  _ThemeModeSelector(
                    mode: appearance.mode,
                    onChanged: (mode) => state.updateAppearance(
                      appearance.copyWith(mode: mode),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Theme colour — a swatch that opens the palette; dimmed while the
          // system palette is in charge.
          _ThemeColourRow(
            appearance: appearance,
            onChanged: (color) => state.updateAppearance(
              appearance.copyWith(seedColor: color.toARGB32()),
            ),
          ),
          // App font — a Google Fonts family applied across the whole app.
          SettingHighlight(
            active: highlight == SettingAnchor.font,
            child: FontPickerRow(
              title: 'App font',
              fontFamily: appearance.fontFamily,
              onChanged: (family) => state.updateAppearance(
                appearance.copyWith(fontFamily: family),
              ),
            ),
          ),
          const Divider(height: 24),
          // A diagnostic, not a preference (so it is not persisted): overlays two
          // frame-time graphs — UI thread on top, raster/GPU thread below. A bar
          // over the green line is a dropped frame. Use it to see *which* thread
          // is slow when something stutters.
          SwitchListTile(
            dense: true,
            value: state.perfOverlay,
            onChanged: (_) => state.togglePerfOverlay(),
            secondary: const Icon(Icons.speed_outlined),
            title: const Text('Show performance overlay'),
            subtitle: const Text(
                'Frame-time graphs for diagnosing stutter — top is UI, bottom '
                'is the GPU'),
          ),
        ],
      ),
    );
  }
}

/// The System / Light / Dark / AMOLED picker. A dropdown keeps four options
/// tidy on the row without the width a four-segment button would demand.
class _ThemeModeSelector extends StatelessWidget {
  const _ThemeModeSelector({required this.mode, required this.onChanged});

  final AppThemeMode mode;
  final ValueChanged<AppThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<AppThemeMode>(
        value: mode,
        borderRadius: BorderRadius.circular(12),
        onChanged: (next) {
          if (next != null) onChanged(next);
        },
        items: [
          for (final m in AppThemeMode.values)
            DropdownMenuItem<AppThemeMode>(
              value: m,
              child: Text(m.label),
            ),
        ],
      ),
    );
  }
}

/// A single row showing the current seed colour as a swatch; tapping it opens
/// the palette in a sheet. Disabled (and explained) while system colours win.
class _ThemeColourRow extends StatelessWidget {
  const _ThemeColourRow({required this.appearance, required this.onChanged});

  final Appearance appearance;
  final ValueChanged<Color> onChanged;

  Future<void> _openPalette(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: 16 + MediaQuery.paddingOf(sheetContext).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Theme colour',
                style: Theme.of(sheetContext).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Pick a colour to build the light and dark theme, or tap the last '
              'swatch for a custom one.',
              style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(
                    color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            ThemeColorPicker(
              value: Color(appearance.seedColor),
              enabled: true,
              onChanged: (color) {
                onChanged(color);
                Navigator.of(sheetContext).pop();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabled = !appearance.dynamicColor;
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      enabled: enabled,
      leading: const Icon(Icons.color_lens_outlined),
      title: const Text('Theme colour'),
      subtitle: Text(
        enabled ? 'Base colour for the theme' : 'Turn off system colours to set',
      ),
      trailing: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: Color(appearance.seedColor)
              .withValues(alpha: enabled ? 1 : 0.4),
          shape: BoxShape.circle,
          border: Border.all(color: scheme.outlineVariant),
        ),
      ),
      onTap: enabled ? () => _openPalette(context) : null,
    );
  }
}
