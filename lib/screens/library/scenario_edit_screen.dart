import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/scenario.dart';
import '../../state/app_state.dart';
import '../../widgets/tag_entry_field.dart';

/// The scenario maker: a title, tags, the prompt itself, and what it will cost.
///
/// Deliberately one screen with four things on it. A scenario is a paragraph of
/// prose — the editor should feel like writing one, not like filling in a form —
/// so the content field takes the whole page and everything else is a single row
/// above or below it. The token readout sits under the field because a scenario
/// is paid for on *every* turn, and that is the one number a writer needs in
/// front of them while deciding how much to say.
///
/// Passed a [scenario] it edits a copy and writes it back on Save; with none it
/// builds a fresh one. When [persist] is false nothing is stored — the finished
/// scenario is returned to the caller instead, which is how the picker sheet
/// reuses this screen for an edit it may or may not commit to the library.
class ScenarioEditScreen extends StatefulWidget {
  const ScenarioEditScreen({
    super.key,
    this.scenario,
    this.persist = true,
  });

  final Scenario? scenario;
  final bool persist;

  @override
  State<ScenarioEditScreen> createState() => _ScenarioEditScreenState();
}

class _ScenarioEditScreenState extends State<ScenarioEditScreen> {
  /// The scenario being edited: a copy, so backing out really does discard.
  late final Scenario _scenario;

  late final TextEditingController _name;
  late final TextEditingController _text;

  late List<String> _tags;
  late bool _overwrite;
  bool _dirty = false;

  bool get _isNew => widget.scenario == null;

  @override
  void initState() {
    super.initState();
    _scenario = widget.scenario?.copyWith() ?? Scenario.empty();
    _name = TextEditingController(text: _scenario.name);
    _text = TextEditingController(text: _scenario.text);
    _tags = List<String>.from(_scenario.tags);
    _overwrite = _scenario.overwriteCharacterScenario;
    _name.addListener(_markDirty);
    // The content field drives the token readout, so it rebuilds on every
    // keystroke — unlike the title, which only needs to mark the form dirty.
    _text.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _name.dispose();
    _text.dispose();
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  void _onTextChanged() => setState(() => _dirty = true);

  /// What this scenario will cost on every turn it is in force.
  int _tokens(AppState state) => state.estimateTokens(_text.text);

  Scenario _collect() => _scenario.copyWith(
        name: _name.text.trim(),
        text: _text.text.trim(),
        tags: _tags,
        overwriteCharacterScenario: _overwrite,
        updatedAt: DateTime.now(),
      );

  Future<void> _save() async {
    final text = _text.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('A scenario needs something to say — write the opening '
              'first.'),
        ));
      return;
    }
    final result = _collect();
    if (widget.persist) {
      await context.read<AppState>().saveScenario(result);
      if (!mounted) return;
      Navigator.of(context).pop(result);
      return;
    }
    Navigator.of(context).pop(result);
  }

  Future<void> _handlePop(bool didPop) async {
    if (didPop) return;
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard this scenario?'),
        content: const Text('Your changes have not been saved.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.of(context).pop();
  }
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.paddingOf(context).bottom;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) => _handlePop(didPop),
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isNew ? 'New scenario' : 'Edit scenario'),
          actions: [
            TextButton(onPressed: _save, child: const Text('Save')),
          ],
        ),
        body: ListView(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 24 + bottom),
          children: [
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Title',
                hintText: 'Snowed in at the station',
                prefixIcon: Icon(Icons.title_outlined),
              ),
            ),
            const SizedBox(height: 16),
            TagEntryField(
              tags: _tags,
              hint: 'e.g. winter, isolation, slow burn',
              onChanged: (tags) => setState(() {
                _tags = tags;
                _dirty = true;
              }),
            ),
            const SizedBox(height: 20),
            Text(
              'The scenario',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _text,
              minLines: 8,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
                hintText: 'Where are you both, and what is happening?\n\n'
                    '{{char}} and {{user}} work here — they become the '
                    'character\'s and your name.',
              ),
            ),
            const SizedBox(height: 10),
            _TokenLine(tokens: _tokens(state)),
            const Divider(height: 36),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _overwrite,
              onChanged: (v) => setState(() {
                _overwrite = v;
                _dirty = true;
              }),
              secondary: const Icon(Icons.swap_horiz_outlined),
              title: const Text("Replace the character's scenario"),
              subtitle: Text(_overwrite
                  ? 'The card\'s own scenario is set aside while this one is in '
                      'force'
                  : 'This is added after the card\'s own scenario, so both are '
                      'sent'),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the scenario costs, every turn. Worded as a running cost rather than a
/// size, because that is the decision it informs.
class _TokenLine extends StatelessWidget {
  const _TokenLine({required this.tokens});

  final int tokens;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Past a few hundred tokens a scenario starts eating the chat history it was
    // written to frame, so the readout says so instead of only counting.
    final heavy = tokens > 400;
    return Row(
      children: [
        Icon(
          heavy ? Icons.warning_amber_outlined : Icons.data_usage_outlined,
          size: 16,
          color: heavy ? scheme.error : scheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            tokens == 0
                ? 'No tokens yet'
                : '$tokens token${tokens == 1 ? '' : 's'}, on every turn'
                    '${heavy ? ' — that is a lot of the context window' : ''}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: heavy ? scheme.error : scheme.onSurfaceVariant,
                ),
          ),
        ),
      ],
    );
  }
}
