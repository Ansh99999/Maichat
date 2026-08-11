import 'package:flutter/material.dart';

/// Curated one-tap theme seeds. Each generates a full Material 3 scheme via
/// [ColorScheme.fromSeed], so these are starting points rather than exact
/// surface colours.
const List<Color> kThemeSwatches = <Color>[
  Color(0xFF7C5CFF), // MaiChat purple (default)
  Color(0xFF3B82F6), // blue
  Color(0xFF06B6D4), // cyan
  Color(0xFF10B981), // green
  Color(0xFF84CC16), // lime
  Color(0xFFF59E0B), // amber
  Color(0xFFF97316), // orange
  Color(0xFFEF4444), // red
  Color(0xFFEC4899), // pink
  Color(0xFFA855F7), // violet
  Color(0xFF64748B), // slate
  Color(0xFF111827), // near-black
];

/// A grid of preset seed swatches plus a "Custom" entry that opens the HSV
/// picker. [value] is the currently selected seed; [onChanged] fires with the
/// new ARGB colour whenever the user picks one.
class ThemeColorPicker extends StatelessWidget {
  const ThemeColorPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final Color value;
  final ValueChanged<Color> onChanged;
  final bool enabled;

  bool _matches(Color a, Color b) => a.toARGB32() == b.toARGB32();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final custom = !kThemeSwatches.any((c) => _matches(c, value));
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final swatch in kThemeSwatches)
            _Swatch(
              color: swatch,
              selected: _matches(swatch, value),
              onTap: enabled ? () => onChanged(swatch) : null,
            ),
          // Custom colour: shows the current colour when it is off-palette,
          // otherwise a neutral "+" chip. Tapping opens the HSV dialog.
          _Swatch(
            color: custom ? value : scheme.surfaceContainerHighest,
            selected: custom,
            icon: Icons.tune,
            onTap: enabled
                ? () async {
                    final picked = await showCustomColorDialog(context, value);
                    if (picked != null) onChanged(picked);
                  }
                : null,
          ),
        ],
      ),
    );
  }
}

/// A single tappable colour circle: a ring + check when selected, an optional
/// glyph (used by the "custom" entry).
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.selected,
    this.onTap,
    this.icon,
  });

  final Color color;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Pick a glyph colour that stays legible on the swatch.
    final onColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
            ? Colors.white
            : Colors.black;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 3 : 1,
            ),
          ),
          child: icon != null && !selected
              ? Icon(icon, size: 20, color: onColor)
              : selected
                  ? Icon(Icons.check, size: 22, color: onColor)
                  : null,
        ),
      ),
    );
  }
}

/// Opens the HSV picker seeded with [initial]. Resolves to the chosen colour,
/// or null if dismissed.
Future<Color?> showCustomColorDialog(BuildContext context, Color initial) {
  return showDialog<Color>(
    context: context,
    builder: (_) => _CustomColorDialog(initial: initial),
  );
}

/// Parses `#RRGGBB`, `RRGGBB`, or an 8-digit `AARRGGBB` string into a colour.
/// Returns null when the text is not a valid hex colour.
Color? parseHexColor(String input) {
  var hex = input.trim();
  if (hex.startsWith('#')) hex = hex.substring(1);
  if (hex.length == 6) hex = 'FF$hex';
  if (hex.length != 8) return null;
  final value = int.tryParse(hex, radix: 16);
  return value == null ? null : Color(value);
}

