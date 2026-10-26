import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/chat_tool.dart';
import '../../models/conversation.dart';
import '../../state/app_state.dart';
import '../../widgets/chat_tool_results.dart';
import '../../widgets/export_sheet.dart';

/// Settings ▸ Tool calls, scoped by route.
///
/// With no [conversationId] this edits the app-wide library. With one it edits
/// that thread's own copy. Every save passes the same id back to AppState, so
/// a chat page can never quietly write to the global library or vice versa.
class ChatToolsPage extends StatelessWidget {
  const ChatToolsPage({super.key, this.conversationId});

  final String? conversationId;

  Future<void> _save(
    BuildContext context,
    AppState state,
    ChatToolConfig config,
  ) async {
    try {
      await state.saveChatToolConfig(config, conversationId: conversationId);
    } catch (error) {
      if (!context.mounted) return;
      _toast(
        context,
        'Could not save tool settings: ${_friendlyError(error)}',
        error: true,
      );
      return;
    }
    if (context.mounted) _toast(context, 'Tool settings saved');
  }

  Future<void> _toggle(
    BuildContext context,
    AppState state,
    ChatToolConfig config, {
    bool? enabled,
    String? tool,
    int? maxRounds,
    int? maxCalls,
    String? trackerPlacement,
  }) async {
    var disabled = config.disabledTools.toList();
    if (tool != null) {
      final isEnabled = !disabled.contains(tool);
      final shouldEnable = enabled ?? !isEnabled;
      disabled = shouldEnable
          ? disabled.where((name) => name != tool).toList()
          : [...disabled, tool];
    }
    final next = config.copyWith(
      enabled: enabled ?? config.enabled,
      disabledTools: List<String>.unmodifiable(disabled),
      maxRounds: maxRounds ?? config.maxRounds,
      maxCalls: maxCalls ?? config.maxCalls,
      trackerPlacement: trackerPlacement ?? config.trackerPlacement,
    );
    await _save(context, state, next);
  }

  Future<void> _saveCustom(
    BuildContext context,
    AppState state,
    ChatToolConfig config,
    ChatToolDefinition tool,
  ) async {
    final replacements = <String, ChatToolDefinition>{};
    for (final existing in config.customTools) {
      replacements[existing.name] = existing;
    }
    replacements[tool.name] = tool;
    final next = [
      for (final existing in config.customTools)
        replacements.remove(existing.name) ?? existing,
      if (replacements.containsKey(tool.name)) replacements.remove(tool.name)!,
    ];
    await _save(
      context,
      state,
      config.copyWith(
        customTools: List<ChatToolDefinition>.unmodifiable(next),
        disabledTools: List<String>.unmodifiable(
          config.disabledTools.where((name) => name != tool.name),
        ),
      ),
    );
  }

  Future<void> _deleteCustom(
    BuildContext context,
    AppState state,
    ChatToolConfig config,
    ChatToolDefinition tool,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${readableToolName(tool.name)}?'),
        content: const Text(
          'This custom tool definition is removed. Built-in operations stay '
          'available.',
        ),
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
    if (ok != true || !context.mounted) return;
    await _save(
      context,
      state,
      config.copyWith(
        customTools: List<ChatToolDefinition>.unmodifiable([
          for (final existing in config.customTools)
            if (existing.name != tool.name) existing,
        ]),
        disabledTools: List<String>.unmodifiable(
          config.disabledTools.where((name) => name != tool.name),
        ),
      ),
    );
  }

  Future<void> _import(BuildContext context, AppState state) async {
    final source = await _chooseImport(context);
    if (source == null) return;
    try {
      await state.importChatTools(source, conversationId: conversationId);
    } catch (error) {
      if (!context.mounted) return;
      _toast(context, 'Import failed: ${_friendlyError(error)}', error: true);
      return;
    }
    if (context.mounted) _toast(context, 'Tool definitions imported');
  }

