import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/model_pricing.dart';
import '../../state/app_state.dart';
import '../presets/preset_pickers.dart';
import 'provider_draft.dart';

/// The settings you configure once and then forget: what each model costs, what
/// to fall back to when one fails, and any headers to send alongside.
class ProviderAdvancedTab extends StatefulWidget {
  const ProviderAdvancedTab({
    super.key,
    required this.draft,
    required this.onChanged,
  });

  final ProviderDraft draft;
  final VoidCallback onChanged;

  @override
  State<ProviderAdvancedTab> createState() => _ProviderAdvancedTabState();
}

class _ProviderAdvancedTabState extends State<ProviderAdvancedTab> {
  ProviderDraft get _draft => widget.draft;

  void _edited(VoidCallback change) {
    setState(change);
    widget.onChanged();
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.fromLTRB(
        16,
        4,
        16,
        96 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        _label('MODEL PRICES'),
        _pricesHint(),
        for (var i = 0; i < _draft.prices.length; i++)
          _PriceCard(
            key: ValueKey<int>(i),
            price: _draft.prices[i],
            onChanged: (next) => _edited(() => _draft.prices[i] = next),
            onRemove: () => _edited(() => _draft.prices.removeAt(i)),
            onPickModel: () => _pickPriceModel(i),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _addPrice,
            icon: const Icon(Icons.add),
            label: const Text('Add a model price'),
          ),
        ),
        _label('FALLBACK CHAIN'),
        _fallbackHint(),
        _fallbackList(),
        _label('HEADERS'),
        _claudeCodeSwitch(),
        _customHeaders(),
      ],
    );
  }

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
        ),
      );

  Widget _pricesHint() => _hint(
        'Prices are per provider, because the same model costs different amounts '
        'at different hosts. A model with no price here shows as “—” in Costs '
        'rather than as free.',
      );

  Widget _fallbackHint() => _hint(
        'If the chosen model fails, these are tried in order — but only while '
        'nothing has arrived yet. Once a reply has started it is kept, and the '
        'error is shown instead of restarting.',
      );

  void _addPrice() {
    _edited(() => _draft.prices.add(
          ModelPrice(model: _draft.model.text.trim()),
        ));
  }

  Future<void> _pickPriceModel(int index) async {
    final chosen = await _pickAModel(_draft.prices[index].model);
    if (chosen == null) return;
    _edited(() => _draft.prices[index] =
        _draft.prices[index].copyWith(model: chosen));
  }

  /// The shared model picker, over whatever this provider has cached.
  Future<String?> _pickAModel(String selected) async {
    final state = context.read<AppState>();
    return showSearchPicker(
      context: context,
      title: 'Choose model',
      entries: [
        for (final model in state.cachedModels(_draft.id))
          PickerEntry(id: model, title: model),
      ],
      selectedId: selected,
      allowCustom: true,
    );
  }

  /// The chain, reorderable because the order *is* the setting.
  Widget _fallbackList() {
    if (_draft.fallbackModels.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _addFallback,
          icon: const Icon(Icons.add),
          label: const Text('Add a fallback model'),
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: _draft.fallbackModels.length,
          onReorderItem: (from, to) => _edited(() {
            final moved = _draft.fallbackModels.removeAt(from);
            _draft.fallbackModels.insert(to, moved);
          }),
          itemBuilder: (context, index) {
            final model = _draft.fallbackModels[index];
            return Card(
              key: ValueKey<String>('$index:$model'),
              elevation: 0,
              color: scheme.surfaceContainerLow,
              child: ListTile(
                leading: ReorderableDragStartListener(
                  index: index,
                  child: const Icon(Icons.drag_handle),
                ),
                title: Text(model, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('Try ${index + 1}${index == 0 ? 'st' : index == 1 ? 'nd' : index == 2 ? 'rd' : 'th'}'),
                trailing: IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () =>
                      _edited(() => _draft.fallbackModels.removeAt(index)),
                ),
              ),
            );
          },
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _addFallback,
            icon: const Icon(Icons.add),
            label: const Text('Add another'),
          ),
        ),
      ],
    );
  }

  Future<void> _addFallback() async {
    final chosen = await _pickAModel('');
    if (chosen == null || chosen.trim().isEmpty) return;
    _edited(() => _draft.fallbackModels.add(chosen.trim()));
  }

  /// Claude Code's own identifying headers.
  ///
  /// The switch is honest about what it is for rather than dressing it up: it
  /// makes requests look like they came from a different client, which is the
  /// sort of thing a vendor's terms have an opinion about.
  Widget _claudeCodeSwitch() {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Column(
        children: [
          SwitchListTile(
            value: _draft.claudeCodeHeaders,
            onChanged: (on) => _edited(() => _draft.claudeCodeHeaders = on),
            title: const Text('Send Claude Code headers'),
            subtitle: const Text(
              'Identifies requests as coming from the Claude Code CLI.',
            ),
          ),
          if (_draft.claudeCodeHeaders)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Presenting as another client may breach a vendor’s terms '
                      'of use, and it does not grant access you do not already '
                      'have. Your key still decides what you can call.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.4,
                          ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Arbitrary headers, merged last so they can override anything the app sends.
  Widget _customHeaders() {
    final scheme = Theme.of(context).colorScheme;
    final entries = _draft.customHeaders.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        for (final entry in entries)
          Card(
            elevation: 0,
            color: scheme.surfaceContainerLow,
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.label_outline),
              title: Text(entry.key),
              subtitle: Text(
                // A header that looks like a credential is masked in the list
                // for the same reason the request preview redacts it.
                _looksSecret(entry.key) ? '••••••••' : entry.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: () =>
                    _edited(() => _draft.customHeaders.remove(entry.key)),
              ),
              onTap: () => _editHeader(entry.key, entry.value),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _editHeader('', ''),
            icon: const Icon(Icons.add),
            label: const Text('Add a header'),
          ),
        ),
      ],
    );
  }

  static bool _looksSecret(String name) =>
      RegExp(r'key|token|secret|auth|cookie|password')
          .hasMatch(name.toLowerCase());

  Future<void> _editHeader(String name, String value) async {
    final nameField = TextEditingController(text: name);
    final valueField = TextEditingController(text: value);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(name.isEmpty ? 'Add header' : 'Edit header'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameField,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'x-my-header',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: valueField,
              autocorrect: false,
              maxLines: 3,
              minLines: 1,
              decoration: const InputDecoration(labelText: 'Value'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    final nextName = nameField.text.trim();
    final nextValue = valueField.text.trim();
    nameField.dispose();
    valueField.dispose();
    if (saved != true || nextName.isEmpty) return;
    _edited(() {
      // A rename is a remove plus an add, or the old name lingers.
      if (name.isNotEmpty && name != nextName) {
        _draft.customHeaders.remove(name);
      }
      _draft.customHeaders[nextName] = nextValue;
    });
  }
}

/// One priced model: which model, how it is charged, and the rates.
class _PriceCard extends StatefulWidget {
  const _PriceCard({
    super.key,
    required this.price,
    required this.onChanged,
    required this.onRemove,
    required this.onPickModel,
  });

  final ModelPrice price;
  final ValueChanged<ModelPrice> onChanged;
  final VoidCallback onRemove;
  final VoidCallback onPickModel;

  @override
  State<_PriceCard> createState() => _PriceCardState();
}

class _PriceCardState extends State<_PriceCard> {
  late final TextEditingController _input =
      TextEditingController(text: _text(widget.price.input));
  late final TextEditingController _output =
      TextEditingController(text: _text(widget.price.output));

  /// A zero price shows as an empty field, not "0.0" — the field being blank is
  /// how "I have not set this" reads.
  static String _text(double value) => value == 0 ? '' : _trim(value);

  /// Drops the trailing zeros a double prints, so 3.0 shows as "3".
  static String _trim(double value) {
    var s = value.toStringAsFixed(6);
    s = s.replaceFirst(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    return s;
  }

  @override
  void dispose() {
    _input.dispose();
    _output.dispose();
    super.dispose();
  }

  void _push() => widget.onChanged(widget.price.copyWith(
        input: double.tryParse(_input.text.trim()) ?? 0,
        output: double.tryParse(_output.text.trim()) ?? 0,
      ));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final price = widget.price;
    final perRequest = price.mode == PriceMode.perRequest;

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: widget.onPickModel,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          const Icon(Icons.memory_outlined, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              price.model.trim().isEmpty
                                  ? 'Choose a model'
                                  : price.model,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: price.model.trim().isEmpty
                                    ? scheme.onSurfaceVariant
                                    : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove price',
                  icon: const Icon(Icons.remove_circle_outline, size: 20),
                  onPressed: widget.onRemove,
                ),
              ],
            ),
            const SizedBox(height: 4),
            SegmentedButton<PriceMode>(
              showSelectedIcon: false,
              segments: [
                for (final mode in PriceMode.values)
                  ButtonSegment<PriceMode>(value: mode, label: Text(mode.label)),
              ],
              selected: <PriceMode>{price.mode},
              onSelectionChanged: (next) =>
                  widget.onChanged(price.copyWith(mode: next.first)),
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const SizedBox(height: 12),
            _rates(perRequest),
          ],
        ),
      ),
    );
  }

  /// Two rate fields, or one flat charge. Per-request has no output half — the
  /// charge does not depend on how much came back.
  Widget _rates(bool perRequest) {
    if (perRequest) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: TextField(
          controller: _input,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Per request',
            prefixText: '\$ ',
            isDense: true,
          ),
          onChanged: (_) => _push(),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Input / 1M',
                prefixText: '\$ ',
                isDense: true,
              ),
              onChanged: (_) => _push(),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _output,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Output / 1M',
                prefixText: '\$ ',
                isDense: true,
              ),
              onChanged: (_) => _push(),
            ),
          ),
        ],
      ),
    );
  }
}
