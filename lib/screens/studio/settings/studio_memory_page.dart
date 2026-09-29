import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../../services/studio/studio_knowledge.dart';
import '../../../services/studio/studio_memory.dart';
import '../../../services/studio/studio_store.dart';
import '../../../state/app_state.dart';
import '../studio_text_dialog.dart';
import 'settings_parts.dart';

/// Opens the Studio's memory: reads it (from the Studio's folder, or from
/// [store] when given) and shows it.
Future<void> openStudioMemory(BuildContext context, {StudioStore? store}) async {
  final state = context.read<AppState>();
  final found = store ?? await StudioStore.open();
  if (!context.mounted) return;
  if (found == null) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('This device would not give the Studio a folder to keep '
          'its memory in.'),
    ));
    return;
  }
  final memory = await StudioMemory.forDirectory(found.directory);
  // The tools read the same memory this page edits.
  StudioKnowledge.configure(config: () => state.studioConfig, memory: memory);
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => StudioMemoryPage(memory: memory),
  ));
}

/// What the Studio remembers about the user across sessions — the notes every
/// agent is told before it starts. Each can be edited or deleted here, new ones
/// added, and memory switched off altogether.
class StudioMemoryPage extends StatelessWidget {
  const StudioMemoryPage({super.key, required this.memory});

  final StudioMemory memory;

  Future<void> _add(BuildContext context) async {
    final text = await showStudioTextDialog(
      context,
      title: 'Remember',
      initial: '',
      hint: 'e.g. Writes greetings in third-person present',
    );
    if (text == null || !context.mounted) return;
    final refused = memory.add(text);
    if (refused != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(refused)));
    }
  }

  Future<void> _edit(BuildContext context, int index) async {
    final text = await showStudioTextDialog(
      context,
      title: 'Edit note',
      initial: memory.notes[index],
    );
    if (text != null) memory.replace(index, text);
  }

  Future<void> _clear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget everything?'),
        content: const Text('Every note the Studio has about you is deleted. '
            'Your sessions and characters stay.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (ok == true) memory.clear();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final config = state.studioConfig;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return ListenableBuilder(
      listenable: memory,
      builder: (context, _) {
        final notes = memory.notes;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Memory'),
            actions: [
              if (notes.isNotEmpty)
                IconButton(
                  tooltip: 'Forget everything',
                  icon: const Icon(Icons.delete_sweep_outlined),
                  onPressed: () => _clear(context),
                ),
            ],
          ),
          floatingActionButton: config.memoryEnabled
              ? FloatingActionButton.extended(
                  key: const Key('studio-memory-add'),
                  onPressed: () => _add(context),
                  icon: const Icon(Icons.add),
                  label: const Text('Remember'),
                )
              : null,
          body: ListView(
            padding: settingsPagePadding(context, fab: true),
            children: [
              SettingsGroup(children: [
                SwitchListTile(
                  key: const Key('studio-memory-switch'),
                  contentPadding: const EdgeInsets.fromLTRB(20, 8, 16, 8),
                  title: const Text('Remember my preferences'),
                  subtitle: const Text('Every session starts with these '
                      'notes, and the Studio adds to them as it learns.'),
                  value: config.memoryEnabled,
                  onChanged: (v) => unawaited(state.updateStudioConfig(
                    config.copyWith(memoryEnabled: v),
                  )),
                ),
              ]),
              const SizedBox(height: 32),
              if (notes.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                  child: Column(
                    children: [
                      Icon(Icons.psychology_outlined,
                          size: 48, color: theme.colorScheme.primary),
                      const SizedBox(height: 16),
                      Text(
                        'Nothing remembered yet. Tell the Studio how you like '
                        'characters built and it will keep it in mind.',
                        textAlign: TextAlign.center,
                        style: muted,
                      ),
                    ],
                  ),
                )
              else
                SettingsGroup(
                  title: '${notes.length} of $kStudioMemoryMaxNotes notes',
                  children: [
                    for (var i = 0; i < notes.length; i++)
                      ListTile(
                        key: ValueKey('memory-note-$i'),
                        contentPadding:
                            const EdgeInsets.fromLTRB(20, 8, 8, 8),
                        title: Text(notes[i]),
                        onTap: () => _edit(context, i),
                        trailing: IconButton(
                          tooltip: 'Forget',
                          icon: const Icon(Icons.close),
                          onPressed: () => memory.replace(i, ''),
                        ),
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
