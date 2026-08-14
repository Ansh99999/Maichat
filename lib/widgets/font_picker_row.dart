import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../screens/presets/preset_pickers.dart';

/// A settings row that shows the currently chosen Google Fonts family and opens
/// a searchable picker of every family when tapped. "System default" clears the
/// choice, and the current family previews itself in the subtitle.
///
/// Shared by the app-wide font row and the per-role sender-name rows, so every
/// font choice in the app is picked the same way.
class FontPickerRow extends StatelessWidget {
  const FontPickerRow({
    super.key,
    required this.title,
    required this.fontFamily,
    required this.onChanged,
    this.pickerTitle,
    this.icon = Icons.font_download_outlined,
    this.systemLabel = 'System default',
    this.systemSubtitle = 'Platform font',
    this.dense = false,
  });

  final String title;

  /// The chosen family, or null for the inherited/system font.
  final String? fontFamily;

  /// Called with the chosen family, or null for the default.
  final ValueChanged<String?> onChanged;

  /// Heading for the picker sheet; defaults to [title].
  final String? pickerTitle;

  final IconData icon;

  /// Label and blurb for the "no explicit font" entry — "System default" app
  /// wide, "Same as app font" for a single element.
  final String systemLabel;
  final String systemSubtitle;

  final bool dense;

  static const String _systemId = '__system__';

  Future<void> _pick(BuildContext context) async {
    final families = GoogleFonts.asMap().keys.toList()..sort();
    final chosen = await showSearchPicker(
      context: context,
      title: pickerTitle ?? title,
      entries: [
        PickerEntry(
          id: _systemId,
          title: systemLabel,
          subtitle: systemSubtitle,
        ),
        for (final f in families) PickerEntry(id: f, title: f),
      ],
      selectedId: fontFamily ?? _systemId,
      allowCustom: true,
    );
    if (chosen == null) return;
    onChanged(
        chosen == _systemId || chosen.trim().isEmpty ? null : chosen.trim());
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
      dense: dense,
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(family ?? systemLabel, style: preview),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (family != null)
            IconButton(
              tooltip: 'Use the default font',
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
