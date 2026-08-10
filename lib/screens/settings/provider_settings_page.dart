import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/settings.dart';
import '../../services/chat_client.dart';
import '../../state/app_state.dart';
import 'setting_anchors.dart';
import 'setting_highlight.dart';

/// Where the endpoint lives: base URL, credential and the model to talk to.
///
/// [highlight] is set when the user arrived here from a search result, so the
/// matching field is focused and flashed.
class ProviderSettingsPage extends StatefulWidget {
  const ProviderSettingsPage({super.key, this.highlight});

  final SettingAnchor? highlight;

  @override
  State<ProviderSettingsPage> createState() => _ProviderSettingsPageState();
}

class _ProviderSettingsPageState extends State<ProviderSettingsPage> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;
  final FocusNode _baseUrlFocus = FocusNode();
  final FocusNode _apiKeyFocus = FocusNode();
  final FocusNode _modelFocus = FocusNode();
  bool _revealKey = false;
  bool _loadingModels = false;

  @override
  void initState() {
    super.initState();
    final settings = context.read<AppState>().settings;
    _baseUrl = TextEditingController(text: settings.baseUrl);
    _apiKey = TextEditingController(text: settings.apiKey);
    _model = TextEditingController(text: settings.model);
    // Land the cursor on whatever the search sent us to.
    final focus = switch (widget.highlight) {
      SettingAnchor.baseUrl => _baseUrlFocus,
      SettingAnchor.apiKey => _apiKeyFocus,
      SettingAnchor.model => _modelFocus,
      _ => null,
    };
    if (focus != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    _baseUrlFocus.dispose();
    _apiKeyFocus.dispose();
    _modelFocus.dispose();
    super.dispose();
  }

  AppSettings get _current => AppSettings(
        baseUrl: _baseUrl.text.trim().isEmpty
            ? AppSettings.defaultBaseUrl
            : _baseUrl.text.trim(),
        apiKey: _apiKey.text.trim(),
        model: _model.text.trim(),
      );

  Future<void> _save() => context.read<AppState>().updateSettings(_current);

  /// Persists what is on screen, then asks the host what it can serve.
  Future<void> _browseModels() async {
    final state = context.read<AppState>();
    setState(() => _loadingModels = true);
    await state.updateSettings(_current);
    List<String>? models;
    String? error;
    try {
      models = await state.fetchModels();
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
      builder: (context) => _ModelPicker(
        models: models!,
        selected: _model.text.trim(),
      ),
    );
    if (picked == null || !mounted) return;
    _model.text = picked;
    await _save();
    if (mounted) _toast('Model set to $picked');
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Provider')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          SettingHighlight(
            active: widget.highlight == SettingAnchor.baseUrl,
            child: TextField(
              controller: _baseUrl,
              focusNode: _baseUrlFocus,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: AppSettings.defaultBaseUrl,
                helperText: 'OpenAI-compatible root, usually ending in /v1',
                prefixIcon: Icon(Icons.link),
              ),
            ),
          ),
          const SizedBox(height: 16),
          SettingHighlight(
            active: widget.highlight == SettingAnchor.apiKey,
            child: TextField(
              controller: _apiKey,
              focusNode: _apiKeyFocus,
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
          ),
          const SizedBox(height: 16),
          SettingHighlight(
            active: widget.highlight == SettingAnchor.model,
            child: _modelField(),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () async {
              await _save();
              if (mounted) _toast('Saved');
            },
            icon: const Icon(Icons.check),
            label: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Widget _modelField() {
    return TextField(
      controller: _model,
      focusNode: _modelFocus,
      autocorrect: false,
      decoration: InputDecoration(
        labelText: 'Model',
        hintText: 'gpt-4o-mini',
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

/// Bottom sheet listing the host's model ids, with a filter box because some
/// endpoints return hundreds.
class _ModelPicker extends StatefulWidget {
  const _ModelPicker({required this.models, required this.selected});

  final List<String> models;
  final String selected;

  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final needle = _filter.trim().toLowerCase();
    final visible = needle.isEmpty
        ? widget.models
        : widget.models
            .where((m) => m.toLowerCase().contains(needle))
            .toList(growable: false);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: TextField(
                  autofocus: false,
                  decoration: const InputDecoration(
                    labelText: 'Filter',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                  ),
                  onChanged: (value) => setState(() => _filter = value),
                ),
              ),
              Expanded(child: _list(visible)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _list(List<String> visible) {
    if (visible.isEmpty) {
      return const Center(child: Text('Nothing matches that filter'));
    }
    return ListView.builder(
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final model = visible[index];
        final isSelected = model == widget.selected;
        return ListTile(
          title: Text(model),
          selected: isSelected,
          trailing: isSelected ? const Icon(Icons.check) : null,
          onTap: () => Navigator.of(context).pop(model),
        );
      },
    );
  }
}