  Future<String?> _chooseImport(BuildContext context) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.upload_file_outlined),
              title: const Text('Choose a .json file'),
              onTap: () => Navigator.of(context).pop('file'),
            ),
            ListTile(
              leading: const Icon(Icons.content_paste_outlined),
              title: const Text('Paste Recipe JSON'),
              onTap: () => Navigator.of(context).pop('paste'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return null;

    if (choice == 'file') {
      try {
        final picked = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['json'],
          withData: true,
        );
        final bytes = picked?.files.firstOrNull?.bytes;
        return bytes == null ? null : utf8.decode(bytes);
      } catch (error) {
        if (context.mounted) {
          _toast(
            context,
            'Could not read the file: ${_friendlyError(error)}',
            error: true,
          );
        }
        return null;
      }
    }

    return showDialog<String>(
      context: context,
      builder: (context) => const _ImportPasteDialog(),
    );
  }

  Future<void> _export(BuildContext context, AppState state) async {
    final source = state.exportChatTools(conversationId: conversationId);
    await offerExport(
      context,
      text: source,
      fileName: _exportName(state),
      subtitle: 'MaiChat tool definitions (recipes are JSON, not JavaScript)',
    );
  }

  String _exportName(AppState state) {
    final conversation = conversationId == null
        ? null
        : state.conversationById(conversationId!);
    final base = conversation == null
        ? 'maichat-tools'
        : safeFileName('maichat-tools-${conversation.title}');
    return '$base.json';
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final conversation = conversationId == null
        ? null
        : state.conversationById(conversationId!);
    final config = state.chatToolConfigFor(conversation);
    final definitions = state.chatToolDefinitionsFor(conversation).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tool calls'),
        actions: [
          if (conversation?.chatToolConfig != null)
            IconButton(
              tooltip: 'Follow app defaults',
              icon: const Icon(Icons.restore),
              onPressed: () async {
                try {
                  await state.resetChatToolConfig(conversationId!);
                } catch (error) {
                  if (context.mounted) _toast(context, '$error', error: true);
                }
              },
            ),
          IconButton(
            tooltip: 'Import',
            icon: const Icon(Icons.upload_outlined),
            onPressed: () => _import(context, state),
          ),
          IconButton(
            tooltip: 'Export',
            icon: const Icon(Icons.download_outlined),
            onPressed: () => _export(context, state),
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          8,
          8,
          8,
          16 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          _ScopeCard(
            conversationId: conversationId,
            conversation: conversation,
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            dense: true,
            secondary: const Icon(Icons.build_outlined),
            title: const Text('Enable tool calls'),
            subtitle: const Text(
              'The model may ask MaiChat to run an operation, then react to the '
              'recorded result.',
            ),
            value: config.enabled,
            onChanged: (value) =>
                _toggle(context, state, config, enabled: value),
          ),
          _LimitsCard(
            config: config,
            onChanged: (rounds, calls) => _toggle(
              context,
              state,
              config,
              maxRounds: rounds,
              maxCalls: calls,
            ),
          ),
          _TrackerPlacementCard(
            value: config.trackerPlacement,
            onChanged: (value) =>
                _toggle(context, state, config, trackerPlacement: value),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: OutlinedButton.icon(
              onPressed: () => _edit(context, state, config, null),
              icon: const Icon(Icons.add),
              label: const Text('Create a custom tool'),
            ),
          ),
          const SizedBox(height: 4),
          for (final tool in definitions)
            _ToolCard(
              tool: tool,
              enabled:
                  tool.enabled && !config.disabledTools.contains(tool.name),
              onChanged: definitions.length > 1
                  ? (value) => _toggle(
                      context,
                      state,
                      config,
                      tool: tool.name,
                      enabled: value,
                    )
                  : null,
              onInspect: () => _inspect(context, tool),
              onTest: () => _test(context, state, tool),
              onDuplicate: () => _duplicate(context, state, config, tool),
              onEdit: tool.builtin
                  ? null
                  : () => _edit(context, state, config, tool),
              onDelete: tool.builtin
                  ? null
                  : () => _deleteCustom(context, state, config, tool),
            ),
          if (definitions.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'No tool definitions are available in this scope.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    AppState state,
    ChatToolConfig config,
    ChatToolDefinition? initial,
  ) async {
    final edited = await showDialog<ChatToolDefinition>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ToolEditorDialog(
        initial: initial,
        existingNames: {
          for (final tool in config.customTools)
            if (tool.name != initial?.name) tool.name,
        },
      ),
    );
    if (edited == null || !context.mounted) return;
    await _saveCustom(context, state, config, edited);
  }

  ChatToolDefinition _seedDuplicate(ChatToolDefinition tool, String name) =>
      tool.builtin
      ? tool.copyWith(
          name: name,
          description:
              'Custom wrapper for the built-in ${tool.name} operation.',
          action: {
            'call': tool.name,
            'arguments': {'ref': 'args'},
          },
          enabled: true,
          hidden: false,
          followUp: true,
          builtin: false,
        )
      : tool.copyWith(name: name, enabled: true, builtin: false);

  Future<void> _duplicate(
    BuildContext context,
    AppState state,
    ChatToolConfig config,
    ChatToolDefinition tool,
  ) async {
    final name = await _askDuplicateName(
      context,
      _seedDuplicate(tool, _copyName(tool.name)).name,
    );
    if (name == null || !context.mounted) return;
    await _saveCustom(context, state, config, _seedDuplicate(tool, name));
  }

  Future<String?> _askDuplicateName(BuildContext context, String initial) =>
      showDialog<String>(
        context: context,
        builder: (context) => _ToolNameDialog(
          title: 'Duplicate tool',
          initial: initial,
          labelText: 'Tool name',
        ),
      );

  Future<void> _inspect(BuildContext context, ChatToolDefinition tool) {
    return showDialog<void>(
      context: context,
      builder: (context) => _ToolInspectDialog(tool: tool),
    );
  }

  Future<void> _test(
    BuildContext context,
    AppState state,
    ChatToolDefinition tool,
  ) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          _ToolTestDialog(tool: tool, conversationId: conversationId),
    );
  }
}

