import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/chat_interface.dart';
import '../../../state/app_state.dart';
import '../../../widgets/color_picker.dart';
import '../../../widgets/message_markdown.dart';
import 'controls.dart';

/// The "Text wrapping" editor: the user's own symbol pairs, each tinting what it
/// wraps and each free to keep or hide its symbols. Asterisks and quotes are the
/// two built-in cases of this; these are the same idea, spelled out.
class TextWrapSection extends StatelessWidget {
  const TextWrapSection({
    super.key,
    required this.rules,
    required this.markdown,
    required this.onChanged,
  });

  final List<TextWrapRule> rules;

  /// Wrapping is part of the markdown pass, so it does nothing while markdown is
  /// off — said out loud rather than left as a setting that quietly has no
  /// effect.
  final bool markdown;

  final ValueChanged<List<TextWrapRule>> onChanged;

  Future<void> _edit(BuildContext context, int? index) async {
    final edited = await showWrapRuleSheet(
      context,
      index == null ? null : rules[index],
    );
    if (edited == null) return;
    final next = [...rules];
    if (index == null) {
      next.add(edited);
    } else {
      next[index] = edited;
    }
    onChanged(next);
    if (!context.mounted) return;
    notifySetting(
        context, index == null ? 'Wrapping rule added' : 'Wrapping rule updated');
  }

  void _write(int index, TextWrapRule rule) {
    final next = [...rules]..[index] = rule;
    onChanged(next);
  }
  @override
  Widget build(BuildContext context) {
    final full = rules.length >= kMaxTextWrapRules;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        settingNote(
          context,
          'Give a pair of symbols a colour of its own — and choose whether the '
          'symbols stay visible, the way quotes do, or disappear, the way '
          'asterisks do.',
        ),
        for (final (i, rule) in rules.indexed)
          _WrapRuleTile(
            rule: rule,
            onTap: () => _edit(context, i),
            onToggle: (v) => _write(i, rule.copyWith(enabled: v)),
            onRemove: () {
              onChanged([...rules]..removeAt(i));
              notifySetting(context, 'Wrapping rule removed');
            },
          ),
        if (rules.isNotEmpty && !markdown)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              'Markdown is off, so nothing is being wrapped right now.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: full ? null : () => _edit(context, null),
              icon: const Icon(Icons.add),
              label: Text(full ? 'Rule limit reached' : 'Add wrapping rule'),
            ),
          ),
        ),
      ],
    );
  }
}
/// One rule in the list: a swatch, a live sample of what it does, the raw symbol
/// pair, and controls to switch it off or drop it. Tapping the row edits it.
class _WrapRuleTile extends StatelessWidget {
  const _WrapRuleTile({
    required this.rule,
    required this.onTap,
    required this.onToggle,
    required this.onRemove,
  });

