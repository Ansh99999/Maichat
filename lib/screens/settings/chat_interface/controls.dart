/// The row widgets every Chat Interface spoke is built from.
///
/// These were private to the one long settings page before it was split into a
/// hub and seven spokes; they are unchanged in behaviour, only lifted out so
/// seven pages can share them rather than each growing its own near-copy.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../widgets/color_picker.dart';

/// Subtle, non-blocking confirmation that a change was applied. Replaces any
/// still-showing note so rapid tweaks don't stack up.
void notifySetting(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(milliseconds: 1400),
        behavior: SnackBarBehavior.floating,
      ),
    );
}

/// A section heading inside a spoke, for the two pages that still group their
/// rows (Layout's floating buttons, Text's wrapping rules).
Widget settingHeader(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );

/// A paragraph of explanation under a heading, in the muted voice the settings
/// pages use for "here is what this section is for".
Widget settingNote(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
/// A compact switch row — the shape every toggle on these pages takes.
class SettingSwitch extends StatelessWidget {
  const SettingSwitch({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
        dense: true,
        value: value,
        onChanged: onChanged,
        secondary: Icon(icon),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
      );
}

/// A labelled slider row: icon + label on top, the slider and its value below.
class SettingSlider extends StatelessWidget {
  const SettingSlider({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.suffix,
    required this.onChanged,
    this.divisions,
  });

  final IconData icon;
  final String label;
  final double value;
  final double min;
  final double max;
  final String suffix;
  final ValueChanged<double> onChanged;

  /// Notches for a setting that is really a whole number (an injection depth is
  /// a count of messages), so the thumb cannot land between two of them.
  final int? divisions;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 16),
              Expanded(child: Text(label)),
              Text(
                suffix,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

/// A labelled row of segmented choices for a small enum.
class SettingEnumRow<T> extends StatelessWidget {
  const SettingEnumRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.values,
    required this.labelOf,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final T value;
  final List<T> values;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 16),
              Text(label),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<T>(
              showSelectedIcon: false,
              segments: [
                for (final v in values)
                  ButtonSegment<T>(value: v, label: Text(labelOf(v))),
              ],
              selected: {value},
              onSelectionChanged: (s) => onChanged(s.first),
            ),
          ),
        ],
      ),
    );
  }
}

/// A labelled row whose choices live in a dropdown — for enums with more values
/// than a segmented button can show without shrinking the labels to nothing.
class SettingDropdownRow<T> extends StatelessWidget {
  const SettingDropdownRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.values,
    required this.labelOf,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final T value;
  final List<T> values;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 16),
          Expanded(child: Text(label)),
          DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: value,
              borderRadius: BorderRadius.circular(12),
              onChanged: (next) {
                if (next != null) onChanged(next);
              },
              items: [
                for (final v in values)
                  DropdownMenuItem<T>(value: v, child: Text(labelOf(v))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A colour override row: a swatch that opens the HSV picker, an "Auto (theme)"
/// state when unset, and a clear button to fall back to the theme again.
class SettingColorRow extends StatelessWidget {
  const SettingColorRow({
    super.key,
    required this.label,
    required this.value,
    required this.fallback,
    required this.onChanged,
  });

  final String label;
  final int? value;
  final Color fallback;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final set = value != null;
    final color = set ? Color(value!) : fallback;

    Future<void> pick() async {
      final picked = await showCustomColorDialog(context, color);
      if (picked != null) onChanged(picked.toARGB32());
    }
    return ListTile(
      leading: const Icon(Icons.format_color_fill_outlined),
      title: Text(label),
      subtitle: Text(set ? hexOf(color) : 'Auto (theme)'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (set)
            IconButton(
              tooltip: 'Follow theme',
              icon: const Icon(Icons.close),
              onPressed: () => onChanged(null),
            ),
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: scheme.outlineVariant),
            ),
          ),
        ],
      ),
      onTap: pick,
    );
  }
}

/// A numeric value editable two ways at once: a slider for quick adjustment and
/// a text field for precise entry, kept in sync. The slider spans [min]..
/// [sliderMax]; the field accepts anything in [min]..[hardMax] so a value past
/// the slider's comfortable ceiling can still be typed (the slider just pins to
/// its max). [onChanged] fires live; [onChangeEnd] fires once a change is
/// committed (slider release or field submit) — the hook the caller uses to
/// surface a confirmation.
class SettingSizeField extends StatefulWidget {
  const SettingSizeField({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.min,
    required this.sliderMax,
    required this.hardMax,
    required this.unit,
    required this.onChanged,
    this.onChangeEnd,
  });

