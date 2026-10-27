import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/chat_tool.dart';
import '../../state/app_state.dart';
import '../../services/chat_tools/definitions.dart';
import '../../widgets/chat_tool_results.dart';
import '../../widgets/export_sheet.dart';
import 'chat_tools_edit_screen.dart';
import 'chat_tools_info_screen.dart';
import 'chat_tools_options_screen.dart';

/// Settings ▸ Tools, scoped by route.
///
/// With no [conversationId] this edits the app-wide library. With one it edits
/// that thread's own copy. The page is deliberately simple: a search bar, tag
/// and sort filters, and one row per tool with its toggle and actions — the
/// knobs live one tap away in the settings sub-screen, and the explainer one
/// tap away behind the ⓘ.
class ChatToolsPage extends StatefulWidget {
  const ChatToolsPage({super.key, this.conversationId});

  final String? conversationId;

  @override
  State<ChatToolsPage> createState() => _ChatToolsPageState();
}

class _ChatToolsPageState extends State<ChatToolsPage> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  final Set<String> _tags = {};
  String _sort = 'name';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<ChatToolDefinition> _visible(List<ChatToolDefinition> definitions) {
    final q = _query.trim().toLowerCase();
    var shown = definitions.where((tool) {
      if (_tags.isNotEmpty && !_tags.contains(toolTag(tool))) return false;
      if (q.isEmpty) return true;
      return tool.name.toLowerCase().contains(q) ||
          tool.description.toLowerCase().contains(q);
    }).toList();
    shown.sort((a, b) {
      if (a.builtin != b.builtin) return a.builtin ? -1 : 1;
      if (_sort == 'kind') {
        final byTag = toolTag(a).compareTo(toolTag(b));
        if (byTag != 0) return byTag;
      }
      return readableToolName(
        a.name,
      ).toLowerCase().compareTo(readableToolName(b.name).toLowerCase());
    });
    return shown;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final conversation = widget.conversationId == null
        ? null
        : state.conversationById(widget.conversationId!);
    final config = state.chatToolConfigFor(conversation);
    final definitions = state.chatToolDefinitionsFor(conversation).toList();
    final allTags = <String>{for (final t in definitions) toolTag(t)};
    final shown = _visible(definitions);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tools'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'About tools',
            icon: const Icon(Icons.info_outline),
            onPressed: () => showChatToolsInfo(context),
          ),
          IconButton(
            tooltip: 'Tools settings',
            icon: const Icon(Icons.tune),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ChatToolsOptionsScreen(
                  conversationId: widget.conversationId,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
            child: SearchBar(
              key: const Key('chat-tools-search'),
              controller: _search,
              hintText: 'Search tools',
              leading: const Icon(Icons.search),
              trailing: [
                if (_query.isNotEmpty)
                  IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      _search.clear();
                      setState(() => _query = '');
                    },
                  ),
              ],
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(context).copyWith(
                      dragDevices: {
                        ...ScrollConfiguration.of(context).dragDevices,
                        PointerDeviceKind.mouse,
                      },
                    ),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final tag in allTags)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: FilterChip(
                                key: Key('chat-tools-tag-$tag'),
                                label: Text(tag),
                                selected: _tags.contains(tag),
                                onSelected: (on) => setState(() {
                                  if (on) {
                                    _tags.add(tag);
                                  } else {
                                    _tags.remove(tag);
                                  }
                                }),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  key: const Key('chat-tools-sort'),
                  tooltip: 'Sort',
                  icon: const Icon(Icons.sort),
                  initialValue: _sort,
                  onSelected: (value) => setState(() => _sort = value),
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'name', child: Text('Name')),
                    PopupMenuItem(value: 'kind', child: Text('Kind')),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: shown.isEmpty && definitions.isEmpty
                ? const _EmptyScope()
                : shown.isEmpty
                ? _NoMatch(query: _query.trim())
                : ListView.builder(
                    padding: EdgeInsets.only(
                      bottom: 16 + MediaQuery.paddingOf(context).bottom,
                    ),
                    itemCount: shown.length,
                    itemBuilder: (context, index) => _ToolRow(
                      tool: shown[index],
                      enabled:
                          shown[index].enabled &&
                          !config.disabledTools.contains(shown[index].name),
                      onToggle: (value) => toggleTool(
                        context,
                        state,
                        config,
                        tool: shown[index].name,
                        enabled: value,
                        conversationId: widget.conversationId,
                      ),
                      onOpen: () => _openTool(context, shown[index], config),
                      onInspect: () => _openTool(context, shown[index], config),
                      onTest: () => testTool(
                        context,
                        shown[index],
                        conversationId: widget.conversationId,
                      ),
                      onDuplicate: () => duplicateTool(
                        context,
                        state,
                        config,
                        shown[index],
                        conversationId: widget.conversationId,
                      ),
                      onFollowUp: (value) => setToolFollowUp(
                        context,
                        state,
                        config,
                        shown[index],
                        value,
                        conversationId: widget.conversationId,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _openTool(
    BuildContext context,
    ChatToolDefinition tool,
    ChatToolConfig config,
  ) async {
    if (tool.builtin) {
      // A built-in opens in the editor's read-only view, where its Duplicate
      // lives; only a custom definition is editable in place.
      await Navigator.of(context).push(
        MaterialPageRoute<bool>(
          builder: (_) => ChatToolEditScreen(
            conversationId: widget.conversationId,
            initial: tool,
            existingNames: {for (final other in config.customTools) other.name},
          ),
        ),
      );
      return;
    }
    final saved = await Navigator.of(context).push(
      MaterialPageRoute<bool>(
        builder: (_) => ChatToolEditScreen(
          conversationId: widget.conversationId,
          initial: tool,
          existingNames: {
            for (final other in config.customTools)
              if (other.name != tool.name) other.name,
          },
        ),
      ),
    );
    if (saved == true && mounted) {
      final messenger = ScaffoldMessenger.of(this.context);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Tool saved')));
    }
  }
}

class _EmptyScope extends StatelessWidget {
  const _EmptyScope();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 48),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.extension_outlined,
            size: 48,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: 20),
          Text(
            'No tool definitions are available in this scope.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}

class _NoMatch extends StatelessWidget {
  const _NoMatch({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
      child: Column(
        children: [
          Icon(Icons.search_off, size: 40, color: scheme.onSurfaceVariant),
          const SizedBox(height: 14),
          Text(
            'No tools match "$query"',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}

/// One tool in the list. The name and its toggle sit on one line; the action
/// strip below carries Inspect | Test | Duplicate | Follow up. On a narrow
/// screen the Follow up button is revealed by dragging the strip sideways.
class _ToolRow extends StatefulWidget {
  const _ToolRow({
    required this.tool,
    required this.enabled,
    required this.onToggle,
    required this.onOpen,
    required this.onInspect,
    required this.onTest,
    required this.onDuplicate,
    required this.onFollowUp,
  });

  final ChatToolDefinition tool;
  final bool enabled;
  final ValueChanged<bool>? onToggle;
  final VoidCallback onOpen;
  final VoidCallback onInspect;
  final VoidCallback onTest;
  final VoidCallback onDuplicate;
  final ValueChanged<bool>? onFollowUp;

  @override
  State<_ToolRow> createState() => _ToolRowState();
}

class _ToolRowState extends State<_ToolRow> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    // The four actions in one horizontal strip. When the row is too narrow
    // for all four, the strip slides: the user swipes it left to reach
    // Follow up. Where it fits (tablet/desktop widths), all four show.
    final strip = ListView(
      key: Key('chat-tool-strip-${widget.tool.name}'),
      scrollDirection: Axis.horizontal,
      // The whole row scrolls as one, so vertical drags never fight the
      // page's list.
      physics: const ClampingScrollPhysics(),
      children: [
        ActionChip(
          tooltip: 'Inspect definition',
          avatar: const Icon(Icons.search, size: 16),
          label: const Text('Inspect'),
          onPressed: widget.onInspect,
        ),
        const SizedBox(width: 8),
        ActionChip(
          tooltip: 'Run this operation with test arguments',
          avatar: const Icon(Icons.play_arrow, size: 16),
          label: const Text('Test'),
          onPressed: widget.onTest,
        ),
        const SizedBox(width: 8),
        ActionChip(
          tooltip: 'Save an editable copy',
          avatar: const Icon(Icons.copy_all_outlined, size: 16),
          label: const Text('Duplicate'),
          onPressed: widget.onDuplicate,
        ),
        const SizedBox(width: 8),
        ActionChip(
          key: const Key('chat-tool-action-followup'),
          tooltip: 'Ask the model to react after this tool records a result',
          avatar: Icon(
            widget.tool.followUp
                ? Icons.replay_outlined
                : Icons.replay_circle_filled_outlined,
            size: 16,
          ),
          label: Text(widget.tool.followUp ? 'Follow up' : 'No follow up'),
          onPressed: widget.onFollowUp == null
              ? null
              : () => widget.onFollowUp!(!widget.tool.followUp),
        ),
        const SizedBox(width: 4),
      ],
    );

    return Card(
      key: Key('chat-tool-row-${widget.tool.name}'),
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: widget.enabled
          ? scheme.surfaceContainerLow
          : scheme.surfaceContainerLow.withValues(alpha: .65),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: widget.onOpen,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            readableToolName(widget.tool.name),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: widget.enabled
                                  ? null
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            widget.tool.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (widget.tool.builtin)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(
                      Icons.extension_outlined,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                Switch(
                  key: Key('chat-tool-toggle-${widget.tool.name}'),
                  value: widget.enabled,
                  onChanged: widget.onToggle,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(
                  dragDevices: {
                    ...ScrollConfiguration.of(context).dragDevices,
                    PointerDeviceKind.mouse,
                  },
                ),
                child: SizedBox(
                  height:
                      48 + (MediaQuery.textScalerOf(context).scale(16) - 16),
                  child: strip,
                ),
              ),
            ),
            if (widget.tool.hidden)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: Icon(
                  Icons.visibility_off_outlined,
                  size: 14,
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared tool helpers — the single path every surface (list row, options
// screen, editor) writes through. All go via AppState.saveChatToolConfig
// with the same conversationId, so chat and global scope can never mix.
// ---------------------------------------------------------------------------

/// One word describing what a tool is for — the tag row and the Kind sort.
String toolTag(ChatToolDefinition tool) {
  if (tool.builtin) {
    return switch (tool.name) {
      'roll_dice' || 'random_integer' => 'Random',
      'read_trackers' || 'define_tracker' || 'update_tracker' => 'Trackers',
      'set_prompt_injection' => 'Prompt',
      'generate_image' => 'Images',
      'list_tools' || 'save_tool' || 'delete_tool' => 'Library',
      _ => 'Built-in',
    };
  }
  return 'Custom';
}

Future<void> toggleTool(
  BuildContext context,
  AppState state,
  ChatToolConfig config, {
  required String tool,
  bool? enabled,
  String? conversationId,
}) async {
  final disabled = config.disabledTools.toList();
  final isEnabled = !disabled.contains(tool);
  final shouldEnable = enabled ?? !isEnabled;
  final customTools = [
    for (final definition in config.customTools)
      if (definition.name == tool)
        definition.copyWith(enabled: shouldEnable)
      else
        definition,
  ];
  final next = shouldEnable
      ? disabled.where((name) => name != tool).toList()
      : [...disabled, tool];
  try {
    await state.saveChatToolConfig(
      config.copyWith(
        disabledTools: List<String>.unmodifiable(next),
        customTools: List<ChatToolDefinition>.unmodifiable(customTools),
      ),
      conversationId: conversationId,
    );
  } catch (error) {
    if (context.mounted) {
      toastToolError(
        context,
        'Could not save tool settings: ${friendlyError(error)}',
      );
    }
  }
}

/// Toggles follow-up without changing a built-in's executable definition.
Future<void> setToolFollowUp(
  BuildContext context,
  AppState state,
  ChatToolConfig config,
  ChatToolDefinition tool,
  bool value, {
  String? conversationId,
}) async {
  if (tool.builtin) {
    try {
      await state.saveChatToolConfig(
        config.copyWith(
          followUpOverrides: {...config.followUpOverrides, tool.name: value},
        ),
        conversationId: conversationId,
      );
    } catch (error) {
      if (context.mounted) {
        toastToolError(
          context,
          'Could not save follow-up: ${friendlyError(error)}',
        );
      }
    }
    return;
  }
  try {
    await saveCustomTool(
      context,
      state,
      config,
      tool.copyWith(followUp: value),
      conversationId: conversationId,
    );
  } catch (error) {
    if (context.mounted) {
      toastToolError(
        context,
        'Could not save follow-up: ${friendlyError(error)}',
      );
    }
  }
}

Future<void> saveCustomTool(
  BuildContext context,
  AppState state,
  ChatToolConfig config,
  ChatToolDefinition tool, {
  String? conversationId,
  String? originalName,
}) async {
  // A rename replaces the entry carrying [originalName] rather than adding a
  // second tool.
  final retired = originalName == null || originalName == tool.name
      ? const <String>{}
      : {originalName};
  final replacements = <String, ChatToolDefinition>{};
  for (final existing in config.customTools) {
    replacements[existing.name] = existing;
  }
  replacements[tool.name] = tool;
  final next = [
    for (final existing in config.customTools)
      if (!retired.contains(existing.name))
        replacements.remove(existing.name) ?? existing,
    if (replacements.containsKey(tool.name)) replacements.remove(tool.name)!,
  ];
  await state.saveChatToolConfig(
    config.copyWith(
      customTools: List<ChatToolDefinition>.unmodifiable(next),
      disabledTools: List<String>.unmodifiable([
        for (final name in config.disabledTools)
          if (retired.contains(name)) tool.name else name,
      ]),
    ),
    conversationId: conversationId,
  );
}

Future<void> deleteCustomTool(
  BuildContext context,
  AppState state,
  ChatToolConfig config,
  ChatToolDefinition tool, {
  String? conversationId,
}) async {
  await state.saveChatToolConfig(
    config.copyWith(
      customTools: List<ChatToolDefinition>.unmodifiable([
        for (final existing in config.customTools)
          if (existing.name != tool.name) existing,
      ]),
      disabledTools: List<String>.unmodifiable(
        config.disabledTools.where((name) => name != tool.name),
      ),
    ),
    conversationId: conversationId,
  );
}

ChatToolDefinition seedToolDuplicate(ChatToolDefinition tool, String name) =>
    tool.builtin
    ? tool.copyWith(
        name: name,
        description: 'Custom wrapper for the built-in ${tool.name} operation.',
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

Future<void> duplicateTool(
  BuildContext context,
  AppState state,
  ChatToolConfig config,
  ChatToolDefinition tool, {
  String? conversationId,
}) async {
  final existingNames = {
    for (final other in config.customTools) other.name,
    for (final builtin in chatToolBuiltIns) builtin.name,
  };
  final name = await askToolName(
    context,
    toolCopyName(tool.name, existingNames: existingNames),
    existingNames: existingNames,
  );
  if (name == null || !context.mounted) return;
  try {
    final current = state.chatToolConfigFor(
      conversationId == null ? null : state.conversationById(conversationId),
    );
    await saveCustomTool(
      context,
      state,
      current,
      seedToolDuplicate(tool, name),
      conversationId: conversationId,
    );
    if (context.mounted) _toast(context, 'Duplicated as $name');
  } catch (error) {
    if (context.mounted) {
      toastToolError(context, 'Could not duplicate: ${friendlyError(error)}');
    }
  }
}

/// Validates custom names against both the current library and native tools.
String? toolNameError(String name, Set<String> existingNames) {
  if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,63}$').hasMatch(name)) {
    return 'Use 1–64 letters, numbers or _, starting with a letter or _.';
  }
  if (existingNames.contains(name) ||
      chatToolBuiltIns.any((tool) => tool.name == name)) {
    return 'Name already used.';
  }
  return null;
}

/// Asks for a validated, unused name without altering the source definition.
Future<String?> askToolName(
  BuildContext context,
  String initial, {
  Set<String> existingNames = const {},
}) => showDialog<String>(
  context: context,
  builder: (context) =>
      _ToolNameDialog(initial: initial, existingNames: existingNames),
);

class _ToolNameDialog extends StatefulWidget {
  const _ToolNameDialog({required this.initial, required this.existingNames});

  final String initial;
  final Set<String> existingNames;

  @override
  State<_ToolNameDialog> createState() => _ToolNameDialogState();
}

class _ToolNameDialogState extends State<_ToolNameDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final name = _controller.text.trim();
    final error = toolNameError(name, widget.existingNames);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Name the copy'),
    content: TextField(
      controller: _controller,
      autocorrect: false,
      textCapitalization: TextCapitalization.none,
      decoration: InputDecoration(labelText: 'Tool name', errorText: _error),
      onSubmitted: (_) => _save(),
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

Future<void> testTool(
  BuildContext context,
  ChatToolDefinition tool, {
  String? conversationId,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) =>
        ToolTestDialog(tool: tool, conversationId: conversationId),
  );
}

Future<void> importChatTools(
  BuildContext context, {
  String? conversationId,
}) async {
  final state = context.read<AppState>();
  final source = await _chooseImport(context);
  if (source == null) return;
  try {
    await state.importChatTools(source, conversationId: conversationId);
  } catch (error) {
    if (context.mounted) {
      toastToolError(context, 'Import failed: ${friendlyError(error)}');
    }
    return;
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('Tool definitions imported')),
      );
  }
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
        toastToolError(
          context,
          'Could not read the file: ${friendlyError(error)}',
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

Future<void> exportChatTools(
  BuildContext context,
  AppState state, {
  String? conversationId,
}) async {
  final source = state.exportChatTools(conversationId: conversationId);
  final conversation = conversationId == null
      ? null
      : state.conversationById(conversationId);
  final base = conversation == null
      ? 'maichat-tools'
      : safeFileName('maichat-tools-${conversation.title}');
  await offerExport(
    context,
    text: source,
    fileName: '$base.json',
    subtitle: 'MaiChat tool definitions (recipes are JSON, not JavaScript)',
  );
}

String toolCopyName(String name, {Set<String> existingNames = const {}}) {
  for (var suffix = 2; ; suffix++) {
    final ending = '_copy$suffix';
    final prefix = name.length + ending.length <= 64
        ? name
        : name.substring(0, 64 - ending.length);
    final candidate = '$prefix$ending';
    if (!existingNames.contains(candidate)) return candidate;
  }
}

String friendlyError(Object error) {
  final text = error.toString();
  if (text.startsWith('FormatException: ')) {
    return text.substring('FormatException: '.length);
  }
  return text;
}

void toastToolError(BuildContext context, String message) =>
    _toast(context, message, error: true);

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
        width: 520.0,
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

/// The Test dialog, ported unchanged from the old page: arguments in, one
/// run, readable result or error.
class ToolTestDialog extends StatefulWidget {
  const ToolTestDialog({
    super.key,
    required this.tool,
    required this.conversationId,
  });

  final ChatToolDefinition tool;
  final String? conversationId;

  @override
  State<ToolTestDialog> createState() => _ToolTestDialogState();
}

class _ToolTestDialogState extends State<ToolTestDialog> {
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
        _error = 'Invalid JSON arguments: ${friendlyError(error)}';
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
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('Test ${readableToolName(widget.tool.name)}'),
      content: SizedBox(
        width: 560.0,
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
                style: theme.textTheme.bodySmall,
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
                  text: friendlyError(_error!),
                  isError: true,
                )
              else if (_result != null)
                _ResultBlock(label: 'Result', text: prettyJson(_result!))
              else
                Text(
                  'Run the tool to see JSON or text it returns.',
                  style: theme.textTheme.bodySmall,
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
