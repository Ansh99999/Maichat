import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/preset.dart';
import '../../models/provider.dart';
import '../../services/chat_client.dart';
import '../../state/app_state.dart';
import '../../widgets/color_picker.dart';
import '../../widgets/model_picker.dart';
import 'advanced_section.dart';
import 'general_section.dart';
import 'prompt_section.dart';

/// The preset editor. Top to bottom: an editable name, the provider and model
/// it runs on, a colour band, a thin divider, then a Simple/Advanced mode
/// toggle that gates which sections show. Simple exposes General + Prompt;
/// Advanced adds the extra samplers, toggles and context budget.
class PresetEditScreen extends StatefulWidget {
  const PresetEditScreen({super.key, required this.presetId});

  final String presetId;

  @override
  State<PresetEditScreen> createState() => _PresetEditScreenState();
}

class _PresetEditScreenState extends State<PresetEditScreen> {
  late Preset _p;
  late final TextEditingController _name;
  late final TextEditingController _model;
  bool _loadingModels = false;
  bool _missing = false;

  @override
  void initState() {
    super.initState();
    final stored = context.read<AppState>().presetById(widget.presetId);
    if (stored == null) {
      _missing = true;
      _p = Preset.create();
    } else {
      // Work on a deep copy so edits commit explicitly.
      _p = Preset.fromJson(stored.toJson());
    }
    _name = TextEditingController(text: _p.name)
      ..addListener(() {
        _p.name = _name.text;
        _commit();
      });
    _model = TextEditingController(text: _p.model)
      ..addListener(() {
        _p.model = _model.text;
        _commit();
      });
  }

  @override
  void dispose() {
    _name.dispose();
    _model.dispose();
    super.dispose();
  }

  /// Persists the working copy. Cheap enough for a personal, on-device store.
  void _commit() {
    if (_missing) return;
    context.read<AppState>().savePreset(_p);
  }

  void _change(VoidCallback mutate) {
    setState(mutate);
    _commit();
  }

  Provider? get _resolvedProvider {
    final state = context.read<AppState>();
    if (_p.providerId != null) {
      for (final p in state.providers) {
        if (p.id == _p.providerId) return p;
      }
    }
    return state.activeProvider;
  }

  Future<void> _browseModels() async {
    final provider = _resolvedProvider;
    if (provider == null) {
      _toast('Add a provider first.');
      return;
    }
    setState(() => _loadingModels = true);
    List<String>? models;
    String? error;
    try {
      models = await context.read<AppState>().fetchModels(provider);
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
      builder: (_) => ModelPicker(models: models!, selected: _model.text.trim()),
    );
    if (picked != null && mounted) _model.text = picked;
  }

  void _toast(String message) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );

  // PLACEHOLDER_BUILD
  @override
  Widget build(BuildContext context) {
    if (_missing) {
      return Scaffold(
        appBar: AppBar(title: const Text('Preset')),
        body: const Center(child: Text('This preset no longer exists.')),
      );
    }
    final state = context.watch<AppState>();
    final bottom = MediaQuery.paddingOf(context).bottom;
    final band = _p.colorBand != null ? Color(_p.colorBand!) : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit preset'),
        actions: [
          IconButton(
            tooltip: 'Set as default',
            icon: Icon(
              state.defaultPresetId == _p.id ? Icons.star : Icons.star_border,
            ),
            onPressed: () => state.setDefaultPreset(_p.id),
          ),
        ],
      ),
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
          DropdownButtonFormField<String?>(
            initialValue: _p.providerId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Provider',
              prefixIcon: Icon(Icons.dns_outlined),
            ),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('Active provider'),
              ),
              for (final p in state.providers)
                DropdownMenuItem<String?>(
                  value: p.id,
                  child: Text(p.displayName, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => _change(() => _p.providerId = v),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _model,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Model',
              hintText: 'Leave blank to use the provider\'s model',
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
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Text('Colour band', style: Theme.of(context).textTheme.labelLarge),
              const Spacer(),
              if (band != null)
                TextButton(
                  onPressed: () => _change(() => _p.colorBand = null),
                  child: const Text('Clear'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          ThemeColorPicker(
            value: band ?? Theme.of(context).colorScheme.primary,
            onChanged: (c) => _change(() => _p.colorBand = c.toARGB32()),
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),
          SegmentedButton<PresetMode>(
            segments: const [
              ButtonSegment(value: PresetMode.simple, label: Text('Simple')),
              ButtonSegment(value: PresetMode.advanced, label: Text('Advanced')),
            ],
            selected: {_p.mode},
            onSelectionChanged: (s) => _change(() => _p.mode = s.first),
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: 'General',
            child: GeneralSection(preset: _p, onChanged: _commit),
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: 'Prompt',
            child: PromptSection(preset: _p, onChanged: _commit),
          ),
          if (_p.mode == PresetMode.advanced) ...[
            const SizedBox(height: 16),
            _SectionCard(
              title: 'Advanced',
              child: AdvancedSection(preset: _p, onChanged: _commit),
            ),
          ],
        ],
      ),
    );
  }
}

/// A titled container for one editor section.
class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: child,
          ),
        ),
      ],
    );
  }
}
