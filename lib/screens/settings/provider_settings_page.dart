import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/provider.dart';
import '../../services/chat_client.dart';
import '../../state/app_state.dart';
import '../presets/preset_pickers.dart';

/// Editor for a single provider: its name, API format, base URL, one or more
/// credentials and the model to talk to. Opened for a new provider (null) or an
/// existing one.
class ProviderSettingsPage extends StatefulWidget {
  const ProviderSettingsPage({super.key, this.provider});

  final Provider? provider;

  @override
  State<ProviderSettingsPage> createState() => _ProviderSettingsPageState();
}

class _ProviderSettingsPageState extends State<ProviderSettingsPage> {
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  late final List<TextEditingController> _keys;
  late ProviderKind _kind;
  late KeyRotationStrategy _keyStrategy;
  // Stable across rebuilds so the model cache keys consistently, even before a
  // brand-new provider is first saved.
  late final String _id;
  bool _revealKeys = false;

  bool get _isNew => widget.provider == null;

  @override
  void initState() {
    super.initState();
    final p = widget.provider;
    _id = p?.id ?? DateTime.now().microsecondsSinceEpoch.toString();
    _kind = p?.kind ?? ProviderKind.openai;
    _keyStrategy = p?.keyStrategy ?? KeyRotationStrategy.roundRobin;
    _name = TextEditingController(text: p?.name ?? '');
    _baseUrl = TextEditingController(text: p?.baseUrl ?? _kind.defaultBaseUrl);
    _model = TextEditingController(text: p?.model ?? '');
    _keys = [
      for (final key in p?.apiKeys ?? const <String>[])
        TextEditingController(text: key),
    ];
    // Always show at least one key row.
    if (_keys.isEmpty) _keys.add(TextEditingController());
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _model.dispose();
    for (final controller in _keys) {
      controller.dispose();
    }
    super.dispose();
  }

  // PLACEHOLDER-BODY

  /// Switching format swaps in that format's default base URL, but only when
  /// the field is still a default (never clobbering a URL the user typed).
  void _changeKind(ProviderKind next) {
    if (next == _kind) return;
    final current = _baseUrl.text.trim();
    final wasDefault = current.isEmpty ||
        ProviderKind.values.any((k) => k.defaultBaseUrl == current);
    setState(() {
      _kind = next;
      if (wasDefault) _baseUrl.text = next.defaultBaseUrl;
    });
  }

  void _addKey() => setState(() => _keys.add(TextEditingController()));

  void _removeKey(int index) {
    if (_keys.length <= 1) return;
    final removed = _keys.removeAt(index);
    removed.dispose();
    setState(() {});
  }

  Provider get _current => Provider(
        id: _id,
        name: _name.text.trim(),
        kind: _kind,
        baseUrl: _baseUrl.text.trim().isEmpty
            ? _kind.defaultBaseUrl
            : _baseUrl.text.trim(),
        apiKeys: [
          for (final controller in _keys)
            if (controller.text.trim().isNotEmpty) controller.text.trim(),
        ],
        keyStrategy: _keyStrategy,
        model: _model.text.trim(),
      );

