import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A labelled slider with an editable numeric field on the right — the
/// workhorse control for the preset editor. The field and slider stay in sync;
/// typing a value clamps it into range.
class PresetSlider extends StatefulWidget {
  const PresetSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.integer = false,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final int? divisions;

  /// Whether the value is a whole number (formats/parses without decimals).
  final bool integer;

  @override
  State<PresetSlider> createState() => _PresetSliderState();
}

class _PresetSliderState extends State<PresetSlider> {
  late final TextEditingController _field =
      TextEditingController(text: _format(widget.value));
  final FocusNode _focus = FocusNode();

  String _format(double v) =>
      widget.integer || v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);

  @override
  void didUpdateWidget(PresetSlider old) {
    super.didUpdateWidget(old);
    // Reflect external/slider-driven changes into the field, unless the user is
    // mid-edit in it.
    if (!_focus.hasFocus && _format(widget.value) != _field.text) {
      _field.text = _format(widget.value);
    }
  }

  @override
  void dispose() {
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commitField(String text) {
    final parsed = double.tryParse(text.trim());
    if (parsed == null) {
      _field.text = _format(widget.value);
      return;
    }
    final clamped = parsed.clamp(widget.min, widget.max).toDouble();
    widget.onChanged(clamped);
    _field.text = _format(clamped);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: theme.textTheme.bodyMedium),
        Row(
          children: [
            Expanded(
              child: Slider(
                value: widget.value.clamp(widget.min, widget.max),
                min: widget.min,
                max: widget.max,
                divisions: widget.divisions,
                label: _format(widget.value),
                onChanged: widget.onChanged,
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 68,
              child: TextField(
                controller: _field,
                focusNode: _focus,
                textAlign: TextAlign.center,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
                ],
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                ),
                onSubmitted: _commitField,
                onEditingComplete: () => _commitField(_field.text),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A labelled on/off switch with an optional explanatory subtitle.
class PresetSwitch extends StatelessWidget {
  const PresetSwitch({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: subtitle == null ? null : Text(subtitle!),
      value: value,
      onChanged: onChanged,
    );
  }
}