  final TextWrapRule rule;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = rule.color != null ? Color(rule.color!) : scheme.onSurface;
    final sample =
        rule.hideMarkers ? 'furious' : '${rule.start}furious${rule.end}';
    final facts = [
      '${rule.start} … ${rule.end}',
      rule.hideMarkers ? 'symbols hidden' : 'symbols shown',
      if (rule.color != null) hexOf(Color(rule.color!)) else 'follows the text',
    ];
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: ListTile(
        onTap: onTap,
        leading: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: tint,
            shape: BoxShape.circle,
            border: Border.all(color: scheme.outlineVariant),
          ),
        ),
        title: Text.rich(
          TextSpan(
            children: [
              const TextSpan(text: 'He was '),
              TextSpan(text: sample, style: TextStyle(color: tint)),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(facts.join(' · '),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(value: rule.enabled, onChanged: onToggle),
            IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.delete_outline),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}
/// Opens the editor for one wrapping rule. Completes with the rule to save, or
/// null when the sheet is dismissed.
Future<TextWrapRule?> showWrapRuleSheet(
  BuildContext context,
  TextWrapRule? initial,
) =>
    showModalBottomSheet<TextWrapRule>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _WrapRuleSheet(initial: initial),
    );

/// The add/edit sheet: the two symbols, a colour, whether the symbols show, and
/// a preview rendered by the same code that draws a message — so what is shown
/// here is what the chat will do.
class _WrapRuleSheet extends StatefulWidget {
  const _WrapRuleSheet({this.initial});

  final TextWrapRule? initial;

  @override
  State<_WrapRuleSheet> createState() => _WrapRuleSheetState();
}

class _WrapRuleSheetState extends State<_WrapRuleSheet> {
  late final TextEditingController _start =
      TextEditingController(text: widget.initial?.start ?? '');
  late final TextEditingController _end =
      TextEditingController(text: widget.initial?.end ?? '');
  late int? _color = widget.initial?.color;
  late bool _hide = widget.initial?.hideMarkers ?? true;

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  TextWrapRule get _rule => TextWrapRule(
        start: _start.text,
        end: _end.text,
        color: _color,
        hideMarkers: _hide,
        enabled: widget.initial?.enabled ?? true,
      );
  /// A one-or-two-character field. Symbols are punctuation, so the keyboard and
  /// the length cap both say so.
  Widget _symbolField(TextEditingController c, String label, String hint) =>
      TextField(
        controller: c,
        maxLength: kMaxWrapMarkerLength,
        textAlign: TextAlign.center,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 18),
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          counterText: '',
          border: const OutlineInputBorder(),
        ),
      );

  Future<void> _pickColour() async {
    final scheme = Theme.of(context).colorScheme;
    final picked = await showCustomColorDialog(
      context,
      _color != null ? Color(_color!) : scheme.primary,
    );
    if (picked != null) setState(() => _color = picked.toARGB32());
  }

  /// The rule as the chat would draw it, built by the message renderer itself.
  Widget _preview(TextWrapRule rule) {
    final scheme = Theme.of(context).colorScheme;
    final ui = context.watch<AppState>().chatInterface;
    final base = TextStyle(
      color: scheme.onSurface,
      fontSize: ui.fontSize,
      height: 1.35,
    );
    final sample =
        'She said "wait" and ${rule.start}this part${rule.end} is yours.';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text.rich(
        TextSpan(
          style: base,
          children: buildMessageSpans(
            sample,
            MarkdownStyles(
              base: base,
              emphasis: ui.emphasisColor != null
                  ? Color(ui.emphasisColor!)
                  : scheme.onSurface,
              quote:
                  ui.quoteColor != null ? Color(ui.quoteColor!) : scheme.onSurface,
              codeBackground: scheme.surfaceContainerLowest,
              codeForeground: scheme.onSurface,
              link: scheme.primary,
              wraps: [rule],
            ),
          ),
        ),
      ),
    );
  }
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rule = _rule;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.initial == null ? 'New wrapping rule' : 'Wrapping rule',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: _symbolField(_start, 'Start symbol', '<')),
                const SizedBox(width: 12),
                Expanded(child: _symbolField(_end, 'End symbol', '>')),
              ],
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _hide,
              onChanged: (v) => setState(() => _hide = v),
              title: const Text('Hide the symbols'),
              subtitle:
                  const Text('Off keeps them in the message, the way quotes do'),
            ),
            _colourRow(scheme),
            if (rule.isValid && rule.start == rule.end)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'The same symbol both ends, so it only pairs at the edges of '
                  'a word — a contraction like "don\'t" is left alone.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ),
            const SizedBox(height: 12),
            _preview(rule),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed:
                      rule.isValid ? () => Navigator.of(context).pop(rule) : null,
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _colourRow(ColorScheme scheme) => ListTile(
        contentPadding: EdgeInsets.zero,
        onTap: _pickColour,
        leading: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: _color != null ? Color(_color!) : scheme.onSurface,
            shape: BoxShape.circle,
            border: Border.all(color: scheme.outlineVariant),
          ),
        ),
        title: const Text('Colour'),
        subtitle:
            Text(_color == null ? 'Follows the text' : hexOf(Color(_color!))),
        trailing: _color == null
            ? null
            : IconButton(
                tooltip: 'Follow the text',
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => _color = null),
              ),
      );
}






