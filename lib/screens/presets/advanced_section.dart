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
        _thinking(theme),
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

  /// The thinking group: whether to ask for reasoning, how much of it to allow,
  /// and the tag pair that separates thinking a model writes inline in its reply
  /// from the reply itself.
  Widget _thinking(ThemeData theme) {
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Thinking', style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        Text(
          'Thinking is shown as a collapsed "Thought for …" bar above the reply, '
          'never as message text, and is not sent back on the next turn.',
          style: muted,
        ),
        PresetSwitch(
          label: 'Enable thinking',
          subtitle: 'Ask the model to reason before it answers.',
          value: _p.thinking,
          onChanged: _toggleThinking,
        ),
        // Effort and budget only mean anything once thinking is on, so they stay
        // out of the way until then.
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: _p.thinking
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    PresetDropdown<String>(
                      label: 'Reasoning effort',
                      value: _effort,
                      options: const [
                        ('', 'Model default'),
                        ('low', 'Low'),
                        ('medium', 'Medium'),
                        ('high', 'High'),
                      ],
                      onChanged: (v) => _set(() => _p.reasoningEffort = v),
                    ),
                    PresetSlider(
                      label: 'Thinking budget (tokens)',
                      value: _p.thinkingBudget.toDouble().clamp(0, 65536),
                      min: 0,
                      max: 65536,
                      integer: true,
                      onChanged: (v) => _set(() => _p.thinkingBudget = v.round()),
                    ),
                    Text(
                      '0 leaves the budget to the provider. Claude reserves at '
                      'least 1024 tokens and raises the response length to fit; '
                      'Gemini takes it as its thinking budget.',
                      style: muted,
                    ),
                  ],
                )
              : const SizedBox(width: double.infinity, height: 0),
        ),
        const SizedBox(height: 16),
        Text('Thinking tags', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: PresetTextField(
                key: const Key('thinkStartTag'),
                label: 'Start',
                hint: '<think>',
                value: _p.thinkStartTag,
                onChanged: (v) => _set(() => _p.thinkStartTag = v),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: PresetTextField(
                key: const Key('thinkEndTag'),
                label: 'End',
                hint: '</think>',
                value: _p.thinkEndTag,
                onChanged: (v) => _set(() => _p.thinkEndTag = v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'For models that write their thinking into the reply. Anything between '
          'these tags is lifted out into the thinking bar. Clear either field to '
          'leave the reply exactly as it arrives.',
          style: muted,
        ),
      ],
    );
  }

  /// The dropdown needs a value it actually offers; an imported preset can carry
  /// an effort this app does not list.
  String get _effort => const ['', 'low', 'medium', 'high']
          .contains(_p.reasoningEffort)
      ? _p.reasoningEffort
      : '';

  /// Turning thinking on with no effort chosen would send nothing at all to an
  /// OpenAI-compatible host, so the switch seeds a visible, editable default.
  void _toggleThinking(bool on) => _set(() {
        _p.thinking = on;
        if (on && _p.reasoningEffort.isEmpty) _p.reasoningEffort = 'medium';
      });
}
