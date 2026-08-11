import 'package:flutter/material.dart';

import '../../models/preset.dart';
import 'preset_controls.dart';

/// The "General" section, mirroring Agnaistic's General preset tab: the handful
/// of settings most chats actually tune — response length, context size,
/// temperature, min-p, streaming, and stopping strings.
class GeneralSection extends StatefulWidget {
  const GeneralSection({super.key, required this.preset, required this.onChanged});

  final Preset preset;
  final VoidCallback onChanged;

  @override
  State<GeneralSection> createState() => _GeneralSectionState();
}

class _GeneralSectionState extends State<GeneralSection> {
  Preset get _p => widget.preset;

  void _set(VoidCallback mutate) {
    setState(mutate);
    widget.onChanged();
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
          subtitle: 'Prefer the model\'s own limit over the value above.',
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
