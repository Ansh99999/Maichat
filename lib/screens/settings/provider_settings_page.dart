import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/provider.dart';
import '../../services/chat_client.dart';
import '../../state/app_state.dart';
import '../../widgets/model_picker.dart';

/// Editor for a single provider: its name, API format, base URL, credential and
/// the model to talk to. Opened for a new provider (null) or an existing one.
class ProviderSettingsPage extends StatefulWidget {
  const ProviderSettingsPage({super.key, this.provider});

  final Provider? provider;

  @override
  State<ProviderSettingsPage> createState() => _ProviderSettingsPageState();
}

class _ProviderSettingsPageState extends State<ProviderSettingsPage> {
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;
  late ProviderKind _kind;
  bool _revealKey = false;
  bool _loadingModels = false;

  bool get _isNew => widget.provider == null;

  @override
  void initState() {
    super.initState();
    final p = widget.provider;
    _kind = p?.kind ?? ProviderKind.openai;
    _name = TextEditingController(text: p?.name ?? '');
    _baseUrl = TextEditingController(text: p?.baseUrl ?? _kind.defaultBaseUrl);
    _apiKey = TextEditingController(text: p?.apiKey ?? '');
    _model = TextEditingController(text: p?.model ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    super.dispose();
  }

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

  Provider get _current => Provider(
        id: widget.provider?.id ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        name: _name.text.trim(),
        kind: _kind,
        baseUrl: _baseUrl.text.trim().isEmpty
            ? _kind.defaultBaseUrl
            : _baseUrl.text.trim(),
        apiKey: _apiKey.text.trim(),
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

  /// Asks the host — using whatever is on screen — what models it can serve.
  Future<void> _browseModels() async {
    final state = context.read<AppState>();
    setState(() => _loadingModels = true);
    List<String>? models;
    String? error;
    try {
      models = await state.fetchModels(_current);
    } on ChatApiException catch (e) {
      error = e.message;
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
    if (!mounted) return;
    if (error != null || models == null) {
      _toast(error ?? 'Could not list models.');
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => ModelPicker(
        models: models!,
        selected: _model.text.trim(),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _model.text = picked);
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );
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
          const SizedBox(height: 20),
          Text('API format', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<ProviderKind>(
            segments: const [
              ButtonSegment(
                value: ProviderKind.openai,
                label: Text('OpenAI'),
                icon: Icon(Icons.api),
              ),
              ButtonSegment(
                value: ProviderKind.anthropic,
                label: Text('Anthropic'),
                icon: Icon(Icons.auto_awesome_outlined),
              ),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => _changeKind(s.first),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _baseUrl,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Base URL',
              hintText: _kind.defaultBaseUrl,
              helperText: _kind == ProviderKind.anthropic
                  ? 'Anthropic API root, usually ending in /v1'
                  : 'OpenAI-compatible root, usually ending in /v1',
              prefixIcon: const Icon(Icons.link),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _apiKey,
            obscureText: !_revealKey,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'API key',
              prefixIcon: const Icon(Icons.key_outlined),
              suffixIcon: IconButton(
                tooltip: _revealKey ? 'Hide key' : 'Show key',
                icon: Icon(
                  _revealKey
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
                onPressed: () => setState(() => _revealKey = !_revealKey),
              ),
            ),
          ),
          const SizedBox(height: 16),
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

  Widget _modelField() {
    return TextField(
      controller: _model,
      autocorrect: false,
      decoration: InputDecoration(
        labelText: 'Model',
        hintText: _kind == ProviderKind.anthropic
            ? 'claude-sonnet-4-5'
            : 'gpt-4o-mini',
        helperText: 'Type an id, or browse what the host offers',
        prefixIcon: const Icon(Icons.memory_outlined),
        suffixIcon: _loadingModels
            ? const Padding(
                padding: EdgeInsets.all(14),
                child: SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : IconButton(
                tooltip: 'Browse models',
                icon: const Icon(Icons.expand_more),
                onPressed: _browseModels,
              ),
      ),
    );
  }
}
