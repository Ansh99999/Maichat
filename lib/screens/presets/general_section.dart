import 'package:flutter/material.dart';

import '../../models/preset.dart';
import '../../services/model_context.dart';
import 'preset_controls.dart';

/// The "General" section, mirroring Agnaistic's General preset tab: the handful
/// of settings most chats actually tune — response length, context size,
/// temperature, min-p, streaming, and stopping strings.
class GeneralSection extends StatefulWidget {
  const GeneralSection({
    super.key,
    required this.preset,
    required this.onChanged,
    this.model = '',
  });

  final Preset preset;
  final VoidCallback onChanged;

  /// The model this preset will run on, so the context row can report the limit
  /// it resolves to. Empty when none is selected yet.
  final String model;

  @override
  State<GeneralSection> createState() => _GeneralSectionState();
}

class _GeneralSectionState extends State<GeneralSection> {
  Preset get _p => widget.preset;

  void _set(VoidCallback mutate) {
    setState(mutate);
    widget.onChanged();
  }

  /// What the "use the model's limit" switch actually resolves to right now —
  /// the whole point of the switch is that the number in use is not the one on
  /// the slider, so say which it is.
  String get _maxContextSubtitle {
    if (!_p.useMaxContext) {
      return 'Prefer the model\'s own limit over the value above.';
    }
    final model = widget.model.trim();
    if (model.isEmpty) return 'No model selected yet — using the value above.';
    final known = knownMaxContext(model);
    if (known == null) return 'No known limit for $model — using the value above.';
    return 'Using ${_thousands(known)} tokens for $model.';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PresetSlider(
          label: 'Response length (max tokens)',
          value: _p.maxResponseTokens.toDouble(),
          min: 16,
          max: 8192,
          onChanged: (v) => _set(() => _p.maxResponseTokens = v.round()),
        ),
        PresetSlider(
          label: 'Context size',
          value: _p.maxContext.toDouble().clamp(16, 200000),
          min: 16,
          max: 200000,
          onChanged: (v) => _set(() => _p.maxContext = v.round()),
        ),
        PresetSwitch(
          label: 'Use model max context if known',
          subtitle: _maxContextSubtitle,
          value: _p.useMaxContext,
          onChanged: (v) => _set(() => _p.useMaxContext = v),
        ),
        PresetSlider(
          label: 'Temperature',
          value: _p.temperature,
          min: 0.0,
          max: 2.0,
          onChanged: (v) => _set(() => _p.temperature = v),
        ),
        PresetSlider(
          label: 'Min P',
          value: _p.minP,
          min: 0.0,
          max: 1.0,
          onChanged: (v) => _set(() => _p.minP = v),
        ),
        PresetSwitch(
          label: 'Stream response',
          subtitle: 'Off waits for the whole reply, with no streaming request.',
          value: _p.stream,
          onChanged: (v) => _set(() => _p.stream = v),
        ),
        const SizedBox(height: 8),
        _StopSequences(
          stops: _p.stopSequences,
          onChanged: () => _set(() {}),
        ),
      ],
    );
  }
}

/// `131072` as `131,072` — a context window is easier to recognise grouped.
String _thousands(int value) {
  final digits = value.toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// A small chip editor for stopping strings.
class _StopSequences extends StatefulWidget {
  const _StopSequences({required this.stops, required this.onChanged});

  final List<String> stops;
  final VoidCallback onChanged;

  @override
  State<_StopSequences> createState() => _StopSequencesState();
}

class _StopSequencesState extends State<_StopSequences> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _add() {
    final v = _field.text.trim();
    if (v.isEmpty || widget.stops.contains(v)) return;
    widget.stops.add(v);
    _field.clear();
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Stopping strings', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        if (widget.stops.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final stop in List<String>.from(widget.stops))
                InputChip(
                  label: Text(stop),
                  onDeleted: () {
                    widget.stops.remove(stop);
                    widget.onChanged();
                  },
                ),
            ],
          ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _field,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Add a stop sequence',
                ),
                onSubmitted: (_) => _add(),
              ),
            ),
            IconButton(icon: const Icon(Icons.add), onPressed: _add),
          ],
        ),
      ],
    );
  }
}
