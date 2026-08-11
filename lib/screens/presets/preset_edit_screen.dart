import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/preset.dart';
import '../../models/provider.dart';
import '../../services/chat_client.dart';
import '../../state/app_state.dart';
import '../../widgets/color_picker.dart';
import 'advanced_section.dart';
import 'general_section.dart';
import 'preset_pickers.dart';
import 'prompt_section.dart';

/// The preset editor. A fixed header (name, provider + model on one line, a
/// discrete colour dot, and a Simple/Advanced toggle) sits above a tabbed area
/// that slides between General, Prompt, and — in Advanced mode — Advanced.
class PresetEditScreen extends StatefulWidget {
  const PresetEditScreen({super.key, required this.presetId});

  final String presetId;

  @override
  State<PresetEditScreen> createState() => _PresetEditScreenState();
}

class _PresetEditScreenState extends State<PresetEditScreen> {
  late Preset _p;
  late final TextEditingController _name;
  bool _missing = false;

  @override
  void initState() {
    super.initState();
    final stored = context.read<AppState>().presetById(widget.presetId);
    if (stored == null) {
      _missing = true;
      _p = Preset.create();
    } else {
      _p = Preset.fromJson(stored.toJson()); // deep copy; edits commit explicitly
    }
    _name = TextEditingController(text: _p.name)
      ..addListener(() {
        _p.name = _name.text;
        _commit();
      });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

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

  // --- pickers -------------------------------------------------------------

  Future<void> _pickProvider() async {
    final state = context.read<AppState>();
    final entries = <PickerEntry>[
      const PickerEntry(id: '', title: 'Active provider', subtitle: 'Use the app\'s active provider'),
      for (final p in state.providers)
        PickerEntry(id: p.id, title: p.displayName, subtitle: '${p.kind.label} · ${p.model.isEmpty ? 'no model' : p.model}'),
    ];
    final chosen = await showSearchPicker(
      context: context,
      title: 'Choose provider',
      entries: entries,
      selectedId: _p.providerId ?? '',
    );
    if (chosen == null) return;
    _change(() => _p.providerId = chosen.isEmpty ? null : chosen);
  }

  Future<void> _pickModel() async {
    final state = context.read<AppState>();
    final provider = _resolvedProvider;
    if (provider == null) {
      _toast('Add a provider first.');
      return;
    }
    final chosen = await showSearchPicker(
      context: context,
      title: 'Choose model',
      entries: [
        for (final m in state.cachedModels(provider.id)) PickerEntry(id: m, title: m),
      ],
      selectedId: _p.model,
      allowCustom: true,
      // Fetch once when nothing is cached; the refresh button re-fetches.
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
    if (chosen == null) return;
    _change(() => _p.model = chosen);
  }

  Future<void> _pickColor() async {
    final current = _p.colorBand != null ? Color(_p.colorBand!) : null;
    final result = await showDialog<_ColorResult>(
      context: context,
      builder: (context) => _ColorPickerDialog(current: current),
    );
    if (result == null) return;
    _change(() => _p.colorBand = result.cleared ? null : result.color!.toARGB32());
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
    final advanced = _p.mode == PresetMode.advanced;
    final tabCount = advanced ? 3 : 2;

    final providerLabel = _p.providerId == null
        ? 'Active provider'
        : (_providerName(state) ?? 'Unknown provider');
    final modelLabel = _p.model.trim().isEmpty ? 'Default' : _p.model.trim();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit preset'),
        actions: [
          IconButton(
            tooltip: 'Set as default',
            icon: Icon(state.defaultPresetId == _p.id ? Icons.star : Icons.star_border),
            onPressed: () => state.setDefaultPreset(_p.id),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Column(
              children: [
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    prefixIcon: Icon(Icons.label_outline),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                // Provider + model share one line.
                Row(
                  children: [
                    Expanded(
                      child: _PickerField(
                        label: 'Provider',
                        value: providerLabel,
                        icon: Icons.dns_outlined,
                        onTap: _pickProvider,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _PickerField(
                        label: 'Model',
                        value: modelLabel,
                        icon: Icons.memory_outlined,
                        onTap: _pickModel,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _ColorDot(
                      color: _p.colorBand != null ? Color(_p.colorBand!) : null,
                      onTap: _pickColor,
                    ),
                    const SizedBox(width: 8),
                    Text('Colour', style: Theme.of(context).textTheme.bodyMedium),
                    const Spacer(),
                    SegmentedButton<PresetMode>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: PresetMode.simple, label: Text('Simple')),
                        ButtonSegment(value: PresetMode.advanced, label: Text('Advanced')),
                      ],
                      selected: {_p.mode},
                      onSelectionChanged: (s) => _change(() => _p.mode = s.first),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: DefaultTabController(
              // Rebuild the controller when the tab count changes with the mode.
              key: ValueKey(tabCount),
              length: tabCount,
              child: Column(
                children: [
                  TabBar(
                    tabs: [
                      const Tab(text: 'General'),
                      const Tab(text: 'Prompt'),
                      if (advanced) const Tab(text: 'Advanced'),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _scroll(GeneralSection(preset: _p, onChanged: _commit)),
                        _scroll(PromptSection(preset: _p, onChanged: _commit)),
                        if (advanced)
                          _scroll(AdvancedSection(preset: _p, onChanged: _commit)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String? _providerName(AppState state) {
    for (final p in state.providers) {
      if (p.id == _p.providerId) return p.displayName;
    }
    return null;
  }

  Widget _scroll(Widget child) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          16, 12, 16, 24 + MediaQuery.paddingOf(context).bottom,
        ),
        child: child,
      );
}

/// A compact tappable field showing a label and current value with a chevron —
/// used for the provider and model pickers so they fit one line.
class _PickerField extends StatelessWidget {
  const _PickerField({
    required this.label,
    required this.value,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final String value;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          prefixIcon: Icon(icon, size: 20),
          suffixIcon: const Icon(Icons.expand_more),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        ),
        child: Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: scheme.onSurface),
        ),
      ),
    );
  }
}

/// A small colour circle for the discrete band picker; a dashed-look ring when
/// no band is set.
class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color, required this.onTap});

  final Color? color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: color ?? scheme.surfaceContainerHighest,
          shape: BoxShape.circle,
          border: Border.all(color: scheme.outline),
        ),
        child: color == null
            ? Icon(Icons.format_color_reset_outlined, size: 15, color: scheme.onSurfaceVariant)
            : null,
      ),
    );
  }
}

/// Result of the colour dialog: a chosen colour, or an explicit clear.
class _ColorResult {
  const _ColorResult({this.color, this.cleared = false});
  final Color? color;
  final bool cleared;
}

/// A compact dialog with the preset swatches and a "No band" option.
class _ColorPickerDialog extends StatelessWidget {
  const _ColorPickerDialog({required this.current});

  final Color? current;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Preset colour'),
      content: SizedBox(
        width: 320,
        child: ThemeColorPicker(
          value: current ?? Theme.of(context).colorScheme.primary,
          onChanged: (c) => Navigator.of(context).pop(_ColorResult(color: c)),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(const _ColorResult(cleared: true)),
          child: const Text('No band'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
