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

/// The reusable body of the preset editor: a header (name, provider + model on
/// one line, a discrete colour dot, and a Simple/Advanced toggle) above a
/// tabbed area that slides between General, Prompt and (in Advanced) Advanced.
///
/// It edits [preset] in place and calls [onChanged] after each change; it does
/// NOT persist — the host decides what saving means (commit to the library, or
/// hold as a chat override). Used full-screen by the presets editor and inside
/// the chat sidebar. Give it a `ValueKey(preset.id)` so switching presets
/// rebuilds its controllers.
class PresetEditorBody extends StatefulWidget {
  const PresetEditorBody({
    super.key,
    required this.preset,
    required this.onChanged,
    this.compact = false,
  });

  final Preset preset;
  final VoidCallback onChanged;

  /// Tightens paddings for the narrow chat sidebar.
  final bool compact;

  @override
  State<PresetEditorBody> createState() => _PresetEditorBodyState();
}

class _PresetEditorBodyState extends State<PresetEditorBody> {
  Preset get _p => widget.preset;
  late final TextEditingController _name;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: _p.name)
      ..addListener(() {
        _p.name = _name.text;
        widget.onChanged();
      });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _change(VoidCallback mutate) {
    setState(mutate);
    widget.onChanged();
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

  Future<void> _pickProvider() async {
    final state = context.read<AppState>();
    final chosen = await showSearchPicker(
      context: context,
      title: 'Choose provider',
      entries: [
        const PickerEntry(id: '', title: 'Active provider', subtitle: 'Use the app\'s active provider'),
        for (final p in state.providers)
          PickerEntry(id: p.id, title: p.displayName, subtitle: '${p.kind.label} · ${p.model.isEmpty ? 'no model' : p.model}'),
      ],
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
    final result = await showDialog<ColorPickResult>(
      context: context,
      builder: (context) => ColorPickerDialog(current: current),
    );
    if (result == null) return;
    _change(() => _p.colorBand = result.cleared ? null : result.color!.toARGB32());
  }

  void _toast(String message) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );

  String? _providerName(AppState state) {
    for (final p in state.providers) {
      if (p.id == _p.providerId) return p.displayName;
    }
    return null;
  }

  // PLACEHOLDER_BODY_BUILD
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final advanced = _p.mode == PresetMode.advanced;
    final tabCount = advanced ? 3 : 2;
    final pad = widget.compact ? 12.0 : 16.0;

    final providerLabel = _p.providerId == null
        ? 'Active provider'
        : (_providerName(state) ?? 'Unknown provider');
    final modelLabel = _p.model.trim().isEmpty ? 'Default' : _p.model.trim();

    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(pad, 8, pad, 4),
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
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: PickerField(
                      label: 'Provider',
                      value: providerLabel,
                      icon: Icons.dns_outlined,
                      onTap: _pickProvider,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: PickerField(
                      label: 'Model',
                      value: modelLabel,
                      icon: Icons.memory_outlined,
                      onTap: _pickModel,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  ColorDot(
                    color: _p.colorBand != null ? Color(_p.colorBand!) : null,
                    onTap: _pickColor,
                  ),
                  const SizedBox(width: 8),
                  if (!widget.compact)
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
            key: ValueKey(tabCount),
            length: tabCount,
            child: Column(
              children: [
                TabBar(
                  isScrollable: widget.compact,
                  tabAlignment: widget.compact ? TabAlignment.center : null,
                  tabs: [
                    const Tab(text: 'General'),
                    const Tab(text: 'Prompt'),
                    if (advanced) const Tab(text: 'Advanced'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _scroll(GeneralSection(preset: _p, onChanged: widget.onChanged), pad),
                      _scroll(PromptSection(preset: _p, onChanged: widget.onChanged), pad),
                      if (advanced)
                        _scroll(AdvancedSection(preset: _p, onChanged: widget.onChanged), pad),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _scroll(Widget child, double pad) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          pad, 12, pad, 24 + MediaQuery.paddingOf(context).bottom,
        ),
        child: child,
      );
}

/// A compact tappable field showing a label and current value with a chevron —
/// used for the provider and model pickers so they fit one line.
class PickerField extends StatelessWidget {
  const PickerField({
    super.key,
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

/// A small colour circle for the discrete band picker; a "no colour" glyph when
/// no band is set.
class ColorDot extends StatelessWidget {
  const ColorDot({super.key, required this.color, required this.onTap});

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
class ColorPickResult {
  const ColorPickResult({this.color, this.cleared = false});
  final Color? color;
  final bool cleared;
}

/// A compact dialog with the preset swatches and a "No band" option.
class ColorPickerDialog extends StatelessWidget {
  const ColorPickerDialog({super.key, required this.current});

  final Color? current;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Preset colour'),
      content: SizedBox(
        width: 320,
        child: ThemeColorPicker(
          value: current ?? Theme.of(context).colorScheme.primary,
          onChanged: (c) => Navigator.of(context).pop(ColorPickResult(color: c)),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(const ColorPickResult(cleared: true)),
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
