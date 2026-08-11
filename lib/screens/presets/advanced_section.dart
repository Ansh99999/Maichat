import 'package:flutter/material.dart';

import '../../models/preset.dart';
import 'preset_controls.dart';

/// The "Advanced" section: the extra samplers, behaviour toggles and a context
/// budget readout that the Simple view hides.
class AdvancedSection extends StatefulWidget {
  const AdvancedSection({super.key, required this.preset, required this.onChanged});

  final Preset preset;
  final VoidCallback onChanged;

  @override
  State<AdvancedSection> createState() => _AdvancedSectionState();
}

class _AdvancedSectionState extends State<AdvancedSection> {
  Preset get _p => widget.preset;

  void _set(VoidCallback mutate) {
    setState(mutate);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final budget = (_p.maxContext - _p.maxResponseTokens).clamp(0, 1 << 30);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PresetSlider(
          label: 'Top P',
          value: _p.topP,
          min: 0.0,
          max: 1.0,
          onChanged: (v) => _set(() => _p.topP = v),
        ),
        PresetSlider(
          label: 'Top K',
          value: _p.topK.toDouble(),
          min: 0,
          max: 200,
          onChanged: (v) => _set(() => _p.topK = v.round()),
        ),
        PresetSlider(
          label: 'Top A',
          value: _p.topA.toDouble(),
          min: 0,
          max: 1000,
          onChanged: (v) => _set(() => _p.topA = v.round()),
        ),
        PresetSlider(
          label: 'Frequency penalty',
          value: _p.frequencyPenalty,
          min: -2.0,
          max: 2.0,
          onChanged: (v) => _set(() => _p.frequencyPenalty = v),
        ),
        PresetSlider(
          label: 'Presence penalty',
          value: _p.presencePenalty,
          min: -2.0,
          max: 2.0,
          onChanged: (v) => _set(() => _p.presencePenalty = v),
        ),
        PresetSlider(
          label: 'Repetition penalty',
          value: _p.repetitionPenalty,
          min: 1.0,
          max: 2.0,
          onChanged: (v) => _set(() => _p.repetitionPenalty = v),
        ),
        PresetSlider(
          label: 'Responses (n)',
          value: _p.n.toDouble(),
          min: 1,
          max: 8,
          divisions: 7,
          onChanged: (v) => _set(() => _p.n = v.round()),
        ),
        PresetSlider(
          label: 'Seed (-1 = random)',
          value: _p.seed.toDouble().clamp(-1, 1000000),
          min: -1,
          max: 1000000,
          onChanged: (v) => _set(() => _p.seed = v.round()),
        ),
        const Divider(height: 24),
        PresetSwitch(
          label: 'Squash system messages',
          subtitle: 'Merge consecutive system turns into one.',
          value: _p.squashSystemMessages,
          onChanged: (v) => _set(() => _p.squashSystemMessages = v),
        ),
        PresetSwitch(
          label: 'Wrap messages in quotes',
          value: _p.wrapInQuotes,
          onChanged: (v) => _set(() => _p.wrapInQuotes = v),
        ),
        PresetSwitch(
          label: 'Unlock max context',
          subtitle: 'Allow context sizes beyond the usual cap.',
          value: _p.maxContextUnlocked,
          onChanged: (v) => _set(() => _p.maxContextUnlocked = v),
        ),
        const Divider(height: 24),
        Text('Context budget', style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        Text(
          '$budget tokens for the prompt '
          '(${_p.maxContext} context − ${_p.maxResponseTokens} reserved for the reply). '
          'Fixed blocks are placed first; chat history fills the rest, newest first.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