/// The opaque `#RRGGBB` form of [color], upper-case, ready for a hex field.
String hexOf(Color color) {
  final rgb = color.toARGB32() & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

/// A full HSV picker: hue / saturation / brightness gradient sliders kept in
/// sync with a hex text field and a live preview.
class _CustomColorDialog extends StatefulWidget {
  const _CustomColorDialog({required this.initial});

  final Color initial;

  @override
  State<_CustomColorDialog> createState() => _CustomColorDialogState();
}

class _CustomColorDialogState extends State<_CustomColorDialog> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initial);
  late final TextEditingController _hexField =
      TextEditingController(text: hexOf(widget.initial));

  Color get _color => _hsv.toColor();

  @override
  void dispose() {
    _hexField.dispose();
    super.dispose();
  }

  /// Applies an HSV change from a slider and mirrors it into the hex field.
  void _apply(HSVColor next) {
    setState(() => _hsv = next);
    final text = hexOf(next.toColor());
    if (text.toUpperCase() != _hexField.text.toUpperCase()) {
      _hexField.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
  }

  /// Applies a hex the user typed, without clobbering the field mid-edit.
  void _applyHex(String text) {
    final parsed = parseHexColor(text);
    if (parsed != null) setState(() => _hsv = HSVColor.fromColor(parsed));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onPreview =
        ThemeData.estimateBrightnessForColor(_color) == Brightness.dark
            ? Colors.white
            : Colors.black;
    return AlertDialog(
      title: const Text('Theme colour'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Live preview of the seed the scheme will be generated from.
            Container(
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _color,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                hexOf(_color),
                style: TextStyle(
                  color: onPreview,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                ),
              ),
            ),
            const SizedBox(height: 16),
            _GradientSlider(
              label: 'Hue',
              value: _hsv.hue,
              max: 360,
              gradient: const LinearGradient(colors: [
                Color(0xFFFF0000), Color(0xFFFFFF00), Color(0xFF00FF00),
                Color(0xFF00FFFF), Color(0xFF0000FF), Color(0xFFFF00FF),
                Color(0xFFFF0000),
              ]),
              onChanged: (v) => _apply(_hsv.withHue(v)),
            ),
            _GradientSlider(
              label: 'Saturation',
              value: _hsv.saturation,
              gradient: LinearGradient(colors: [
                HSVColor.fromAHSV(1, _hsv.hue, 0, _hsv.value).toColor(),
                HSVColor.fromAHSV(1, _hsv.hue, 1, _hsv.value).toColor(),
              ]),
              onChanged: (v) => _apply(_hsv.withSaturation(v)),
            ),
            _GradientSlider(
              label: 'Brightness',
              value: _hsv.value,
              gradient: LinearGradient(colors: [
                HSVColor.fromAHSV(1, _hsv.hue, _hsv.saturation, 0).toColor(),
                HSVColor.fromAHSV(1, _hsv.hue, _hsv.saturation, 1).toColor(),
              ]),
              onChanged: (v) => _apply(_hsv.withValue(v)),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _hexField,
              onChanged: _applyHex,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: 'Hex',
                prefixIcon: const Icon(Icons.tag),
                filled: true,
                fillColor: scheme.surfaceContainerHighest,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_color),
          child: const Text('Select'),
        ),
      ],
    );
  }
}

/// A [Slider] laid over a rounded gradient track — the classic HSV channel
/// control. [value] runs from 0 to [max] (default 1).
class _GradientSlider extends StatelessWidget {
  const _GradientSlider({
    required this.label,
    required this.value,
    required this.gradient,
    required this.onChanged,
    this.max = 1,
  });

  final String label;
  final double value;
  final double max;
  final Gradient gradient;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelMedium),
        Stack(
          alignment: Alignment.center,
          children: [
            // The gradient track, inset to line up with the slider's usable
            // width so the thumb tracks the colour under it.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Container(
                height: 12,
                decoration: BoxDecoration(
                  gradient: gradient,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
              ),
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 12,
                activeTrackColor: Colors.transparent,
                inactiveTrackColor: Colors.transparent,
                overlayColor: theme.colorScheme.primary.withValues(alpha: 0.12),
                thumbColor: Colors.white,
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 10,
                  elevation: 2,
                ),
              ),
              child: Slider(
                value: value.clamp(0, max),
                max: max,
                onChanged: onChanged,
              ),
            ),
          ],
        ),
      ],
    );
  }
}




