import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/provider.dart';
import '../../models/provider_template.dart';
import '../../services/chat_client.dart';
import '../../state/app_state.dart';
import '../presets/preset_pickers.dart';
import '../settings/tokenizer_settings_page.dart';
import 'provider_draft.dart';
import 'provider_keys_section.dart';

/// What you need to talk to a host at all: a name, the format it speaks, its
/// address, the credentials, and which model to use.
class ProviderBasicTab extends StatefulWidget {
  const ProviderBasicTab({
    super.key,
    required this.draft,
    required this.onChanged,
  });

  final ProviderDraft draft;
  final VoidCallback onChanged;

  @override
  State<ProviderBasicTab> createState() => _ProviderBasicTabState();
}

class _ProviderBasicTabState extends State<ProviderBasicTab> {
  ProviderDraft get _draft => widget.draft;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        // Clear of the save button, not just the system inset.
        96 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        TextField(
          controller: _draft.name,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'My provider',
            helperText: 'Shown wherever you pick a provider',
            prefixIcon: Icon(Icons.badge_outlined),
          ),
          onChanged: (_) => widget.onChanged(),
        ),
        const SizedBox(height: 16),
        _FormatField(
          kind: _draft.kind,
          onKind: (kind) {
            setState(() => _draft.changeKind(kind));
            widget.onChanged();
          },
          onTemplate: _applyTemplate,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _draft.baseUrl,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'Base URL',
            hintText: _draft.kind.defaultBaseUrl,
            helperText: _draft.kind.baseUrlHelper,
            helperMaxLines: 2,
            prefixIcon: const Icon(Icons.link),
          ),
          onChanged: (_) => widget.onChanged(),
        ),
        const SizedBox(height: 20),
        ProviderKeysSection(draft: _draft, onChanged: widget.onChanged),
        const SizedBox(height: 20),
        _modelField(),
        const SizedBox(height: 24),
        _tokenizerButton(),
      ],
    );
  }

  /// Applies a ready-made host: format and address always, and the name only
  /// while it is still untouched, so picking a template never renames a provider
  /// the user has already named.
  void _applyTemplate(ProviderTemplate template) {
    final currentName = _draft.name.text.trim();
    final nameWasDefault = currentName.isEmpty ||
        ProviderKind.values.any((k) => k.label == currentName) ||
        kProviderTemplates.any((t) => t.label == currentName);
    setState(() {
      _draft.kind = template.kind;
      _draft.baseUrl.text = template.baseUrl;
      if (nameWasDefault) _draft.name.text = template.label;
      if (template.defaultModel.isNotEmpty && _draft.model.text.trim().isEmpty) {
        _draft.model.text = template.defaultModel;
      }
    });
    widget.onChanged();
  }

  /// Opens the cached model list, fetching from the host only on demand so a
  /// request is not fired every time the picker opens.
  Future<void> _pickModel() async {
    final state = context.read<AppState>();
    final provider = _draft.toProvider();
    final chosen = await showSearchPicker(
      context: context,
      title: 'Choose model',
      entries: [
        for (final model in state.cachedModels(provider.id))
          PickerEntry(id: model, title: model),
      ],
      selectedId: _draft.model.text.trim(),
      allowCustom: true,
      onRefresh: () async {
        try {
          final models = await state.refreshModels(provider);
          return [for (final model in models) PickerEntry(id: model, title: model)];
        } on ChatApiException catch (e) {
          throw PickerRefreshException(e.message);
        }
      },
      refreshOnEmpty: state.cachedModels(provider.id).isEmpty,
    );
    if (chosen == null || !mounted) return;
    setState(() => _draft.model.text = chosen);
    widget.onChanged();
  }

  Widget _modelField() => TextField(
        controller: _draft.model,
        autocorrect: false,
        readOnly: true,
        onTap: _pickModel,
        decoration: InputDecoration(
          labelText: 'Model',
          hintText: _draft.kind.modelHint,
          helperText: 'Tap to pick; refresh inside to fetch the latest list',
          prefixIcon: const Icon(Icons.memory_outlined),
          suffixIcon: IconButton(
            tooltip: 'Choose model',
            icon: const Icon(Icons.expand_more),
            onPressed: _pickModel,
          ),
        ),
      );

  /// The tokenizer is a provider-adjacent setting rather than a provider field —
  /// it is app-wide — so it is a door out of this tab rather than a control in it.
  Widget _tokenizerButton() {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const TokenizerSettingsPage(),
          ),
        ),
        icon: const Icon(Icons.calculate_outlined),
        label: Text('Tokenizer · ${state.tokenizerConfig.kind.label}'),
        style: OutlinedButton.styleFrom(foregroundColor: scheme.onSurface),
      ),
    );
  }
}

/// The API-format picker: the dialects on top, ready-made hosts under them.
///
/// A [DropdownButton] cannot render section headings, and with six formats plus
/// six templates one flat list of twelve is a worse thing to read than two
/// labelled groups of six. [MenuAnchor] can, so this is a menu dressed as a
/// field.
class _FormatField extends StatelessWidget {
  const _FormatField({
    required this.kind,
    required this.onKind,
    required this.onTemplate,
  });

  final ProviderKind kind;
  final ValueChanged<ProviderKind> onKind;
  final ValueChanged<ProviderTemplate> onTemplate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MenuAnchor(
      style: const MenuStyle(alignment: Alignment.bottomLeft),
      builder: (context, controller, _) => InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () =>
            controller.isOpen ? controller.close() : controller.open(),
        child: InputDecorator(
          decoration: const InputDecoration(
            labelText: 'API format',
            prefixIcon: Icon(Icons.cable),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 16),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  kind.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
              Icon(Icons.expand_more, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
      menuChildren: [
        _heading(context, 'FORMATS'),
        for (final value in ProviderKind.values)
          MenuItemButton(
            leadingIcon: Icon(
              value == kind ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 18,
              color: value == kind ? scheme.primary : scheme.onSurfaceVariant,
            ),
            onPressed: () => onKind(value),
            child: Text(value.label),
          ),
        const Divider(height: 8),
        _heading(context, 'READY-MADE'),
        for (final template in kProviderTemplates)
          MenuItemButton(
            leadingIcon: const Icon(Icons.bolt_outlined, size: 18),
            onPressed: () => onTemplate(template),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(template.label),
                if (template.blurb.isNotEmpty)
                  Text(
                    template.blurb,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _heading(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
        ),
      );
}