class _ScopeCard extends StatelessWidget {
  const _ScopeCard({required this.conversationId, required this.conversation});

  final String? conversationId;
  final Conversation? conversation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = conversationId == null ? 'App-wide tools' : 'This chat only';
    final detail = conversationId == null
        ? 'These settings apply to every chat that does not have its own tool '
              'overrides. New chats inherit changes made here.'
        : (conversation?.title.trim().isNotEmpty ?? false)
        ? conversation!.title
        : 'This thread';
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      elevation: 0,
      color: scheme.secondaryContainer.withValues(alpha: 0.7),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(
              Icons.travel_explore_outlined,
              color: scheme.onSecondaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: scheme.onSecondaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSecondaryContainer.withValues(alpha: .8),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LimitsCard extends StatelessWidget {
  const _LimitsCard({required this.config, required this.onChanged});

  final ChatToolConfig config;
  final void Function(int rounds, int calls) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Run limits',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            _LimitSlider(
              label: 'Follow-up rounds',
              value: config.maxRounds,
              min: 1,
              max: 10,
              onChanged: (value) => onChanged(value, config.maxCalls),
            ),
            const SizedBox(height: 4),
            _LimitSlider(
              label: 'Total tool calls',
              value: config.maxCalls,
              min: 1,
              max: 50,
              onChanged: (value) => onChanged(config.maxRounds, value),
            ),
          ],
        ),
      ),
    );
  }
}

class _LimitSlider extends StatelessWidget {
  const _LimitSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
            const SizedBox(width: 12),
            Text(
              '$value',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        Slider(
          value: value.toDouble(),
          min: min.toDouble(),
          max: max.toDouble(),
          divisions: max - min,
          label: '$value',
          onChanged: (changed) => onChanged(changed.round()),
        ),
      ],
    );
  }
}

