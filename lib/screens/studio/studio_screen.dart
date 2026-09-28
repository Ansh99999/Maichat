import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/studio.dart';
import '../../services/studio/studio_controller.dart';
import '../../services/studio/studio_store.dart';
import '../../state/app_state.dart';
import 'shell/area_capsule.dart';
import 'shell/liquid_panel.dart';
import 'shell/studio_composer.dart';
import 'shell/studio_drawer.dart';
import 'shell/subagent_list.dart';
import 'studio_agent_view.dart';
import 'studio_changes_view.dart';
import 'studio_draft_view.dart';
import 'studio_home_screen.dart';
import 'studio_settings_page.dart';
import 'studio_text_dialog.dart';

/// The route name a session is opened under.
const String kStudioSessionRoute = '/studio/session';

/// One Studio session: a large chat with the agent, and — from the composer's
/// ⋯ → More actions → Show other areas — a capsule over the composer that
/// switches the page to the draft or its changes. When the agent spawns
/// sub-agents, a button appears at the top right; it pours out a panel listing
/// Main and every sub-agent, and tapping one teleports the chat into that
/// agent's own conversation.
///
/// It all runs over one [StudioController], which outlives this screen while
/// the agent works.
class StudioScreen extends StatefulWidget {
  const StudioScreen({super.key, required this.store, required this.session});