  final IconData icon;
  final String label;
  final double value;
  final double min;
  final double sliderMax;
  final double hardMax;
  final String unit;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  State<SettingSizeField> createState() => _SettingSizeFieldState();
}
class _SettingSizeFieldState extends State<SettingSizeField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value.round().toString());
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(SettingSizeField old) {
    super.didUpdateWidget(old);
    // Reflect external changes (e.g. dragging the slider) into the field, but
    // never fight the user while they are typing in it.
    if (!_focus.hasFocus && widget.value != old.value) {
      final text = widget.value.round().toString();
      if (_controller.text != text) _controller.text = text;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  double _clamp(double v) => v.clamp(widget.min, widget.hardMax).toDouble();

  void _commitField(String raw) {
    final parsed = double.tryParse(raw.trim());
    if (parsed == null) {
      _controller.text = widget.value.round().toString();
      return;
    }
    final v = _clamp(parsed);
    _controller.text = v.round().toString();
    widget.onChanged(v);
    widget.onChangeEnd?.call(v);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sliderValue = widget.value.clamp(widget.min, widget.sliderMax);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(widget.icon, size: 20),
              const SizedBox(width: 16),
              Expanded(child: Text(widget.label)),
              SizedBox(
                width: 84,
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  textAlign: TextAlign.end,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: false),
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    isDense: true,
                    suffixText: widget.unit,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 8),
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: _commitField,
                  onTapOutside: (_) {
                    if (_focus.hasFocus) {
                      _focus.unfocus();
                      _commitField(_controller.text);
                    }
                  },
                ),
              ),
            ],
          ),
          Slider(
            value: sliderValue.toDouble(),
            min: widget.min,
            max: widget.sliderMax,
            activeColor: scheme.primary,
            onChanged: (v) {
              final r = v.roundToDouble();
              _controller.text = r.round().toString();
              widget.onChanged(r);
            },
            onChangeEnd: (v) => widget.onChangeEnd?.call(v.roundToDouble()),
          ),
        ],
      ),
    );
  }
}
/// Claims the pointer the moment it lands, so a mostly-vertical drag on the
/// nudge pad is not handed to the surrounding `ListView`.
///
/// This is the settings-page half of a trap the live preview already documents:
/// a scrollable takes any mostly-vertical drag for itself, which is exactly the
/// direction a name or an avatar usually needs to move. The preview solved it by
/// refusing to scroll at all; a settings page has to scroll, so the pad wins the
/// arena instead.
class _EagerPanRecognizer extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

/// The pad's own touch surface. Named so a test can drag the square itself
/// rather than the row it sits in — the row's centre is over the label, where a
/// drag does nothing.
const Key kNudgePadKey = Key('nudge-pad');

/// The two-axis nudge: one square pad standing in for what used to be a "nudge
/// across" slider, a "nudge down" slider and a row whose only job was a Reset.
///
/// Dragging reports a delta in *offset* units, scaled so one traverse of the pad
/// covers the whole range — the numbers are printed beside it, because a pad is
/// good at "a bit left" and bad at "exactly minus twelve".
class NudgePad extends StatelessWidget {
  const NudgePad({
    super.key,
    required this.label,
    required this.offsetX,
    required this.offsetY,
    required this.range,
    required this.onDelta,
    required this.onReset,
    this.hint,
  });

  final String label;
  final double offsetX;
  final double offsetY;

  /// The furthest the offset may go in either direction, on both axes.
  final double range;

  final void Function(Offset delta) onDelta;
  final VoidCallback onReset;

  /// Shown when the offset is untouched, in place of the co-ordinates.
  final String? hint;

  static const double _pad = 76;
  static const double _dot = 9;
  bool get _nudged => offsetX != 0 || offsetY != 0;

  /// Pad pixels → offset units. One full traverse of the pad spans the range.
  double get _scale => range / ((_pad - _dot * 2) / 2);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reach = (_pad - _dot * 2) / 2;
    final dx = (offsetX / range).clamp(-1.0, 1.0) * reach;
    final dy = (offsetY / range).clamp(-1.0, 1.0) * reach;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          const Icon(Icons.open_with_outlined, size: 20),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                const SizedBox(height: 2),
                Text(
                  _nudged
                      ? 'Moved ${offsetX.round()}, ${offsetY.round()}'
                      : hint ?? 'Drag the pad, or drag it in the preview',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                if (_nudged)
                  TextButton(
                    onPressed: onReset,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Reset'),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          RawGestureDetector(
            key: kNudgePadKey,
            gestures: {
              _EagerPanRecognizer:
                  GestureRecognizerFactoryWithHandlers<_EagerPanRecognizer>(
                () => _EagerPanRecognizer(),
                (r) => r.onUpdate = (d) => onDelta(d.delta * _scale),
              ),
            },
            child: Container(
              width: _pad,
              height: _pad,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Cross-hairs, so "back to the middle" is a visible place.
                  Container(width: _pad, height: 1, color: scheme.outlineVariant),
                  Container(width: 1, height: _pad, color: scheme.outlineVariant),
                  Transform.translate(
                    offset: Offset(dx, dy),
                    child: Container(
                      width: _dot * 2,
                      height: _dot * 2,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}










