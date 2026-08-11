import 'package:flutter/material.dart';

import '../../models/prompt_block.dart';

/// Editor for a single prompt block. Edits the [block] in place and calls
/// [onChanged] so the parent can persist. Marker blocks (whose content is filled
/// from live data at send time) expose only their injection settings.
class PromptBlockEditPage extends StatefulWidget {
  const PromptBlockEditPage({
    super.key,
    required this.block,
    required this.onChanged,
  });

  final PromptBlock block;
  final VoidCallback onChanged;

  @override
  State<PromptBlockEditPage> createState() => _PromptBlockEditPageState();
}

class _PromptBlockEditPageState extends State<PromptBlockEditPage> {
  late final TextEditingController _name;
  late final TextEditingController _content;

  PromptBlock get _b => widget.block;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: _b.name)
      ..addListener(() {
        _b.name = _name.text;
        widget.onChanged();
      });
    _content = TextEditingController(text: _b.content)
      ..addListener(() {
        _b.content = _content.text;
        widget.onChanged();
      });
  }

  @override
  void dispose() {
    _name.dispose();
    _content.dispose();
    super.dispose();
  }

  void _set(VoidCallback mutate) {
    setState(mutate);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      appBar: AppBar(title: Text(_b.name.isEmpty ? 'Prompt block' : _b.name)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 24 + bottom),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Name',
              prefixIcon: Icon(Icons.label_outline),
            ),
          ),
          const SizedBox(height: 16),
          Text('Role', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'system', label: Text('System')),
              ButtonSegment(value: 'user', label: Text('User')),
              ButtonSegment(value: 'assistant', label: Text('Assistant')),
            ],
            selected: {kPromptRoles.contains(_b.role) ? _b.role : 'system'},
            onSelectionChanged: (s) => _set(() => _b.role = s.first),
          ),
          const SizedBox(height: 16),
          if (_b.marker)
            Card(
              color: theme.colorScheme.surfaceContainerHighest,
              margin: EdgeInsets.zero,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'This is a marker block. Its content is filled from live data '
                  '(character fields, chat history, examples) when a reply is '
                  'generated, so it has no editable text.',
                ),
              ),
            )
          else
            TextField(
              controller: _content,
              minLines: 5,
              maxLines: 16,
              decoration: const InputDecoration(
                labelText: 'Content',
                alignLabelWithHint: true,
                hintText: 'Supports macros like {{char}}, {{user}}, {{persona}}…',
              ),
            ),
          const SizedBox(height: 20),
          Text('Injection', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Inject at a chat depth'),
            subtitle: const Text(
              'On: placed inside the chat history at a depth. Off: placed in '
              'prompt order.',
            ),
            value: _b.injectionPosition == InjectionPosition.absolute,
            onChanged: (v) => _set(() => _b.injectionPosition =
                v ? InjectionPosition.absolute : InjectionPosition.relative),
          ),
          if (_b.injectionPosition == InjectionPosition.absolute) ...[
            _NumberField(
              label: 'Depth (messages from the end)',
              value: _b.injectionDepth,
              onChanged: (v) => _set(() => _b.injectionDepth = v),
            ),
            _NumberField(
              label: 'Order (higher wins at the same depth)',
              value: _b.injectionOrder,
              onChanged: (v) => _set(() => _b.injectionOrder = v),
            ),
          ],
        ],
      ),
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          IconButton(
            icon: const Icon(Icons.remove),
            onPressed: value > 0 ? () => onChanged(value - 1) : null,
          ),
          Text('$value', style: Theme.of(context).textTheme.titleMedium),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => onChanged(value + 1),
          ),
        ],
      ),
    );
  }
}
