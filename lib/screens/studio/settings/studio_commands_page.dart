import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/studio/studio_commands.dart';
import '../../../services/studio/studio_store.dart';
import 'settings_parts.dart';

/// Opens the user's own `/` commands.
Future<void> openStudioCommands(BuildContext context, {StudioStore? store}) async {
  final found = store ?? await StudioStore.open();
  if (!context.mounted) return;
  if (found == null) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('This device would not give the Studio a folder to keep '
          'its commands in.'),
    ));
    return;
  }
  final commands = await StudioCommandStore.forDirectory(found.directory);
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => StudioCommandsPage(store: commands),
  ));
}

/// The user's own `/` commands: saved messages with blanks to fill in, typed
/// as `/name` in the composer. Each is a file in the Studio's folder, like a
/// Claude Code command.
class StudioCommandsPage extends StatelessWidget {
  const StudioCommandsPage({super.key, required this.store});

  final StudioCommandStore store;

  void _edit(BuildContext context, [StudioCommand? command]) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => StudioCommandEditPage(store: store, command: command),
      ));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final commands = store.commands;
        return Scaffold(
          appBar: AppBar(title: const Text('Commands')),
          floatingActionButton: FloatingActionButton.extended(
            key: const Key('studio-commands-add'),
            onPressed: () => _edit(context),
            icon: const Icon(Icons.add),
            label: const Text('New command'),
          ),
          body: ListView(
            padding: settingsPagePadding(context, fab: true),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Text(
                  'A command is a message you send often, with blanks: '
                  '\$ARGUMENTS is whatever you type after it, \$1 and \$2 its '
                  'first words. Type /name in the composer to use one.',
                  style: muted,
                ),
              ),
              if (commands.isEmpty)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
                  child: Column(
                    children: [
                      Icon(Icons.keyboard_command_key,
                          size: 48, color: theme.colorScheme.primary),
                      const SizedBox(height: 16),
                      Text(
                        'No commands of your own yet. Try one like /villain: '
                        '"Add a villain to this story who \$ARGUMENTS."',
                        textAlign: TextAlign.center,
                        style: muted,
                      ),
                    ],
                  ),
                )
              else
                SettingsGroup(
                  title: '${commands.length} of your own',
                  children: [
                    for (final c in commands)
                      ListTile(
                        key: ValueKey('command-${c.name}'),
                        contentPadding: const EdgeInsets.fromLTRB(20, 10, 16, 10),
                        title: Text('/${c.name}'),
                        subtitle: Text(
                          c.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _edit(context, c),
                      ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Writing or editing one command. The message box is a fixed height and
/// scrolls inside, like the creator's long fields.
class StudioCommandEditPage extends StatefulWidget {
  const StudioCommandEditPage({super.key, required this.store, this.command});

  final StudioCommandStore store;
  final StudioCommand? command;

  @override
  State<StudioCommandEditPage> createState() => _StudioCommandEditPageState();
}

class _StudioCommandEditPageState extends State<StudioCommandEditPage> {
  late final TextEditingController _name =
      TextEditingController(text: widget.command?.name ?? '');
  late final TextEditingController _description =
      TextEditingController(text: widget.command?.description ?? '');
  late final TextEditingController _hint =
      TextEditingController(text: widget.command?.argumentHint ?? '');
  late final TextEditingController _template =
      TextEditingController(text: widget.command?.template ?? '');
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _hint.dispose();
    _template.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_template.text.trim().isEmpty) {
      setState(() => _error = 'Write the message the command sends.');
      return;
    }
    try {
      await widget.store.save(
        StudioCommand(
          name: _name.text.trim().replaceFirst(RegExp(r'^/'), ''),
          description: _description.text.trim(),
          kind: StudioCommandKind.custom,
          argumentHint: _hint.text.trim(),
          template: _template.text.trim(),
        ),
        previousName: widget.command?.name,
      );
      if (mounted) Navigator.of(context).pop();
    } on ArgumentError catch (e) {
      setState(() => _error = '${e.message}');
    }
  }

  Future<void> _delete() async {
    final name = widget.command?.name;
    if (name == null) return;
    await widget.store.delete(name);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.command == null ? 'New command' : 'Edit command'),
        actions: [
          if (widget.command != null)
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => unawaited(_delete()),
            ),
          TextButton(
            key: const Key('studio-command-save'),
            onPressed: _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: settingsPagePadding(context),
        children: [
          TextField(
            key: const Key('studio-command-name'),
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Name',
              prefixText: '/',
              helperText: 'Lower-case words joined by hyphens.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            key: const Key('studio-command-description'),
            controller: _description,
            decoration: const InputDecoration(
              labelText: 'What it does',
              helperText: 'Shown beside it when you type /.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _hint,
            decoration: const InputDecoration(
              labelText: 'What goes after it (optional)',
              hintText: '<who the villain is>',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 260,
            child: TextField(
              key: const Key('studio-command-template'),
              controller: _template,
              expands: true,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                labelText: 'The message it sends',
                helperText: '\$ARGUMENTS · \$1 · \$2',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.error)),
          ],
        ],
      ),
    );
  }
}
