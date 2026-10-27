import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/chat_tool.dart';
import '../../state/app_state.dart';
import '../../widgets/chat_tool_results.dart';
import 'chat_tools_page.dart';

/// Writes, edits, inspects or duplicates one tool — the full-screen
/// replacement for the old capped dialog.
///
/// Custom tools get every field (name, description, switches, JSON schema,
/// recipe). A built-in opens read-only: its description and schema, and a
/// Duplicate button that seeds a custom wrapper recipe calling the native
/// operation. [initial] null creates a fresh tool with the default seed.
class ChatToolEditScreen extends StatefulWidget {
  const ChatToolEditScreen({
    super.key,
    this.conversationId,
    this.initial,
    required this.existingNames,
  });

  final String? conversationId;
  final ChatToolDefinition? initial;
  final Set<String> existingNames;

  @override
  State<ChatToolEditScreen> createState() => _ChatToolEditScreenState();
}

class _ChatToolEditScreenState extends State<ChatToolEditScreen> {
  static final RegExp _namePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,63}$');

  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _parameters;
  late final TextEditingController _action;
  late bool _hidden;
  late bool _followUp;
  late final TextEditingController _tagField;
  String? _editingTag;
  String? _tagError;
  String? _nameError;
  String? _descriptionError;
  String? _parametersError;
  String? _actionError;

  ChatToolDefinition? get _initial => widget.initial;
  bool get _isReadOnly => _initial?.builtin ?? false;

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
    _tags = List<String>.of(initial?.tags ?? const <String>[]);
    _tagField = TextEditingController();
  }

  List<String> get _tagsValue => normalizeToolTags(_tags);
  List<String> _tags = [];

  String? _validateTagField({bool requireText = false}) {
    final raw = _tagField.text.trim();
    if (raw.isEmpty) {
      return requireText || _editingTag != null ? 'Enter a tag.' : null;
    }
    final normalized = normalizeToolTags([raw]);
    if (normalized.isEmpty) return 'Enter a tag.';
    final key = normalized.single.toLowerCase();
    if (_editingTag == null && _tags.any((t) => t.toLowerCase() == key)) {
      return 'That tag is already added.';
    }
    if (_editingTag != null &&
        _editingTag!.toLowerCase() != key &&
        _tags.any((t) => t.toLowerCase() == key)) {
      return 'That tag is already added.';
    }
    return null;
  }

  /// Commits the field so toolbar Save cannot silently drop a pending tag.
  ///
  /// Returns false (and shows the inline tag error) when the pending value is
  /// invalid; unrelated editor errors are deliberately left for [_validate].
  bool _commitTagField() {
    final raw = _tagField.text.trim();
    if (raw.isEmpty && _editingTag != null) {
      setState(() {
        _tags.removeWhere((t) => t.toLowerCase() == _editingTag!.toLowerCase());
        _editingTag = null;
        _tagError = null;
        _tagField.clear();
      });
      return true;
    }
    final error = _validateTagField(requireText: true);
    if (error != null) {
      setState(() => _tagError = error);
      return false;
    }
    final normalized = normalizeToolTags([raw]).single;
    setState(() {
      if (_editingTag != null) {
        final index = _tags.indexWhere(
          (t) => t.toLowerCase() == _editingTag!.toLowerCase(),
        );
        if (index >= 0) {
          _tags[index] = normalized;
        } else {
          _tags.add(normalized);
        }
      } else {
        _tags.add(normalized);
      }
      _editingTag = null;
      _tagError = null;
      _tagField.clear();
    });
    return true;
  }

  void _startEditTag(String tag) {
    setState(() {
      _editingTag = _tags.firstWhere(
        (t) => t.toLowerCase() == tag.toLowerCase(),
        orElse: () => tag,
      );
      _tagField.text = _editingTag!;
      _tagField.selection = TextSelection.collapsed(
        offset: _tagField.text.length,
      );
      _tagError = null;
    });
  }

  void _removeTag(String tag) {
    setState(() {
      _tags.removeWhere((t) => t.toLowerCase() == tag.toLowerCase());
      if (_editingTag?.toLowerCase() == tag.toLowerCase()) {
        _editingTag = null;
        _tagField.clear();
      }
      _tagError = null;
    });
  }

  ChatToolDefinition? _validate() {
    final name = _name.text.trim();
    setState(() {
      _nameError = _namePattern.hasMatch(name)
          ? (widget.existingNames.contains(name) && name != _initial?.name
                ? 'Name already used.'
                : null)
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
        setError('Invalid $label: ${friendlyError(error)}');
        return null;
      }
    }

    final tags = _tagsValue;
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
      enabled: _initial?.enabled ?? true,
      hidden: _hidden,
      followUp: _followUp,
      builtin: false,
      tags: tags,
    );
  }

  Future<void> _save() async {
    final hasPendingTag =
        _tagField.text.trim().isNotEmpty || _editingTag != null;
    if (hasPendingTag && !_commitTagField()) return;
    if (_isReadOnly) {
      final initial = _initial!;
      final tags = _tagsValue;
      final state = context.read<AppState>();
      final config = state.chatToolConfigFor(
        widget.conversationId == null
            ? null
            : state.conversationById(widget.conversationId!),
      );
      try {
        await saveBuiltInTags(
          context,
          state,
          config,
          initial.name,
          tags,
          conversationId: widget.conversationId,
        );
      } catch (_) {
        // The helper has already surfaced the save error.
        return;
      }
      if (mounted) Navigator.of(context).pop(true);
      return;
    }
    final tool = _validate();
    if (tool == null) return;
    final state = context.read<AppState>();
    // Read the config after state changed while the editor was open;
    // otherwise another screen's toggle can be silently reverted by this
    // stale copy.
    final config = state.chatToolConfigFor(
      widget.conversationId == null
          ? null
          : state.conversationById(widget.conversationId!),
    );
    try {
      await saveCustomTool(
        context,
        state,
        config,
        tool,
        conversationId: widget.conversationId,
        originalName: _initial?.name,
      );
    } catch (error) {
      if (mounted) {
        toastToolError(
          context,
          'Could not save the tool: ${friendlyError(error)}',
        );
      }
      return;
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _duplicate() async {
    final initial = _initial;
    if (initial == null) return;
    final name = await askToolName(
      context,
      toolCopyName(initial.name),
      existingNames: widget.existingNames,
    );
    if (name == null || !mounted) return;
    final state = context.read<AppState>();
    final config = state.chatToolConfigFor(
      widget.conversationId == null
          ? null
          : state.conversationById(widget.conversationId!),
    );
    try {
      await saveCustomTool(
        context,
        state,
        config,
        seedToolDuplicate(initial, name),
        conversationId: widget.conversationId,
      );
    } catch (error) {
      if (mounted) {
        toastToolError(context, 'Could not duplicate: ${friendlyError(error)}');
      }
      return;
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    final initial = _initial;
    if (initial == null || initial.builtin) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${readableToolName(initial.name)}?'),
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
    if (ok != true || !mounted) return;
    final state = context.read<AppState>();
    final config = state.chatToolConfigFor(
      widget.conversationId == null
          ? null
          : state.conversationById(widget.conversationId!),
    );
    try {
      await deleteCustomTool(
        context,
        state,
        config,
        initial,
        conversationId: widget.conversationId,
      );
    } catch (error) {
      if (mounted) {
        toastToolError(context, 'Could not delete: ${friendlyError(error)}');
      }
      return;
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  Widget _buildTagSection(ThemeData theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Tags',
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 4),
      LayoutBuilder(
        builder: (context, constraints) => ConstrainedBox(
          constraints: BoxConstraints(maxWidth: constraints.maxWidth),
          child: TextField(
            key: const Key('chat-tool-tags-field'),
            controller: _tagField,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _commitTagField(),
            decoration: InputDecoration(
              hintText: _editingTag == null ? 'Add a tag' : 'Rename tag',
              helperText: 'Labels used only to organise this list',
              errorText: _tagError,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
      ),
      const SizedBox(height: 6),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonalIcon(
          key: Key(
            _editingTag == null ? 'chat-tool-tags-add' : 'chat-tool-tags-save',
          ),
          onPressed: _commitTagField,
          icon: Icon(_editingTag == null ? Icons.add : Icons.check),
          label: Text(_editingTag == null ? 'Add tag' : 'Save tag'),
        ),
      ),
      if (_tags.isNotEmpty) ...[
        const SizedBox(height: 8),
        Wrap(
          key: const Key('chat-tool-tag-chips'),
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final tag in _tags)
              KeyedSubtree(
                key: Key('chat-tool-tag-chip-$tag'),
                child: InputChip(
                  deleteIcon: KeyedSubtree(
                    key: Key('chat-tool-tag-delete-$tag'),
                    child: const Icon(Icons.cancel),
                  ),
                  label: Text(
                    tag,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onPressed: () => _startEditTag(tag),
                  onDeleted: () => _removeTag(tag),
                  deleteButtonTooltipMessage: 'Delete tag',
                ),
              ),
          ],
        ),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) {
    final readOnly = _isReadOnly;
    final theme = Theme.of(context);
    final title = readOnly
        ? readableToolName(_initial!.name)
        : _initial == null
        ? 'New tool'
        : 'Edit tool';
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          TextButton(
            key: const Key('chat-tool-editor-save'),
            onPressed: _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        key: const Key('chat-tool-editor-list'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          if (readOnly) ...[
            Text(
              _initial!.description,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
            ),
            const SizedBox(height: 16),
            _buildTagSection(theme),
            const SizedBox(height: 16),
            _JsonBlock(label: 'Parameters', value: _initial!.parameters),
            const SizedBox(height: 8),
            Text(
              'Built-in operation. Recipes cannot edit it — duplicating it '
              'creates a custom recipe that calls this operation.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              key: const Key('chat-tool-editor-duplicate'),
              onPressed: _duplicate,
              icon: const Icon(Icons.copy_all_outlined),
              label: const Text('Duplicate as custom tool'),
            ),
            if (_initial!.followUp) ...[
              const SizedBox(height: 8),
              Text(
                'The model may react to this tool\'s result in a follow-up '
                'round.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ] else ...[
            TextField(
              key: const Key('chat-tool-editor-name'),
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
              key: const Key('chat-tool-editor-description'),
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
            _buildTagSection(theme),
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
            TextField(
              key: const Key('chat-tool-editor-parameters'),
              controller: _parameters,
              minLines: 5,
              maxLines: 8,
              textInputAction: TextInputAction.newline,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: InputDecoration(
                labelText: 'JSON parameter schema',
                errorText: _parametersError,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('chat-tool-editor-action'),
              controller: _action,
              minLines: 7,
              maxLines: 12,
              textInputAction: TextInputAction.newline,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: InputDecoration(
                labelText: 'Recipe JSON',
                hintText:
                    '{"call":"roll_dice","arguments":{"formula":{"ref":"args.formula"}}}',
                errorText: _actionError,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Recipes execute selected MaiChat operations. They are JSON, '
              'not arbitrary JavaScript, and cannot run host or shell code.',
              style: theme.textTheme.bodySmall,
            ),
            if (_initial != null && !_initial!.builtin) ...[
              const SizedBox(height: 20),
              OutlinedButton.icon(
                key: const Key('chat-tool-editor-delete'),
                onPressed: _delete,
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete tool'),
              ),
            ],
          ],
        ],
      ),
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