class _TrackerPlacementCard extends StatelessWidget {
  const _TrackerPlacementCard({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  static const Map<String, String> _labels = {
    'message': 'Below the reply',
    'pinned': 'Pinned panel',
    'hidden': 'Hidden',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tracker placement',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Where tracker updates from tools are shown.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  for (final entry in _labels.entries)
                    ButtonSegment(value: entry.key, label: Text(entry.value)),
                ],
                selected: {_labels.containsKey(value) ? value : 'message'},
                onSelectionChanged: (selection) => onChanged(selection.first),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({
    required this.tool,
    required this.enabled,
    required this.onChanged,
    required this.onInspect,
    required this.onTest,
    required this.onDuplicate,
    this.onEdit,
    this.onDelete,
  });

  final ChatToolDefinition tool;
  final bool enabled;
  final ValueChanged<bool>? onChanged;
  final VoidCallback onInspect;
  final VoidCallback onTest;
  final VoidCallback onDuplicate;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      elevation: 0,
      color: enabled
          ? scheme.surfaceContainerLow
          : scheme.surfaceContainerLow.withValues(alpha: .65),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            dense: true,
            value: enabled,
            onChanged: onChanged,
            secondary: Icon(
              tool.builtin ? Icons.extension_outlined : Icons.create_outlined,
            ),
            title: Text(readableToolName(tool.name)),
            subtitle: Text(
              tool.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ActionChip(
                  tooltip: 'Inspect definition',
                  avatar: const Icon(Icons.search, size: 16),
                  label: const Text('Inspect'),
                  onPressed: onInspect,
                ),
                ActionChip(
                  tooltip: 'Run this operation with test arguments',
                  avatar: const Icon(Icons.play_arrow, size: 16),
                  label: const Text('Test'),
                  onPressed: onTest,
                ),
                ActionChip(
                  tooltip: 'Save an editable copy',
                  avatar: const Icon(Icons.copy_all_outlined, size: 16),
                  label: const Text('Duplicate'),
                  onPressed: onDuplicate,
                ),
                if (onEdit != null)
                  ActionChip(
                    tooltip: 'Edit this custom tool',
                    avatar: const Icon(Icons.edit_outlined, size: 16),
                    label: const Text('Edit'),
                    onPressed: onEdit,
                  ),
                if (onDelete != null)
                  ActionChip(
                    tooltip: 'Delete this custom tool',
                    avatar: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('Delete'),
                    onPressed: onDelete,
                  ),
                if (tool.hidden)
                  InputChip(
                    tooltip:
                        'The model sees this tool, but chat results are '
                        'kept compact',
                    avatar: const Icon(Icons.visibility_off_outlined, size: 16),
                    label: const Text('Hidden result'),
                    onPressed: null,
                  ),
                if (tool.followUp)
                  InputChip(
                    tooltip:
                        'MaiChat makes another request after the result '
                        'is recorded',
                    avatar: const Icon(Icons.replay_outlined, size: 16),
                    label: const Text('Follow-up'),
                    onPressed: null,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolInspectDialog extends StatelessWidget {
  const _ToolInspectDialog({required this.tool});

  final ChatToolDefinition tool;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(readableToolName(tool.name)),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tool.description),
            const SizedBox(height: 12),
            _JsonBlock(label: 'Parameters', value: tool.parameters),
            const SizedBox(height: 8),
            _JsonBlock(label: 'Recipe JSON', value: tool.action),
            const SizedBox(height: 8),
            Text(
              tool.builtin
                  ? 'Built-in operation. Duplicating it creates a recipe that '
                        'calls this native operation.'
                  : 'Custom operation. Recipes execute selected MaiChat '
                        'operations — they are not arbitrary JavaScript.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _JsonBlock extends StatelessWidget {
  const _JsonBlock({required this.label, required this.value});

  final String label;
  final Map<String, dynamic> value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            prettyJson(value),
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

class _ImportPasteDialog extends StatefulWidget {
  const _ImportPasteDialog();

  @override
  State<_ImportPasteDialog> createState() => _ImportPasteDialogState();
}

class _ImportPasteDialogState extends State<_ImportPasteDialog> {
  final TextEditingController _source = TextEditingController();

  @override
  void dispose() {
    _source.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Paste tool definitions'),
      content: SizedBox(
        width: math.min(520.0, MediaQuery.sizeOf(context).width - 24),
        child: SingleChildScrollView(
          child: TextField(
            controller: _source,
            minLines: 8,
            maxLines: 12,
            textInputAction: TextInputAction.newline,
            decoration: const InputDecoration(
              labelText: 'Recipe JSON',
              hintText: 'Paste a MaiChat tool export',
              border: OutlineInputBorder(),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_source.text),
          child: const Text('Import'),
        ),
      ],
    );
  }
}

class _ToolEditorDialog extends StatefulWidget {
  const _ToolEditorDialog({required this.existingNames, this.initial});

  final ChatToolDefinition? initial;
  final Set<String> existingNames;

  @override
  State<_ToolEditorDialog> createState() => _ToolEditorDialogState();
}

class _ToolEditorDialogState extends State<_ToolEditorDialog> {
  static final RegExp _namePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,63}$');

  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _parameters;
  late final TextEditingController _action;
  late bool _hidden;
  late bool _followUp;
  String? _nameError;
  String? _descriptionError;
  String? _parametersError;
  String? _actionError;

  _ToolEditorDialogState();

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _name = TextEditingController(text: initial?.name ?? '');
    _description = TextEditingController(text: initial?.description ?? '');
    _parameters = TextEditingController(
      text: prettyJson(
        initial?.parameters ??
            const <String, dynamic>{
              'type': 'object',
              'properties': {
                'prompt': {'type': 'string', 'description': 'What to ask for.'},
              },
              'required': ['prompt'],
              'additionalProperties': false,
            },
      ),
    );
    _action = TextEditingController(
      text: prettyJson(
        initial?.action ??
            const <String, dynamic>{
              'call': 'roll_dice',
              'arguments': {
                'formula': {'template': '2d6+{args.prompt}'},
              },
            },
      ),
    );
    _hidden = initial?.hidden ?? false;
    _followUp = initial?.followUp ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _parameters.dispose();
    _action.dispose();
    super.dispose();
  }

  ChatToolDefinition? _validate() {
    final name = _name.text.trim();
    setState(() {
      _nameError = _namePattern.hasMatch(name)
          ? (widget.existingNames.contains(name) ? 'Name already used.' : null)
          : 'Use 1–64 letters, numbers or _, starting with a letter or _.';
      _descriptionError = _description.text.trim().isEmpty
          ? 'Describe what the tool does.'
          : null;
    });
    Map<String, dynamic>? decode(
      TextEditingController controller,
      String label,
      void Function(String?) setError,
    ) {
      final raw = controller.text.trim();
      if (raw.isEmpty) return const <String, dynamic>{};
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) {
          setError('$label must be a JSON object.');
          return null;
        }
        setError(null);
        return Map<String, dynamic>.from(decoded);
      } catch (error) {
        setError('Invalid $label: ${_friendlyError(error)}');
        return null;
      }
    }

    final parameters = decode(
      _parameters,
      'JSON parameter schema',
      (error) => _parametersError = error,
    );
    final action = decode(
      _action,
      'Recipe JSON',
      (error) => _actionError = error,
    );
    setState(() {});
    if (_nameError != null ||
        _descriptionError != null ||
        parameters == null ||
        action == null) {
      return null;
    }
    return ChatToolDefinition(
      name: name,
      description: _description.text.trim(),
      parameters: parameters,
      action: action,
      enabled: widget.initial?.enabled ?? true,
      hidden: _hidden,
      followUp: _followUp,
      builtin: false,
    );
  }

  void _save() {
    final tool = _validate();
    if (tool == null) return;
    Navigator.of(context).pop(tool);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final width = math.min(620.0, media.size.width - 24);
    return AlertDialog(
      title: Text(
        widget.initial == null ? 'Create a custom tool' : 'Edit tool',
      ),
      content: SizedBox(
        width: width,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.none,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'Name',
                  helperText: 'Letters, numbers and _ only',
                  errorText: _nameError,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _description,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: 'Description',
                  errorText: _descriptionError,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _hidden,
                onChanged: (value) => setState(() => _hidden = value),
                title: const Text('Hidden result'),
                subtitle: const Text(
                  'Keep the operation’s output compact in the chat.',
                ),
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _followUp,
                onChanged: (value) => setState(() => _followUp = value),
                title: const Text('Follow-up'),
                subtitle: const Text(
                  'Ask the model to react after the result is recorded.',
                ),
              ),
              const SizedBox(height: 8),
              _RecipeEditor(
                parameters: _parameters,
                action: _action,
                parametersError: _parametersError,
                actionError: _actionError,
              ),
              const SizedBox(height: 10),
              Text(
                'Recipes execute selected MaiChat operations. They are JSON, '
                'not arbitrary JavaScript, and cannot run host or shell code.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

class _RecipeEditor extends StatelessWidget {
  const _RecipeEditor({
    required this.parameters,
    required this.action,
    required this.parametersError,
    required this.actionError,
  });

  final TextEditingController parameters;
  final TextEditingController action;
  final String? parametersError;
  final String? actionError;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: parameters,
          minLines: 5,
          maxLines: 8,
          textInputAction: TextInputAction.newline,
          style: const TextStyle(fontFamily: 'monospace'),
          decoration: InputDecoration(
            labelText: 'JSON parameter schema',
            errorText: parametersError,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: action,
          minLines: 7,
          maxLines: 12,
          textInputAction: TextInputAction.newline,
          style: const TextStyle(fontFamily: 'monospace'),
          decoration: InputDecoration(
            labelText: 'Recipe JSON',
            hintText:
                '{"call":"roll_dice","arguments":{"formula":{"ref":"args.formula"}}}',
            errorText: actionError,
            border: const OutlineInputBorder(),
          ),
        ),
      ],
    );
  }
}

class _ToolTestDialog extends StatefulWidget {
  const _ToolTestDialog({required this.tool, required this.conversationId});

  final ChatToolDefinition tool;
  final String? conversationId;

  @override
  State<_ToolTestDialog> createState() => _ToolTestDialogState();
}

class _ToolTestDialogState extends State<_ToolTestDialog> {
  final TextEditingController _arguments = TextEditingController();
  bool _running = false;
  Object? _result;
  Object? _error;

  @override
  void dispose() {
    _arguments.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final raw = _arguments.text.trim().isEmpty ? '{}' : _arguments.text;
    Map<String, dynamic> arguments;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('Arguments must be a JSON object.');
      }
      arguments = Map<String, dynamic>.from(decoded);
    } catch (error) {
      setState(() {
        _error = 'Invalid JSON arguments: ${_friendlyError(error)}';
      });
      return;
    }

    setState(() {
      _running = true;
      _result = null;
      _error = null;
    });
    try {
      final state = context.read<AppState>();
      final value = await state.testChatTool(
        widget.tool.name,
        arguments,
        conversationId: widget.conversationId,
      );
      if (!mounted) return;
      setState(() => _result = value);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final width = math.min(560.0, media.size.width - 24);
    return AlertDialog(
      title: Text('Test ${readableToolName(widget.tool.name)}'),
      content: SizedBox(
        width: width,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _arguments,
                minLines: 5,
                maxLines: 8,
                style: const TextStyle(fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  labelText: 'Arguments JSON',
                  hintText: '{"formula":"2d6+3"}',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'This runs the operation only and does not start a character '
                'reply.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              if (_running)
                const Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (_error != null)
                _ResultBlock(
                  label: 'Error',
                  text: _friendlyError(_error!),
                  isError: true,
                )
              else if (_result != null)
                _ResultBlock(label: 'Result', text: prettyJson(_result!))
              else
                Text(
                  'Run the tool to see JSON or text it returns.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _running ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: _running ? null : _run,
          child: const Text('Run'),
        ),
      ],
    );
  }
}

class _ResultBlock extends StatelessWidget {
  const _ResultBlock({
    required this.label,
    required this.text,
    this.isError = false,
  });

  final String label;
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: isError ? scheme.error : scheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: isError
                ? scheme.errorContainer.withValues(alpha: .7)
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(text),
        ),
      ],
    );
  }
}

class _ToolNameDialog extends StatefulWidget {
  const _ToolNameDialog({
    required this.title,
    required this.initial,
    required this.labelText,
  });

  final String title;
  final String initial;
  final String labelText;

  @override
  State<_ToolNameDialog> createState() => _ToolNameDialogState();
}

class _ToolNameDialogState extends State<_ToolNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autocorrect: false,
        textCapitalization: TextCapitalization.none,
        decoration: InputDecoration(labelText: widget.labelText),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final value = _controller.text.trim();
            Navigator.of(context).pop(value.isEmpty ? null : value);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

String _copyName(String name) {
  var suffix = 2;
  while (true) {
    final candidate = '${name}_copy$suffix';
    if (candidate.length <= 64) return candidate;
    if (name.length + suffix.toString().length + 5 <= 64) return candidate;
    suffix++;
  }
}

String _friendlyError(Object error) {
  final text = error.toString();
  if (text.startsWith('FormatException: ')) {
    return text.substring('FormatException: '.length);
  }
  return text;
}

void _toast(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error
            ? Theme.of(context).colorScheme.errorContainer
            : null,
      ),
    );
}
