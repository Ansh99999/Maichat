import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/regex_rule.dart';
import '../../services/regex_engine.dart';
import '../../state/app_state.dart';

/// Writes or edits one regex rule. [ruleId] null makes a fresh one.
///
/// Everything lives on a working copy; nothing touches the store until Save, so
/// backing out abandons the edit cleanly. A live test panel at the top runs the
/// rule as you type it, which is the fastest way to tell a working pattern from
/// a broken one without leaving the page.
class RegexEditScreen extends StatefulWidget {
  const RegexEditScreen({super.key, this.ruleId});

  final String? ruleId;

  @override
  State<RegexEditScreen> createState() => _RegexEditScreenState();
}

class _RegexEditScreenState extends State<RegexEditScreen> {
  late final RegexRule _rule;
  late final bool _isNew;

  final _name = TextEditingController();
  final _find = TextEditingController();
  final _replace = TextEditingController();
  final _trim = TextEditingController();
  final _minDepth = TextEditingController();
  final _maxDepth = TextEditingController();
  final _test = TextEditingController();

  bool _advancedOpen = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.ruleId == null
        ? null
        : context.read<AppState>().regexRuleById(widget.ruleId!);
    _isNew = existing == null;
    // Edit a copy so a cancelled edit leaves the stored rule untouched.
    _rule = existing?.copy() ?? RegexRule.create();
    _name.text = _rule.name;
    _find.text = _rule.find;
    _replace.text = _rule.replace;
    _trim.text = _rule.trimStrings.join('\n');
    _minDepth.text = _rule.minDepth?.toString() ?? '';
    _maxDepth.text = _rule.maxDepth?.toString() ?? '';
    _advancedOpen = _rule.trimStrings.isNotEmpty ||
        _rule.minDepth != null ||
        _rule.maxDepth != null ||
        _rule.macroMode != RegexMacroMode.none;
  }

  @override
  void dispose() {
    _name.dispose();
    _find.dispose();
    _replace.dispose();
    _trim.dispose();
    _minDepth.dispose();
    _maxDepth.dispose();
    _test.dispose();
    super.dispose();
  }

  // Fold the controllers back onto the rule before it is saved or tested.
  RegexRule _collect() {
    _rule.name = _name.text.trim();
    _rule.find = _find.text;
    _rule.replace = _replace.text;
    _rule.trimStrings
      ..clear()
      ..addAll(_trim.text
          .split('\n')
          .map((s) => s)
          .where((s) => s.isNotEmpty));
    _rule.minDepth = int.tryParse(_minDepth.text.trim());
    _rule.maxDepth = int.tryParse(_maxDepth.text.trim());
    return _rule;
  }

  Future<void> _save() async {
    final rule = _collect();
    if (rule.find.trim().isEmpty) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(content: Text('Give the rule something to find first.')),
        );
      return;
    }
    await context.read<AppState>().saveRegexRule(rule);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'New rule' : 'Edit rule'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          _TestPanel(collect: _collect, controller: _test),
          const SizedBox(height: 20),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'What this rule is for',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _find,
            style: const TextStyle(fontFamily: 'monospace'),
            decoration: const InputDecoration(
              labelText: 'Find',
              hintText: r'A pattern, or /pattern/flags',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _replace,
            minLines: 2,
            maxLines: 6,
            style: const TextStyle(fontFamily: 'monospace'),
            decoration: const InputDecoration(
              labelText: 'Replace with',
              hintText: r'Empty deletes the match. {{match}}, $1, $<name> reuse it.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          _SectionLabel('Where it applies'),
          _TargetChips(rule: _rule, onChanged: () => setState(() {})),
          const SizedBox(height: 24),
          _SectionLabel('How it changes things'),
          _ModeChoice(rule: _rule, onChanged: () => setState(() {})),
          const SizedBox(height: 16),
          _AdvancedSection(
            open: _advancedOpen,
            onToggle: () => setState(() => _advancedOpen = !_advancedOpen),
            rule: _rule,
            trim: _trim,
            minDepth: _minDepth,
            maxDepth: _maxDepth,
            onChanged: () => setState(() {}),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}

/// A live preview: type sample text, watch the rule act on it. Rebuilds on every
/// keystroke of the input and reads the rule fresh through [collect], so editing
/// the pattern updates the output too (the parent rebuilds the whole page).
class _TestPanel extends StatefulWidget {
  const _TestPanel({required this.collect, required this.controller});

  final RegexRule Function() collect;
  final TextEditingController controller;

  @override
  State<_TestPanel> createState() => _TestPanelState();
}

class _TestPanelState extends State<_TestPanel> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rule = widget.collect();
    final input = widget.controller.text;
    final output = input.isEmpty
        ? ''
        : RegexEngine.runRule(rule, input, charName: 'Aria', userName: 'You');

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.science_outlined, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Text('Try it', style: Theme.of(context).textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: widget.controller,
            minLines: 2,
            maxLines: 5,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Paste sample text to see the rule act on it',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Text('Result', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Text(
              input.isEmpty ? '—' : output,
              style: TextStyle(
                fontFamily: 'monospace',
                color: input.isEmpty ? scheme.onSurfaceVariant : scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The "where it applies" chips — user input, AI output, reasoning.
class _TargetChips extends StatelessWidget {
  const _TargetChips({required this.rule, required this.onChanged});

  final RegexRule rule;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    Widget chip(String label, RegexTarget target) => FilterChip(
          label: Text(label),
          selected: rule.actsOn(target),
          onSelected: (on) {
            rule.setTarget(target, on);
            onChanged();
          },
        );

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        chip('Your messages', RegexTarget.userInput),
        chip('AI replies', RegexTarget.aiOutput),
        chip('Reasoning', RegexTarget.reasoning),
      ],
    );
  }
}

/// The three-way ephemerality choice, as a column of radio rows with a line of
/// explanation each — the wording that trips people up, spelt out.
class _ModeChoice extends StatelessWidget {
  const _ModeChoice({required this.rule, required this.onChanged});

  final RegexRule rule;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    Widget row(RegexMode mode, String title, String subtitle) =>
        RadioListTile<RegexMode>(
          value: mode,
          contentPadding: EdgeInsets.zero,
          title: Text(title),
          subtitle: Text(subtitle),
        );

    return RadioGroup<RegexMode>(
      groupValue: rule.mode,
      onChanged: (value) {
        if (value != null) rule.mode = value;
        onChanged();
      },
      child: Column(
        children: [
          row(RegexMode.permanent, 'Edit the saved message',
              'Rewrites the message for good.'),
          row(RegexMode.displayOnly, 'Only change what is shown',
              'Cosmetic — the saved message stays as it was.'),
          row(RegexMode.promptOnly, 'Only change what is sent',
              'The model gets the cleaned-up version; your chat does not change.'),
        ],
      ),
    );
  }
}

