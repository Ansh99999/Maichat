import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/message_image.dart';
import '../../models/studio.dart';
import '../../services/studio/studio_controller.dart';
import '../../services/studio/studio_store.dart';
import '../../state/app_state.dart';
import 'shell/actions_capsule.dart';
import 'shell/area_pages.dart';
import 'shell/area_capsule.dart';
import 'shell/bottom_fade.dart';
import 'shell/context_meter.dart';
import 'shell/context_sheet.dart';
import 'shell/floating_button.dart';
import 'shell/liquid_panel.dart';
import 'shell/shell_format.dart';
import 'shell/slash_host.dart';
import 'shell/studio_chrome.dart';
import 'shell/studio_composer.dart';
import 'shell/studio_drawer.dart';
import 'shell/studio_pictures.dart';
import 'shell/subagent_list.dart';
import 'studio_agent_view.dart';
import 'studio_changes_view.dart';
import 'studio_draft_view.dart';
import 'studio_home_screen.dart';
import 'studio_settings_page.dart';
import 'studio_text_dialog.dart';

/// The route name a session is opened under.
const String kStudioSessionRoute = '/studio/session';

/// One Studio session: a large chat with the agent, with nothing across the top
/// of it — a soft menu square floats at the top left, and once the agent has
/// spawned sub-agents another at the top right, which pours out a panel
/// listing Main and every sub-agent (tapping one teleports the chat into that
/// agent's own conversation).
///
/// Everything at the bottom floats over the page, as a chat's Expressive
/// composer does: the composer, the actions capsule its ⋯ raises, and — once
/// switched on there, and until it is switched off there again — the
/// Interface | Draft | Changes capsule. The page runs on underneath and fades
/// out behind a band of frost ([StudioBottomFade]). The Draft and Changes pages
/// show the capsule alone; the composer belongs to the conversation.
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
  final ValueNotifier<List<MessageImage>> _attachments =
      ValueNotifier<List<MessageImage>>(const <MessageImage>[]);
  final GlobalKey _dockKey = GlobalKey();

  StudioArea _area = StudioArea.interface;
  bool _actionsOpen = false;

  /// Whose conversation the Interface page shows.
  String _viewing = kMainAgent;

  /// Which way the last teleport went, for the direction the chats slide.
  double _teleportDirection = 1;

  bool _panelOpen = false;
  bool _hasSubagents = false;

  /// The floating dock's resting height over the conversation, which the
  /// transcript keeps clear of. Only a height that has held for a frame is
  /// taken — see [_measureDock] — so a capsule springing open relays the
  /// transcript out once, when it lands, rather than on every frame of the
  /// spring. Measured on the conversation only: what floats over the draft and
  /// its changes is fixed ([_areasDock]), so switching pages never changes an
  /// inset and never lays a page out again mid-slide.
  double _dockHeight = 0;
  double? _pendingDock;

  /// What floats over the draft and its changes: the areas capsule alone —
  /// 52 tall, 6 above it and 14 below.
  static const double _areasDock = 6 + 52 + 14;

  /// The three pages, built once and handed back as the same instances on
  /// every rebuild of the shell, so switching areas (a setState here) does not
  /// rebuild a page. The conversation's is remade only when whose conversation
  /// it shows changes.
  late final Widget _draftPage = StudioDraftView(controller: _controller);
  late final Widget _changesPage = StudioChangesView(controller: _controller);
  late Widget _interfacePage = _buildInterface();

  /// `/` commands: their panel above the composer, and the hook the
  /// controller offers every slash line to.
  late final StudioSlashHost _slash;

  /// `/new`: a fresh session, in this one's place.
  Future<void> _newSession() async {
    final session = newStudioSession();
    await widget.store.save(session);
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
      settings: const RouteSettings(name: kStudioSessionRoute),
      builder: (_) => StudioScreen(store: widget.store, session: session),
    ));
  }

  @override
  void initState() {
    super.initState();
    _controller = StudioHub.instance.open(
      state: context.read<AppState>(),
      store: widget.store,
      session: widget.session,
    );
    _hasSubagents = _controller.hasSubagents;
    _controller.addListener(_onController);
    _slash = StudioSlashHost(
      controller: _controller,
      input: _input,
      attachments: _attachments,
      context: () => context,
      onContext: () => showStudioContextSheet(
        context,
        _controller,
        agentId: _viewing,
      ),
      onAgents: () => setState(() => _panelOpen = true),
      onNewSession: _newSession,
      toastInset: () =>
          _dockHeight + MediaQuery.viewInsetsOf(context).bottom,
    );
    // The first measure; later ones follow the dock's own size changes.
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureDock());
  }

  @override
  void dispose() {
    _controller.removeListener(_onController);
    _slash.dispose();
    _input.dispose();
    _attachments.dispose();
    StudioHub.instance.release(widget.session.id);
    super.dispose();
  }

  /// Rebuilds the screen only for what the screen itself draws from the
  /// controller — whether the sub-agents button exists. Everything else listens
  /// for itself, so a streaming reply never rebuilds the page around it.
  void _onController() {
    final has = _controller.hasSubagents;
    if (has != _hasSubagents && mounted) setState(() => _hasSubagents = has);
  }

  void _measureDock() {
    if (!mounted || _area != StudioArea.interface) return;
    final box = _dockKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final height = box.size.height;
    if ((height - _dockHeight).abs() <= 0.5) {
      _pendingDock = null;
      return;
    }
    if (_pendingDock != null && (height - _pendingDock!).abs() <= 0.5) {
      _pendingDock = null;
      setState(() => _dockHeight = height);
      return;
    }
    // Still moving (or just moved): look again next frame, and take it once it
    // has stopped.
    _pendingDock = height;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => _measureDock())
      ..scheduleFrame();
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
    setState(() {
      _area = area;
      _actionsOpen = false;
    });
  }

  /// Switches the areas capsule on or off. It is remembered app-wide, so it is
  /// still there after leaving the session or restarting — this is the only
  /// place that turns it off.
  void _toggleAreas() {
    final state = context.read<AppState>();
    final shown = !state.studioConfig.areasCapsule;
    state.updateStudioConfig(state.studioConfig.copyWith(areasCapsule: shown));
    setState(() => _actionsOpen = false);
    if (!shown) _setArea(StudioArea.interface);
  }

  Future<void> _addFromGallery() async {
    final image = await pickStudioGalleryPicture(
      context,
      characterId: _controller.session.workspace.character.id,
    );
    if (image == null || !mounted) return;
    setState(() => _actionsOpen = false);
    _attachments.value = [..._attachments.value, image];
  }

  Future<void> _addFromDevice() async {
    final images = await pickStudioDevicePictures(context);
    if (images.isEmpty || !mounted) return;
    setState(() => _actionsOpen = false);
    _attachments.value = [..._attachments.value, ...images];
  }

  /// Shows [agentId]'s conversation (Main or a sub-agent's) on the Interface
  /// page.
  void _teleport(String agentId) {
    setState(() {
      if (agentId != _viewing) {
        _teleportDirection = agentId == kMainAgent ? -1 : 1;
        _viewing = agentId;
        _interfacePage = _buildInterface();
      }
      _panelOpen = false;
      _actionsOpen = false;
    });
    _setArea(StudioArea.interface);
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

  @override
  Widget build(BuildContext context) {
    final view = MediaQuery.viewPaddingOf(context);
    final scheme = Theme.of(context).colorScheme;
    final areasShown =
        context.select<AppState, bool>((s) => s.studioConfig.areasCapsule);
    // A capsule switched off elsewhere (another session's screen) takes this
    // one back to the conversation, where the composer is.
    if (!areasShown && _area != StudioArea.interface) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _setArea(StudioArea.interface));
    }
    // What this build changes about the dock (a page switch, the capsule) is
    // measured once it has landed.
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureDock());
    final onConversation = _area == StudioArea.interface;
    final viewingMain = _viewing == kMainAgent;
    const buttonTop = StudioChrome.buttonTop;
    const margin = StudioChrome.buttonMargin;
    const size = StudioChrome.buttonSize;

    return Scaffold(
      // The keyboard lifts the floating dock (see [_KeyboardLift]); it never
      // resizes the page, so a conversation is not laid out again on every
      // frame of the keyboard's rise.
      resizeToAvoidBottomInset: false,
      onDrawerChanged: (opened) {
        if (opened) FocusManager.instance.primaryFocus?.unfocus();
      },
      drawer: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) => StudioDrawer(
          onHome: _goHome,
          onSettings: _openSettings,
          onSessions: _openSessions,
          sessionTitle: _controller.session.displayTitle,
          sessionDetail: formatSpend(_controller.session),
          onRename: _rename,
          onContext: () => showStudioContextSheet(
            context,
            _controller,
            agentId: _viewing,
          ),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final anchor = Offset(
            width - view.right - margin - size / 2,
            view.top + buttonTop + size / 2,
          );
          final rows = 1 + _controller.subagents.length;
          final panel = Rect.fromLTWH(
            view.left + 8,
            view.top + buttonTop + size + 8,
            width - view.horizontal - 16,
            (rows * SubagentList.rowHeight + 12).clamp(76.0, 272.0),
          );
          return Stack(
            children: [
              Positioned.fill(
                child: StudioAreaPages(
                  index: _area.index,
                  pages: [
                    for (final area in StudioArea.values)
                      StudioChrome(
                        statusBar: view.top,
                        bottom: view.bottom +
                            (area == StudioArea.interface
                                ? _dockHeight
                                : (areasShown ? _areasDock : 0)),
                        rightButton: _hasSubagents,
                        child: switch (area) {
                          StudioArea.interface => _interfacePage,
                          StudioArea.draft => _draftPage,
                          StudioArea.changes => _changesPage,
                        },
                      ),
                  ],
                ),
              ),
              // What scrolls up under the status bar fades out there, rather
              // than running under the clock. A plain gradient: no blur.
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: view.top + 14,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          scheme.surface.withValues(alpha: 0.92),
                          scheme.surface.withValues(alpha: 0),
                        ],
                        stops: [
                          view.top / (view.top + 14),
                          1,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _KeyboardLift(
                  child: NotificationListener<SizeChangedLayoutNotification>(
                    onNotification: (_) {
                      WidgetsBinding.instance
                          .addPostFrameCallback((_) => _measureDock());
                      return true;
                    },
                    child: SizeChangedLayoutNotifier(
                      child: _dock(
                        view: view,
                        onConversation: onConversation,
                        viewingMain: viewingMain,
                        areasShown: areasShown,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: view.top + buttonTop,
                left: view.left + margin,
                child: Builder(
                  builder: (context) => StudioFloatingButton(
                    key: const Key('studio-menu'),
                    tooltip: 'Menu',
                    icon: const Icon(Icons.menu),
                    onPressed: () => Scaffold.of(context).openDrawer(),
                  ),
                ),
              ),
              if (_hasSubagents)
                Positioned(
                  top: view.top + buttonTop,
                  right: view.right + margin,
                  child: ListenableBuilder(
                    listenable: _controller,
                    builder: (context, _) {
                      final running =
                          _controller.subagents.where((a) => a.running).length;
                      return _AgentsButton(
                        running: running,
                        open: _panelOpen,
                        onPressed: () =>
                            setState(() => _panelOpen = !_panelOpen),
                      );
                    },
                  ),
                ),
              Positioned.fill(
                child: LiquidPanel(
                  open: _panelOpen && _hasSubagents,
                  anchor: anchor,
                  panel: panel,
                  color: scheme.surfaceContainerHigh,
                  onDismiss: () => setState(() => _panelOpen = false),
                  child: SubagentList(
                    controller: _controller,
                    viewing: _viewing,
                    onSelect: _teleport,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Everything that floats over the bottom of the page, over its fade.
  Widget _dock({
    required EdgeInsets view,
    required bool onConversation,
    required bool viewingMain,
    required bool areasShown,
  }) {
    final showComposer = onConversation;
    final showActions = onConversation && viewingMain && _actionsOpen;
    final empty = !showComposer && !areasShown;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (!empty)
          const Positioned(
            left: 0,
            right: 0,
            top: -36,
            bottom: 0,
            child: StudioBottomFade(fade: 36),
          ),
        Padding(
          padding: EdgeInsets.only(
            left: view.left,
            right: view.right,
            bottom: view.bottom,
          ),
          child: RepaintBoundary(
            child: Column(
              key: _dockKey,
              mainAxisSize: MainAxisSize.min,
              children: [
                ListenableBuilder(
                  listenable: _controller,
                  builder: (context, _) => _controller.notice == null
                      ? const SizedBox(width: double.infinity)
                      : _Notice(controller: _controller),
                ),
                // A run the app closing cut off waits for a tap: resuming
                // spends, so it never starts on its own.
                ListenableBuilder(
                  listenable: _controller,
                  builder: (context, _) => _Reveal(
                    show: _controller.interrupted && !_controller.running,
                    alignment: Alignment.bottomCenter,
                    child: _InterruptedNotice(controller: _controller),
                  ),
                ),
                // Out of the composer's ⋯, from its right-hand end.
                _Reveal(
                  show: showActions,
                  alignment: Alignment.bottomRight,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
                    child: ActionsCapsule(
                      areasShown: areasShown,
                      onToggleAreas: _toggleAreas,
                      onGallery: _addFromGallery,
                      onDevice: _addFromDevice,
                    ),
                  ),
                ),
                _Reveal(
                  show: areasShown,
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      6,
                      16,
                      // Alone on Draft and Changes, it keeps off the edge.
                      showComposer ? 0 : 14,
                    ),
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
                // The composer belongs to the conversation; on the draft and
                // its changes it sinks away and the capsule rides alone.
                // `/` commands, while one is being typed.
                ListenableBuilder(
                  listenable: _slash.state,
                  builder: (context, _) => _Reveal(
                    show: showComposer && viewingMain && _slash.state.visible,
                    alignment: Alignment.bottomCenter,
                    child: _slash.panel(),
                  ),
                ),
                _Reveal(
                  show: showComposer,
                  alignment: Alignment.topCenter,
                  scale: false,
                  child: viewingMain
                      ? _slash.keys(StudioComposer(
                          controller: _controller,
                          input: _input,
                          attachments: _attachments,
                          actionsOpen: _actionsOpen,
                          onToggleActions: () =>
                              setState(() => _actionsOpen = !_actionsOpen),
                        ))
                      : _ViewingBar(
                          controller: _controller,
                          agentId: _viewing,
                          onBack: () => _teleport(kMainAgent),
                        ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// The conversation on screen: Main's, or a sub-agent's. Changing whose
  /// slides one chat out and the next in — toward a sub-agent to the left, back
  /// to Main to the right — with no fade.
  Widget _buildInterface() => ClipRect(
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
}

/// Lifts what floats at the bottom clear of the keyboard: a transform, so the
/// page underneath is neither resized nor laid out again while it rises — the
/// same lift the chat gives its Expressive composer.
class _KeyboardLift extends StatelessWidget {
  const _KeyboardLift({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final view = MediaQuery.viewPaddingOf(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final lift = (keyboard - view.bottom).clamp(0.0, double.infinity);
    return Transform.translate(offset: Offset(0, -lift), child: child);
  }
}

/// Shows or hides [child] by growing it out of (and sinking it back into)
/// [alignment]: a size-and-scale spring, never a fade.
class _Reveal extends StatelessWidget {
  const _Reveal({
    required this.show,
    required this.alignment,
    required this.child,
    this.scale = true,
  });

  final bool show;
  final Alignment alignment;
  final Widget child;
  final bool scale;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 420),
      reverseDuration: const Duration(milliseconds: 280),
      switchInCurve: Curves.easeOutBack,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final sized = SizeTransition(
          sizeFactor: animation,
          alignment: alignment,
          child: child,
        );
        return scale
            ? ScaleTransition(
                scale: animation,
                alignment: alignment,
                child: sized,
              )
            : sized;
      },
      child: show
          ? KeyedSubtree(key: const ValueKey('shown'), child: child)
          : const SizedBox(key: ValueKey('hidden'), width: double.infinity),
    );
  }
}

/// The sub-agents button: springs in the first time there is a sub-agent, and
/// carries a count of the ones still running.
class _AgentsButton extends StatelessWidget {
  const _AgentsButton({
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
      child: StudioFloatingButton(
        key: const Key('studio-agents-button'),
        tooltip: 'Sub-agents',
        selected: open,
        onPressed: onPressed,
        badge: running > 0 ? '$running' : null,
        icon: Icon(open ? Icons.account_tree : Icons.account_tree_outlined),
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
      bottom: false,
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
            // How full this sub-agent's own context is; tap for the detail.
            StudioContextMeter(controller: controller, agentId: agentId),
            const SizedBox(width: 4),
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

/// What a session the app closing cut off shows over the composer: what
/// happened, and the one tap that carries on.
class _InterruptedNotice extends StatelessWidget {
  const _InterruptedNotice({required this.controller});

  final StudioController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cut = controller.session.interruptedSubagents.length;
    return Container(
      key: const Key('studio-interrupted'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'The Studio was interrupted',
            style: theme.textTheme.titleMedium
                ?.copyWith(color: scheme.onTertiaryContainer),
          ),
          const SizedBox(height: 4),
          Text(
            cut == 0
                ? 'The app closed while it was working. Everything up to then '
                    'is saved.'
                : 'The app closed while it was working, with $cut '
                    'sub-agent${cut == 1 ? '' : 's'}. Everything up to then is '
                    'saved.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: scheme.onTertiaryContainer),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                key: const Key('studio-interrupted-dismiss'),
                onPressed: controller.dismissInterrupted,
                child: const Text('Not now'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                key: const Key('studio-resume'),
                onPressed: controller.resume,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Resume'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
