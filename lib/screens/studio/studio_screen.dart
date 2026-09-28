import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/studio.dart';
import '../../services/studio/studio_controller.dart';
import '../../services/studio/studio_store.dart';
import '../../state/app_state.dart';
import 'studio_agent_view.dart';
import 'studio_changes_view.dart';
import 'studio_draft_view.dart';
import 'studio_settings_page.dart';
import 'studio_text_dialog.dart';

/// One Studio session: the conversation with the agent, the draft it is
/// building, and the changes it has made — three tabs over one
/// [StudioController], which outlives this screen while the agent works.
class StudioScreen extends StatefulWidget {
  const StudioScreen({super.key, required this.store, required this.session});

  final StudioStore store;
  final StudioSession session;

  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends State<StudioScreen>
    with SingleTickerProviderStateMixin {
  late final StudioController _controller;
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _controller = StudioHub.instance.open(
      state: context.read<AppState>(),
      store: widget.store,
      session: widget.session,
    );
    _tabs = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    StudioHub.instance.release(widget.session.id);
    super.dispose();
  }

  Future<void> _rename() async {
    final name = await showStudioTextDialog(
      context,
      title: 'Session name',
      initial: _controller.session.title,
      hint: 'Named after the character',
    );
    if (name != null) _controller.rename(name);
  }

  Future<void> _apply() async {
    final state = context.read<AppState>();
    final session = _controller.session;
    final ws = session.workspace;
    final c = ws.character;
    if (c.name.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('The character needs a name before it can be saved.'),
      ));
      return;
    }
    final existing = state.characterById(c.id) != null;
    var folder = session.folderId != null;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('Apply to library'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(existing
                  ? 'Replaces ${c.displayName} in your library with this draft.'
                  : 'Adds ${c.displayName} to your characters.'),
              if (ws.lorebooks.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Saves ${ws.lorebooks.length} lorebook'
                    '${ws.lorebooks.length == 1 ? '' : 's'}, attached to them.'),
              ],
              if (ws.documents.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(state.embeddingReady
                    ? 'Indexes ${ws.documents.length} document'
                        '${ws.documents.length == 1 ? '' : 's'} into embeddings.'
                    : '${ws.documents.length} document'
                        '${ws.documents.length == 1 ? ' is' : 's are'} left out: '
                        'embeddings are off.'),
              ],
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: folder,
                onChanged: (v) => setDialog(() => folder = v ?? false),
                title: const Text('Bundle into a folder'),
                subtitle: const Text('The character, its lorebooks and '
                    'documents, together.'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    if (go != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await _controller.apply(bundleFolder: folder);
      final parts = <String>[
        'Saved ${result.characterName}',
        if (result.lorebooks > 0)
          '${result.lorebooks} lorebook${result.lorebooks == 1 ? '' : 's'}',
        if (result.documents > 0)
          '${result.documents} document${result.documents == 1 ? '' : 's'}',
        if (result.folderName != null) 'folder "${result.folderName}"',
      ];
      messenger.showSnackBar(SnackBar(
        content: Text('${parts.join(', ')}.'
            '${result.documentsSkipped > 0 ? ' ${result.documentsSkipped} document(s) skipped.' : ''}'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not apply: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final session = _controller.session;
        final theme = Theme.of(context);
        final changes = session.ops.where((o) => !o.reverted).length;
        return Scaffold(
          appBar: AppBar(
            title: GestureDetector(
              onTap: _rename,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    session.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _spend(session),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              IconButton(
                tooltip: 'Studio settings',
                icon: const Icon(Icons.tune),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const StudioSettingsPage(),
                  ),
                ),
              ),
              IconButton(
                tooltip: session.appliedSinceChange
                    ? 'Applied — nothing new to save'
                    : 'Apply to library',
                icon: Icon(
                  session.appliedSinceChange
                      ? Icons.check_circle
                      : Icons.check_circle_outline,
                ),
                onPressed: _controller.running ? null : _apply,
              ),
            ],
            bottom: TabBar(
              controller: _tabs,
              tabs: [
                const Tab(text: 'Agent'),
                const Tab(text: 'Draft'),
                Tab(text: changes == 0 ? 'Changes' : 'Changes ($changes)'),
              ],
            ),
          ),
          body: TabBarView(
            controller: _tabs,
            children: [
              StudioAgentView(controller: _controller),
              StudioDraftView(controller: _controller),
              StudioChangesView(controller: _controller),
            ],
          ),
        );
      },
    );
  }

  static String _spend(StudioSession s) {
    final tokens = s.inputTokens + s.outputTokens;
    if (tokens == 0) return 'Nothing spent yet';
    String k(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';
    final cost = s.cost > 0 ? ' · \$${s.cost.toStringAsFixed(s.cost < 1 ? 3 : 2)}' : '';
    return '${k(s.inputTokens)} in · ${k(s.outputTokens)} out$cost';
  }
}