  final StudioStore store;
  final StudioSession session;

  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends State<StudioScreen> {
  late final StudioController _controller;
  final TextEditingController _input = TextEditingController();
  final PageController _pages = PageController();
  final GlobalKey _stackKey = GlobalKey();
  final GlobalKey _barKey = GlobalKey();
  final GlobalKey _agentsButtonKey = GlobalKey();

  StudioArea _area = StudioArea.interface;
  bool _areasShown = false;

  /// Whose conversation the Interface page shows.
  String _viewing = kMainAgent;

  /// Which way the last teleport went, for the direction the chats slide.
  double _teleportDirection = 1;

  bool _panelOpen = false;
  Offset _anchor = Offset.zero;
  Rect _panel = Rect.zero;

  @override
  void initState() {
    super.initState();
    _controller = StudioHub.instance.open(
      state: context.read<AppState>(),
      store: widget.store,
      session: widget.session,
    );
  }

  @override
  void dispose() {
    _input.dispose();
    _pages.dispose();
    StudioHub.instance.release(widget.session.id);
    super.dispose();
  }

  // --- navigation -------------------------------------------------------------

  void _goHome() => Navigator.of(context).popUntil((route) => route.isFirst);

  void _openSettings() => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const StudioSettingsPage()),
      );

  /// Back to the session list: popped to when it is below this session, opened
  /// in its place when the session was entered some other way (a character's
  /// "Open in Studio").
  void _openSessions() {
    final navigator = Navigator.of(context);
    var found = false;
    navigator.popUntil((route) {
      if (route.settings.name == kStudioSessionsRoute) {
        found = true;
        return true;
      }
      return route.isFirst;
    });
    if (!found) {
      navigator.push(MaterialPageRoute<void>(
        settings: const RouteSettings(name: kStudioSessionsRoute),
        builder: (_) => const StudioHomeScreen(),
      ));
    }
  }

  void _setArea(StudioArea area) {
    if (area == _area) return;
    setState(() => _area = area);
    _pages.animateToPage(
      area.index,
      duration: const Duration(milliseconds: 450),
      curve: Easing.emphasizedDecelerate,
    );
  }

  void _toggleAreas() {
    setState(() => _areasShown = !_areasShown);
    // Hiding the capsule goes back to the conversation, where the composer is.
    if (!_areasShown) _setArea(StudioArea.interface);
  }

  /// Shows [agentId]'s conversation (Main or a sub-agent's) on the Interface
  /// page.
  void _teleport(String agentId) {
    setState(() {
      if (agentId != _viewing) {
        _teleportDirection = agentId == kMainAgent ? -1 : 1;
        _viewing = agentId;
      }
      _panelOpen = false;
    });
    _setArea(StudioArea.interface);
  }

  void _togglePanel() {
    if (_panelOpen) {
      setState(() => _panelOpen = false);
      return;
    }
    final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    final button =
        _agentsButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final bar = _barKey.currentContext?.findRenderObject() as RenderBox?;
    if (stack == null || button == null || bar == null) return;
    final anchor = stack.globalToLocal(
      button.localToGlobal(button.size.center(Offset.zero)),
    );
    final barBottom =
        stack.globalToLocal(bar.localToGlobal(Offset(0, bar.size.height))).dy;
    final rows = 1 + _controller.subagents.length;
    final height = (rows * SubagentList.rowHeight + 12).clamp(76.0, 272.0);
    setState(() {
      _anchor = anchor;
      _panel = Rect.fromLTWH(8, barBottom + 6, stack.size.width - 16, height);
      _panelOpen = true;
    });
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
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      drawer: StudioDrawer(
        onHome: _goHome,
        onSettings: _openSettings,
        onSessions: _openSessions,
      ),
      body: Stack(
        key: _stackKey,
        children: [
          Column(
            children: [
              ListenableBuilder(
                listenable: _controller,
                builder: (context, _) => _appBar(context),
              ),
              Expanded(
                child: PageView(
                  controller: _pages,
                  // Pages change from the capsule; a sideways swipe belongs to
                  // what is on them.
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    _interface(),
                    StudioDraftView(controller: _controller),
                    StudioChangesView(controller: _controller),
                  ],
                ),
              ),
              ListenableBuilder(
                listenable: _controller,
                builder: (context, _) => _controller.notice == null
                    ? const SizedBox.shrink()
                    : _Notice(controller: _controller),
              ),
              // The capsule grows up out of the composer and sinks back into
              // it: a size-and-scale spring from its bottom edge, no fade.
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 420),
                reverseDuration: const Duration(milliseconds: 260),
                switchInCurve: Curves.easeOutBack,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => SizeTransition(
                  sizeFactor: animation,
                  alignment: Alignment.bottomCenter,
                  child: ScaleTransition(
                    scale: animation,
                    alignment: Alignment.bottomRight,
                    child: child,
                  ),
                ),
                child: !_areasShown
                    ? const SizedBox(key: ValueKey('no-capsule'), width: double.infinity)
                    : Padding(
                        key: const ValueKey('capsule'),
                        padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                        child: ListenableBuilder(
                          listenable: _controller,
                          builder: (context, _) => AreaCapsule(
                            area: _area,
                            changes: _controller.session.ops
                                .where((o) => !o.reverted)
                                .length,
                            onChanged: _setArea,
                          ),
                        ),
                      ),
              ),
              _viewing == kMainAgent || _area != StudioArea.interface
                  ? StudioComposer(
                      controller: _controller,
                      input: _input,
                      areasShown: _areasShown,
                      onToggleAreas: _toggleAreas,
                    )
                  : _ViewingBar(
                      controller: _controller,
                      agentId: _viewing,
                      onBack: () => _teleport(kMainAgent),
                    ),
            ],
          ),
          Positioned.fill(
            child: ListenableBuilder(
              listenable: _controller,
              builder: (context, _) => LiquidPanel(
                open: _panelOpen && _controller.hasSubagents,
                anchor: _anchor,
                panel: _panel,
                color: scheme.surfaceContainerHigh,
                onDismiss: () => setState(() => _panelOpen = false),
                child: SubagentList(
                  controller: _controller,
                  viewing: _viewing,
                  onSelect: _teleport,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The conversation on screen: Main's, or a sub-agent's. Changing whose
  /// slides one chat out and the next in — toward a sub-agent to the left, back
  /// to Main to the right — with no fade.
  Widget _interface() => ClipRect(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 380),
          switchInCurve: Easing.emphasizedDecelerate,
          switchOutCurve: Easing.emphasizedAccelerate,
          transitionBuilder: (child, animation) {
            final incoming = child.key == ValueKey<String>(_viewing);
            final begin = Offset(
              incoming ? _teleportDirection : -_teleportDirection,
              0,
            );
            return SlideTransition(
              position: Tween<Offset>(begin: begin, end: Offset.zero)
                  .animate(animation),
              child: child,
            );
          },
          child: StudioAgentView(
            key: ValueKey<String>(_viewing),
            controller: _controller,
            agentId: _viewing,
            onOpenAgent: _teleport,
            onPickExample: (text) => _input.text = text,
          ),
        ),
      );

  Widget _appBar(BuildContext context) {
    final session = _controller.session;
    final theme = Theme.of(context);
    final viewed =
        _viewing == kMainAgent ? null : _controller.subagent(_viewing);
    final running = _controller.subagents.where((a) => a.running).length;
    return AppBar(
      key: _barKey,
      leading: Builder(
        builder: (context) => IconButton(
          key: const Key('studio-menu'),
          tooltip: 'Menu',
          icon: const Icon(Icons.menu),
          onPressed: () => Scaffold.of(context).openDrawer(),
        ),
      ),
      title: GestureDetector(
        onTap: viewed == null ? _rename : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              viewed == null
                  ? session.displayTitle
                  : '${viewed.label} — ${viewed.description}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              viewed == null ? _spend(session) : 'Sub-agent · read-only',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (_controller.hasSubagents)
          _AgentsButton(
            key: _agentsButtonKey,
            running: running,
            open: _panelOpen,
            onPressed: _togglePanel,
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
    );
  }

  static String _spend(StudioSession s) {
    final tokens = s.inputTokens + s.outputTokens;
    if (tokens == 0) return 'Nothing spent yet';
    String k(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';
    final cost = s.cost > 0
        ? ' · \$${s.cost.toStringAsFixed(s.cost < 1 ? 3 : 2)}'
        : '';
    return '${k(s.inputTokens)} in · ${k(s.outputTokens)} out$cost';
  }
}

/// The sub-agents button: springs in the first time there is a sub-agent, and
/// carries a count of the ones still running.
class _AgentsButton extends StatelessWidget {
  const _AgentsButton({
    super.key,
    required this.running,
    required this.open,
    required this.onPressed,
  });

  final int running;
  final bool open;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 520),
      curve: Curves.elasticOut,
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
      child: IconButton(
        tooltip: 'Sub-agents',
        isSelected: open,
        onPressed: onPressed,
        icon: Badge(
          isLabelVisible: running > 0,
          label: Text('$running'),
          child: const Icon(Icons.account_tree_outlined),
        ),
        selectedIcon: Badge(
          isLabelVisible: running > 0,
          label: Text('$running'),
          child: const Icon(Icons.account_tree),
        ),
      ),
    );
  }
}

/// What replaces the composer while a sub-agent's conversation is on screen:
/// its conversation is its own, and read-only.
class _ViewingBar extends StatelessWidget {
  const _ViewingBar({
    required this.controller,
    required this.agentId,
    required this.onBack,
  });

  final StudioController controller;
  final String agentId;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final agent = controller.subagent(agentId);
    return SafeArea(
      top: false,
      child: Container(
        key: const Key('studio-viewing-bar'),
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Row(
          children: [
            Icon(Icons.smart_toy_outlined, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Viewing ${agent?.label ?? 'a sub-agent'} · read-only',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            FilledButton.tonalIcon(
              key: const Key('studio-back-to-main'),
              onPressed: onBack,
              icon: const Icon(Icons.hub_outlined, size: 18),
              label: const Text('Main'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.controller});

  final StudioController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final error = controller.noticeIsError;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: error ? scheme.errorContainer : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              controller.notice ?? '',
              style: TextStyle(
                color: error
                    ? scheme.onErrorContainer
                    : scheme.onSecondaryContainer,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Dismiss',
            icon: const Icon(Icons.close, size: 18),
            onPressed: controller.dismissNotice,
          ),
        ],
      ),
    );
  }
}
