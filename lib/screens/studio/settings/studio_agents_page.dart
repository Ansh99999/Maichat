import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../../models/studio.dart';
import '../../../services/studio/custom_agents.dart';
import '../../../state/app_state.dart';
import 'settings_parts.dart';

/// The kinds of sub-agent the Studio can start: the four it comes with, which
/// can be read and copied, and the user's own, which can be written from
/// scratch — what it is for, what it is told, what it may touch, which model
/// it runs on.
class StudioAgentsPage extends StatelessWidget {
  const StudioAgentsPage({super.key});

  Future<void> _edit(
    BuildContext context, {
    StudioAgentType? type,
    StudioAgentType? from,
  }) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => StudioAgentEditPage(type: type, from: from),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final config = context.watch<AppState>().studioConfig;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final custom = config.customAgents;
    return Scaffold(
      appBar: AppBar(title: const Text('Sub-agent types')),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('studio-agent-new'),
        onPressed: () => _edit(context),
        icon: const Icon(Icons.add),
        label: const Text('New type'),
      ),
      body: ListView(
        padding: settingsPagePadding(context, fab: true),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Text(
              'The Studio picks a type for each sub-agent it starts. Make '
              'your own for jobs you give it often — a voice coach, a canon '
              'checker, a translator.',
              style: muted,
            ),
          ),
          if (custom.isNotEmpty)
            SettingsGroup(
              title: 'Yours',
              children: [
                for (final t in custom)
                  _TypeRow(
                    key: ValueKey('agent-${t.id}'),
                    type: t,
                    onTap: () => _edit(context, type: t),
                  ),
              ],
            ),
          SettingsGroup(
            title: 'Built in',
            children: [
              for (final t in kBuiltInAgentTypes)
                _TypeRow(
                  key: ValueKey('agent-${t.id}'),
                  type: t,
                  onTap: () => _showBuiltIn(context, t),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showBuiltIn(BuildContext context, StudioAgentType t) async {
    final copy = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _BuiltInSheet(type: t),
    );
    if (copy == true && context.mounted) await _edit(context, from: t);
  }
}

class _TypeRow extends StatelessWidget {
  const _TypeRow({super.key, required this.type, required this.onTap});

  final StudioAgentType type;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: type.builtIn
              ? scheme.surfaceContainerHighest
              : scheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(
          type.builtIn ? Icons.smart_toy_outlined : Icons.person_pin_outlined,
          color: type.builtIn
              ? scheme.onSurfaceVariant
              : scheme.onTertiaryContainer,
        ),
      ),
      title: Text(type.label),
      subtitle: Text(
        type.description,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

/// A built-in type, read-only: what it is for, what it may do, and a way to
/// start a type of one's own from it.
class _BuiltInSheet extends StatelessWidget {
  const _BuiltInSheet({required this.type});

  final StudioAgentType type;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groups = toolGroupsOf(type.id);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.75,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          children: [
            Text(type.label, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(type.description, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 24),
            Text('It may',
                style: theme.textTheme.titleSmall
                    ?.copyWith(color: theme.colorScheme.primary)),
            const SizedBox(height: 8),
            Text(
              [
                for (final g in kStudioToolGroups.entries)
                  if (groups.contains(g.key)) g.value.$1,
              ].join(' · '),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            FilledButton.tonalIcon(
              key: const Key('studio-agent-duplicate'),
              onPressed: () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.copy_all_outlined),
              label: const Text('Make my own from this'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Writes one of the user's sub-agent types: a new one, one being changed
/// ([type]), or a copy of a built-in ([from]).
class StudioAgentEditPage extends StatefulWidget {
  const StudioAgentEditPage({super.key, this.type, this.from});

  final StudioAgentType? type;
  final StudioAgentType? from;

  @override
  State<StudioAgentEditPage> createState() => _StudioAgentEditPageState();
}

class _StudioAgentEditPageState extends State<StudioAgentEditPage> {
  late final TextEditingController _label;
  late final TextEditingController _description;
  late final TextEditingController _prompt;
  late final TextEditingController _model;
  late Set<String> _groups;

  @override
  void initState() {
    super.initState();
    final t = widget.type;
    final from = widget.from;
    _label = TextEditingController(
      text: t?.label ?? (from == null ? '' : 'My ${from.label.toLowerCase()}'),
    );
    _description = TextEditingController(
      text: t?.description ?? from?.description ?? '',
    );
    _prompt = TextEditingController(text: t?.prompt ?? '');
    _model = TextEditingController(text: t?.model ?? '');
    _groups = {
      ...?t?.toolGroups,
      if (t == null && from != null) ...toolGroupsOf(from.id),
      if (t == null && from == null) 'read',
    };
  }

  @override
  void dispose() {
    _label.dispose();
    _description.dispose();
    _prompt.dispose();
    _model.dispose();
    super.dispose();
  }

  String get _id => studioAgentId(_label.text);

  /// Why this cannot be saved as it stands, or null.
  String? _problem(StudioConfig config) {
    if (_id.isEmpty) return 'Give it a name.';
    if (kBuiltInAgentTypes.any((b) => b.id == _id)) {
      return 'That name belongs to a built-in type.';
    }
    final taken = config.customAgents
        .any((a) => a.id == _id && a.id != widget.type?.id);
    if (taken) return 'You already have a type called that.';
    if (_description.text.trim().isEmpty) {
      return 'Say what it is for — the Studio reads this to decide when to '
          'use it.';
    }
    return null;
  }

  void _save() {
    final state = context.read<AppState>();
    final config = state.studioConfig;
    final problem = _problem(config);
    if (problem != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    final next = StudioAgentType(
      id: _id,
      label: _label.text.trim(),
      description: _description.text.trim(),
      prompt: _prompt.text.trim(),
      toolGroups: Set.of(_groups),
      model: _model.text.trim(),
    );
    final list = [
      for (final a in config.customAgents)
        if (a.id != widget.type?.id) a,
    ];
    final at = widget.type == null
        ? list.length
        : config.customAgents.indexWhere((a) => a.id == widget.type!.id);
    list.insert(at.clamp(0, list.length), next);
    unawaited(state.updateStudioConfig(config.copyWith(customAgents: list)));
    Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${widget.type!.label}?'),
        content: const Text('Sub-agents already started with it keep their '
            'conversations.'),
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
    final config = state.studioConfig;
    unawaited(state.updateStudioConfig(config.copyWith(customAgents: [
      for (final a in config.customAgents)
        if (a.id != widget.type!.id) a,
    ])));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.type == null ? 'New sub-agent type' : 'Edit type'),
        actions: [
          if (widget.type != null)
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              key: const Key('studio-agent-save'),
              onPressed: _save,
              child: const Text('Save'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: settingsPagePadding(context),
        children: [
          const SizedBox(height: 8),
          TextField(
            key: const Key('studio-agent-label'),
            controller: _label,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Name',
              hintText: 'Voice coach',
              helperText: _id.isEmpty ? null : 'Called "$_id" by the Studio',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            key: const Key('studio-agent-description'),
            controller: _description,
            maxLines: 2,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'What it is for',
              hintText: 'Rewrites dialogue so every character sounds distinct.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          // A fixed-height box the words scroll inside, like the creator's
          // long fields, so the page does not bob under the caret.
          SizedBox(
            height: 200,
            child: TextField(
              key: const Key('studio-agent-prompt'),
              controller: _prompt,
              expands: true,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'What it is told',
                alignLabelWithHint: true,
                hintText: 'How it should work, what to focus on, what to '
                    'report. The rules every sub-agent follows are added '
                    'after this.',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          SettingsGroup(
            title: 'What it may use',
            children: [
              for (final g in kStudioToolGroups.entries)
                CheckboxListTile(
                  key: Key('studio-agent-tools-${g.key}'),
                  contentPadding: const EdgeInsets.fromLTRB(20, 2, 12, 2),
                  title: Text(g.value.$1),
                  value: _groups.contains(g.key),
                  onChanged: (v) => setState(() {
                    if (v ?? false) {
                      _groups.add(g.key);
                    } else {
                      _groups.remove(g.key);
                    }
                  }),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Text('It can always keep a plan. Sub-agents never start '
                'sub-agents of their own, and the memory stays with the '
                'main agent.', style: muted),
          ),
          const SizedBox(height: 32),
          TextField(
            key: const Key('studio-agent-model'),
            controller: _model,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Model',
              hintText: 'The Studio\'s own',
              helperText: 'On the Studio\'s provider. Leave empty to use its '
                  'model.',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }
}
