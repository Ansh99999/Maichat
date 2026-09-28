import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/character.dart';
import '../../models/studio.dart';
import '../../services/studio/studio_controller.dart';
import '../../services/studio/studio_store.dart';
import '../../state/app_state.dart';
import '../../widgets/character_avatar.dart';
import 'studio_screen.dart';
import 'studio_settings_page.dart';

/// The route name the session list is opened under, so a session's drawer
/// can find its way back to it.
const String kStudioSessionsRoute = '/studio';

/// Opens the Character Studio on its list of sessions.
Future<void> openCharacterStudio(BuildContext context) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: kStudioSessionsRoute),
        builder: (_) => const StudioHomeScreen(),
      ),
    );

/// Opens a new Studio session that edits [character] from the library.
Future<void> openCharacterInStudio(
  BuildContext context,
  Character character,
) async {
  final store = await StudioStore.open();
  if (!context.mounted) return;
  if (store == null) {
    _noStore(context);
    return;
  }
  final state = context.read<AppState>();
  final session = studioSessionFor(state, character);
  await store.save(session);
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    settings: const RouteSettings(name: kStudioSessionRoute),
    builder: (_) => StudioScreen(store: store, session: session),
  ));
}

void _noStore(BuildContext context) =>
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('This device would not give the Studio a folder to keep '
          'its sessions in.'),
    ));

/// The Character Studio's front page: every session, newest first, and a way to
/// start another. A session is a draft — deleting one never touches the
/// library.
class StudioHomeScreen extends StatefulWidget {
  const StudioHomeScreen({super.key, this.store});

  /// A store to use instead of the app's own, for tests.
  final StudioStore? store;

  @override
  State<StudioHomeScreen> createState() => _StudioHomeScreenState();
}

class _StudioHomeScreenState extends State<StudioHomeScreen> {
  StudioStore? _store;
  List<StudioSession>? _sessions;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = widget.store ?? await StudioStore.open();
    if (store == null) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    final sessions = await store.list();
    if (!mounted) return;
    setState(() {
      _store = store;
      // A session still open in the hub is fresher than its file.
      _sessions = [
        for (final s in sessions) StudioHub.instance.find(s.id)?.session ?? s,
      ];
    });
  }

  Future<void> _open(StudioSession session) async {
    final store = _store;
    if (store == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: kStudioSessionRoute),
      builder: (_) => StudioScreen(store: store, session: session),
    ));
    await _load();
  }

  Future<void> _create() async {
    final store = _store;
    if (store == null) return;
    final session = newStudioSession();
    await store.save(session);
    await _open(session);
  }

  Future<void> _delete(StudioSession session) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this session?'),
        content: Text(
          session.appliedAt == null
              ? 'The draft and its conversation are deleted. It was never '
                  'applied, so nothing in your library changes.'
              : 'The draft and its conversation are deleted. What it already '
                  'applied stays in your library.',
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
    if (ok != true) return;
    await StudioHub.instance.close(session.id);
    await _store?.delete(session.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessions = _sessions;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Character Studio'),
        actions: [
          IconButton(
            tooltip: 'Studio settings',
            icon: const Icon(Icons.tune),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => const StudioSettingsPage(),
            )),
          ),
        ],
      ),
      floatingActionButton: _store == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _create,
              icon: const Icon(Icons.auto_awesome),
              label: const Text('New session'),
            ),
      body: _failed
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'This device would not give the Studio a folder to keep its '
                  'sessions in.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : sessions == null
              ? const Center(child: CircularProgressIndicator())
              : sessions.isEmpty
                  ? _Empty(onCreate: _create)
                  : ListView.builder(
                      padding: EdgeInsets.only(
                        top: 8,
                        bottom: 96 + MediaQuery.paddingOf(context).bottom,
                      ),
                      itemCount: sessions.length,
                      itemBuilder: (context, i) {
                        final s = sessions[i];
                        final running = StudioHub.instance.isRunning(s.id);
                        return ListTile(
                          leading: CharacterAvatar(
                            character: s.workspace.character,
                            radius: 22,
                          ),
                          title: Text(
                            s.displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            _subtitle(s, running),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: running
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          onTap: () => _open(s),
                          trailing: IconButton(
                            tooltip: 'Delete session',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _delete(s),
                          ),
                        );
                      },
                    ),
    );
  }

  static String _subtitle(StudioSession s, bool running) {
    if (running) return 'Working…';
    final parts = <String>[
      if (s.sourceCharacterId != null) 'Editing a library character',
      if (s.appliedAt != null && s.appliedSinceChange) 'Applied'
      else if (s.appliedAt != null) 'Changed since applied'
      else if (s.ops.isNotEmpty) 'Not applied yet',
      '${s.ops.where((o) => !o.reverted).length} changes',
      _ago(s.updatedAt),
    ];
    return parts.join(' · ');
  }

  static String _ago(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    if (d.inDays < 30) return '${d.inDays} d ago';
    return '${at.year}-${at.month.toString().padLeft(2, '0')}-'
        '${at.day.toString().padLeft(2, '0')}';
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome,
                size: 56, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text('Describe a character, get one',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Tell the Studio the vibe and it writes the card, its greetings, '
              'a lorebook for its world and anything else it needs — then '
              'playtests it. Everything stays a draft until you apply it.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: const Text('Start a session'),
            ),
          ],
        ),
      ),
    );
  }
}
