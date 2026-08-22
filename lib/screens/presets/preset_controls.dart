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
  void initState() {
    super.initState();
    // Commit whatever is typed the moment the field loses focus. Without this a
    // value typed into the box (e.g. a context size of 92000) is only committed
    // by an explicit keyboard "done" (onSubmitted/onEditingComplete); tapping
    // "Save" elsewhere on the screen just blurs the field, so the typed number
    // was silently dropped and only slider-dragged values ever persisted.
    _focus.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) _commitField(_field.text);
  }

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
    _focus.removeListener(_onFocusChange);
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

/// A labelled dropdown for a small fixed set of choices — the compact control
/// this app uses instead of a wide `SegmentedButton` (see the provider editor).
class PresetDropdown<T> extends StatelessWidget {
  const PresetDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final T value;

  /// Choices as value/label pairs, in the order they should appear.
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
          const SizedBox(width: 12),
          DropdownButton<T>(
            value: value,
            underline: const SizedBox.shrink(),
            borderRadius: BorderRadius.circular(12),
            items: [
              for (final (v, text) in options)
                DropdownMenuItem<T>(value: v, child: Text(text)),
            ],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ],
      ),
    );
  }
}

/// A small single-line text field for a preset string, owning its own
/// controller so the section around it can stay a plain builder. Reports every
/// keystroke, and reflects an external change unless the user is mid-edit.
class PresetTextField extends StatefulWidget {
  const PresetTextField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.hint,
  });

  final String label;
  final String value;
  final String? hint;
  final ValueChanged<String> onChanged;

  @override
  State<PresetTextField> createState() => _PresetTextFieldState();
}

class _PresetTextFieldState extends State<PresetTextField> {
  late final TextEditingController _field =
      TextEditingController(text: widget.value);
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(PresetTextField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && widget.value != _field.text) {
      _field.text = widget.value;
    }
  }

  @override
  void dispose() {
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _field,
      focusNode: _focus,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        isDense: true,
      ),
      onChanged: widget.onChanged,
    );
  }
}