class _AdvancedSection extends StatelessWidget {
  const _AdvancedSection({
    required this.open,
    required this.onToggle,
    required this.rule,
    required this.trim,
    required this.minDepth,
    required this.maxDepth,
    required this.onChanged,
  });

  final bool open;
  final VoidCallback onToggle;
  final RegexRule rule;
  final TextEditingController trim;
  final TextEditingController minDepth;
  final TextEditingController maxDepth;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Text('Advanced',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        )),
                const Spacer(),
                Icon(open ? Icons.expand_less : Icons.expand_more,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
        if (open) ...[
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: rule.runOnEdit,
            onChanged: (on) {
              rule.runOnEdit = on;
              onChanged();
            },
            title: const Text('Re-run when a message is edited'),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<RegexMacroMode>(
            initialValue: rule.macroMode,
            decoration: const InputDecoration(
              labelText: 'Macros in the find pattern',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(
                value: RegexMacroMode.none,
                child: Text("Don't substitute"),
              ),
              DropdownMenuItem(
                value: RegexMacroMode.raw,
                child: Text('Substitute (raw)'),
              ),
              DropdownMenuItem(
                value: RegexMacroMode.escaped,
                child: Text('Substitute (escaped)'),
              ),
            ],
            onChanged: (value) {
              if (value != null) rule.macroMode = value;
              onChanged();
            },
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: minDepth,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Min depth',
                    hintText: 'No limit',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: maxDepth,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Max depth',
                    hintText: 'No limit',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Depth is how far back from the newest message a rule reaches — 0 is '
            'the newest. Leave blank for no limit.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: trim,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Trim out',
              hintText: 'Snippets stripped from a match, one per line',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ],
    );
  }
}
