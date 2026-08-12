import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../models/appearance.dart';
import '../../state/app_state.dart';
import '../../widgets/color_picker.dart';
import '../presets/preset_pickers.dart';
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
            child: _FontRow(
              fontFamily: appearance.fontFamily,
              onChanged: (family) => state.updateAppearance(
                appearance.copyWith(fontFamily: family),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A single row showing the current app font; tapping it opens a searchable
/// picker of every Google Fonts family. Choosing "System default" clears it.
class _FontRow extends StatelessWidget {
  const _FontRow({required this.fontFamily, required this.onChanged});

  final String? fontFamily;

  /// Called with the chosen family, or null for the system default.
  final ValueChanged<String?> onChanged;

  static const String _systemId = '__system__';

  Future<void> _pick(BuildContext context) async {
    final families = GoogleFonts.asMap().keys.toList()..sort();
    final chosen = await showSearchPicker(
      context: context,
      title: 'App font',
      entries: [
        const PickerEntry(
          id: _systemId,
          title: 'System default',
          subtitle: 'Platform font',
        ),
        for (final f in families) PickerEntry(id: f, title: f),
      ],
      selectedId: fontFamily ?? _systemId,
      allowCustom: true,
    );
    if (chosen == null) return;
    onChanged(chosen == _systemId || chosen.trim().isEmpty ? null : chosen.trim());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final family = fontFamily;
    // Preview the chosen font on its own name where possible.
    TextStyle? preview;
    if (family != null) {
      try {
        preview = GoogleFonts.getFont(family);
      } catch (_) {
        preview = null;
      }
    }
    return ListTile(
      leading: const Icon(Icons.font_download_outlined),
      title: const Text('App font'),
      subtitle: Text(
        family ?? 'System default',
        style: preview,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (family != null)
            IconButton(
              tooltip: 'Use system font',
              icon: const Icon(Icons.close),
              onPressed: () => onChanged(null),
            ),
          Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
        ],
      ),
      onTap: () => _pick(context),
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