  Future<void> _save() async {
    final state = context.read<AppState>();
    final provider = _current;
    if (_isNew) {
      await state.addProvider(provider);
    } else {
      await state.updateProvider(provider);
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final existing = widget.provider;
    if (existing == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete provider?'),
        content: Text('"${existing.displayName}" will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false) || !mounted) return;
    await context.read<AppState>().deleteProvider(existing.id);
    if (mounted) Navigator.of(context).pop();
  }

  /// Opens the cached model list, refreshing from the host only on demand so a
  /// request is not fired every time the picker is opened.
  Future<void> _pickModel() async {
    final state = context.read<AppState>();
    final provider = _current;
    final chosen = await showSearchPicker(
      context: context,
      title: 'Choose model',
      entries: [
        for (final m in state.cachedModels(provider.id))
          PickerEntry(id: m, title: m),
      ],
      selectedId: _model.text.trim(),
      allowCustom: true,
      onRefresh: () async {
        try {
          final models = await state.refreshModels(provider);
          return [for (final m in models) PickerEntry(id: m, title: m)];
        } on ChatApiException catch (e) {
          throw PickerRefreshException(e.message);
        }
      },
      refreshOnEmpty: state.cachedModels(provider.id).isEmpty,
    );
    if (chosen == null || !mounted) return;
    setState(() => _model.text = chosen);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'Add provider' : 'Edit provider'),
        actions: [
          if (!_isNew)
            IconButton(
              tooltip: 'Delete provider',
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          TextField(
            controller: _name,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'My provider',
              helperText: 'Shown when you pick a provider',
              prefixIcon: Icon(Icons.badge_outlined),
            ),
          ),
          const SizedBox(height: 16),
          _formatField(),
          const SizedBox(height: 16),
          TextField(
            controller: _baseUrl,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Base URL',
              hintText: _kind.defaultBaseUrl,
              helperText: _baseHelper,
              prefixIcon: const Icon(Icons.link),
            ),
          ),
          const SizedBox(height: 20),
          _keysSection(),
          const SizedBox(height: 20),
          _modelField(),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.check),
            label: Text(_isNew ? 'Add provider' : 'Save'),
          ),
        ],
      ),
    );
  }

  String get _baseHelper => _kind.baseUrlHelper;

  /// A compact dropdown for the API format — discrete, unlike a full-width
  /// segmented button, while still offering all three custom formats.
  Widget _formatField() {
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'API format',
        prefixIcon: Icon(Icons.cable),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<ProviderKind>(
          isExpanded: true,
          value: _kind,
          borderRadius: BorderRadius.circular(12),
          onChanged: (next) {
            if (next != null) _changeKind(next);
          },
          items: [
            for (final kind in ProviderKind.values)
              DropdownMenuItem<ProviderKind>(
                value: kind,
                child: Text(kind.label),
              ),
          ],
        ),
      ),
    );
  }

  Widget _keysSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < _keys.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _keyField(i),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _addKey,
            icon: const Icon(Icons.add),
            label: const Text('Add another key'),
          ),
        ),
        if (_keys.length > 1) ...[
          const SizedBox(height: 4),
          _strategyField(),
          const SizedBox(height: 4),
          Text(
            'Extra keys share the load using the strategy above.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ],
    );
  }

  Widget _keyField(int index) {
    final primary = index == 0;
    return TextField(
      controller: _keys[index],
      obscureText: !_revealKeys,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: primary ? 'API key' : 'API key ${index + 1}',
        prefixIcon: Icon(primary ? Icons.key_outlined : Icons.vpn_key_outlined),
        suffixIcon: primary
            ? IconButton(
                tooltip: _revealKeys ? 'Hide keys' : 'Show keys',
                icon: Icon(
                  _revealKeys
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
                onPressed: () => setState(() => _revealKeys = !_revealKeys),
              )
            : IconButton(
                tooltip: 'Remove key',
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: () => _removeKey(index),
              ),
      ),
    );
  }

  Widget _strategyField() {
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Key rotation',
        prefixIcon: Icon(Icons.sync),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<KeyRotationStrategy>(
          isExpanded: true,
          value: _keyStrategy,
          borderRadius: BorderRadius.circular(12),
          onChanged: (next) {
            if (next != null) setState(() => _keyStrategy = next);
          },
          items: [
            for (final strategy in KeyRotationStrategy.values)
              DropdownMenuItem<KeyRotationStrategy>(
                value: strategy,
                child: Text(strategy.label),
              ),
          ],
        ),
      ),
    );
  }

  Widget _modelField() {
    return TextField(
      controller: _model,
      autocorrect: false,
      readOnly: true,
      onTap: _pickModel,
      decoration: InputDecoration(
        labelText: 'Model',
        hintText: _kind.modelHint,
        helperText: 'Tap to pick; refresh inside to fetch the latest list',
        prefixIcon: const Icon(Icons.memory_outlined),
        suffixIcon: IconButton(
          tooltip: 'Choose model',
          icon: const Icon(Icons.expand_more),
          onPressed: _pickModel,
        ),
      ),
    );
  }
}
