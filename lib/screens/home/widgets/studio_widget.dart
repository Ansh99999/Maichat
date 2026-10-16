import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../../models/home_layout.dart';
import '../../../models/studio.dart';
import '../../../services/studio/studio_controller.dart';
import '../../../services/studio/studio_store.dart';
import '../../../state/app_state.dart';
import '../../../widgets/character_avatar.dart';
import '../../studio/studio_home_screen.dart';
import '../../studio/studio_screen.dart';
import '../home_icon_shape.dart';
import '../home_spec.dart';
import '../quick_targets.dart';

/// The Character Studio, front and centre: its latest sessions, and what its
/// agents are doing. The amount shown grows with the tile's span — an icon
/// with a working dot at 1×1, a one-line status at 2×1, one session's detail
/// (progress, current todo, sub-agents) at 2×2, a session list at 4×2 and up,
/// and a recent-changes timeline alongside it once there is room for both.
class StudioSpec extends HomeWidgetSpec {
  const StudioSpec();

  @override
  HomeWidgetKind get kind => HomeWidgetKind.studio;

  @override
  String get title => 'Studio';

  @override
  String get description => 'The Character Studio and its sessions';

  @override
  IconData get icon => Icons.auto_awesome_outlined;

  @override
  String describe(BuildContext context, HomeTile tile) => 'Studio';

  @override
  Widget build(BuildContext context, HomeTileContext tile) {
    if (tile.w <= 1 && tile.h <= 1) {
      return _StudioIcon(
        editing: tile.editing,
        shape: tile.layout.iconShape,
        showLabel: tile.layout.showLabels,
      );
    }
    return _StudioCard(key: ValueKey(tile.tile.id), tile: tile);
  }
}

String _agoText(DateTime at) {
  final d = DateTime.now().difference(at);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

String _statusText(StudioSession s, bool running) {
  if (running) return 'Working…';
  if (s.appliedAt == null && s.ops.isNotEmpty) return 'Not applied yet';
  return _agoText(s.updatedAt);
}

/// The current to-do line for a running session, or null with none in
/// progress.
StudioTodo? _currentTodo(StudioSession s) {
  for (final t in s.todos) {
    if (t.status == StudioTodoStatus.inProgress) return t;
  }
  return null;
}

({int done, int total}) _todoProgress(StudioSession s) {
  final total = s.todos.length;
  final done = s.todos.where((t) => t.status == StudioTodoStatus.completed).length;
  return (done: done, total: total);
}

class _StudioIcon extends StatefulWidget {
  const _StudioIcon({
    required this.editing,
    required this.shape,
    required this.showLabel,
  });

  final bool editing;
  final HomeIconShape shape;
  final bool showLabel;

  @override
  State<_StudioIcon> createState() => _StudioIconState();
}

class _StudioIconState extends State<_StudioIcon> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (!widget.editing) _checkBusy();
  }

  Future<void> _checkBusy() async {
    final state = context.read<AppState>();
    final store = state.studioStore;
    if (store == null) return;
    final sessions = await store.list();
    if (!mounted) return;
    final busy = sessions.any((s) => StudioHub.instance.isRunning(s.id));
    if (busy != _busy) setState(() => _busy = busy);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Studio${_busy ? ', working' : ''}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.editing ? null : () => openCharacterStudio(context),
        child: LayoutBuilder(
          builder: (context, c) {
            final labelRoom = widget.showLabel ? 20.0 : 0.0;
            final side = (c.maxWidth < c.maxHeight - labelRoom
                    ? c.maxWidth
                    : c.maxHeight - labelRoom)
                .clamp(24.0, 58.0);
            final border = homeIconBorder(widget.shape, side);
            final icon = Stack(
              clipBehavior: Clip.none,
              children: [
                HomeOutlined(
                  shape: border,
                  child: Container(
                    width: side,
                    height: side,
                    decoration: ShapeDecoration(
                      // Tertiary, so the Studio stands apart from the shortcuts.
                      color: scheme.tertiaryContainer,
                      shape: border,
                    ),
                    child: Icon(Icons.auto_awesome,
                        size: side * 0.46, color: scheme.onTertiaryContainer),
                  ),
                ),
                if (_busy)
                  Positioned(
                    right: 0,
                    top: 0,
                    child: Container(
                      width: side * 0.22,
                      height: side * 0.22,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.surface, width: 2),
                      ),
                    ),
                  ),
              ],
            );
            return HomeShrink(
              size: c.biggest,
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  icon,
                  if (widget.showLabel) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Studio',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _StudioCard extends StatefulWidget {
  const _StudioCard({super.key, required this.tile});

  final HomeTileContext tile;

  @override
  State<_StudioCard> createState() => _StudioCardState();
}

class _StudioCardState extends State<_StudioCard> {
  List<StudioSession>? _sessions;
  StudioStore? _store;
  bool _loading = false;

  bool get _editing => widget.tile.editing;

  @override
  void initState() {
    super.initState();
    if (!_editing) _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    final state = context.read<AppState>();
    final store = state.studioStore;
    if (store == null) {
      if (mounted) setState(() => _sessions = const []);
      _loading = false;
      return;
    }
    final sessions = await store.list();
    if (!mounted) return;
    setState(() {
      _store = store;
      _sessions = [
        for (final s in sessions) StudioHub.instance.find(s.id)?.session ?? s,
      ];
    });
    _loading = false;
  }

  Future<void> _openNew() async {
    if (_editing) return;
    await openNewStudioSession(context);
    if (mounted) await _load();
  }

  Future<void> _openSession(StudioSession session) async {
    if (_editing || _store == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: kStudioSessionRoute),
      builder: (_) => StudioScreen(store: _store!, session: session),
    ));
    if (mounted) await _load();
  }

  Future<void> _openHome() async {
    if (_editing) return;
    await openCharacterStudio(context);
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sessions = _sessions;
    final running =
        sessions?.where((s) => StudioHub.instance.isRunning(s.id)).length ?? 0;
    final w = widget.tile.w;
    final h = widget.tile.h;

    return HomeCard(
      semanticLabel: running > 0 ? 'Studio, $running working' : 'Studio',
      color: scheme.tertiaryContainer.withValues(alpha: 0.55),
      alignment: AlignmentDirectional.topStart,
      onTap: _editing ? null : _openHome,
      builder: (context, inner) {
        if (sessions == null) {
          // Loading: an empty header only — never a spinner (it would stop
          // pumpAndSettle in widget tests, and reads as "stuck" to a user on
          // a slow disk, where a half-second of nothing reads as "quick").
          return _Header(
            title: 'Studio',
            onNew: _editing ? null : _openNew,
            wide: inner.width >= 200,
          );
        }

        // 2x1 and similarly short-and-wide spans: one line only.
        if (h <= 1 && w >= 2) {
          return _OneLineRow(sessions: sessions, running: running);
        }

        // 2x2-ish: one session's detail (the most recently touched, or the
        // one working), with its progress/todo/sub-agents.
        if (w <= 3 && h <= 3) {
          return _DetailCard(
            sessions: sessions,
            onNew: _editing ? null : _openNew,
            onOpen: _editing ? null : _openSession,
            inner: inner,
          );
        }

        // 4x2 and up: header + a session list, and once there is enough
        // height too, a recent-changes timeline for the top session.
        final titleStyle = theme.textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.w700);
        final headerH = homeLineHeight(context, titleStyle) > 40
            ? homeLineHeight(context, titleStyle)
            : 40.0;
        final showTimeline = h >= 4 && sessions.isNotEmpty;
        // HomeShrink hands this builder an unbounded height (it measures the
        // natural size and scales down if needed), so the body below the
        // header is sized to the inner box by hand rather than with
        // Expanded/Flexible, which need a bounded height to resolve.
        final bodyH = (inner.height - headerH - 8).clamp(0.0, double.infinity);
        final bodyW = inner.width;
        final listOrTimeline = sessions.isEmpty
            ? HomeShrink(
                size: Size(bodyW, bodyH),
                alignment: AlignmentDirectional.topStart,
                child: SizedBox(
                  width: bodyW,
                  child: _EmptyBlurb(onStart: _editing ? null : _openNew),
                ),
              )
            : showTimeline
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: (inner.width - 14) * 3 / 5,
                        height: bodyH,
                        child: _SessionList(
                          sessions: sessions,
                          editing: _editing,
                          onTap: _openSession,
                        ),
                      ),
                      const SizedBox(width: 14),
                      SizedBox(
                        width: (inner.width - 14) * 2 / 5,
                        height: bodyH,
                        child: _OpsTimeline(session: sessions.first),
                      ),
                    ],
                  )
                : _SessionList(
                    sessions: sessions,
                    editing: _editing,
                    onTap: _openSession,
                  );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: headerH,
              child: _Header(
                title: running > 0 ? 'Studio · $running working' : 'Studio',
                onNew: _editing ? null : _openNew,
                wide: inner.width >= 200,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(height: bodyH, child: listOrTimeline),
          ],
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.onNew, required this.wide});

  final String title;
  final VoidCallback? onNew;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final titleStyle =
        theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700);
    return Row(
      children: [
        Icon(Icons.auto_awesome, size: 20, color: scheme.tertiary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          ),
        ),
        if (wide)
          FilledButton.tonalIcon(
            onPressed: onNew,
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('New'),
          )
        else
          IconButton.filledTonal(
            tooltip: 'New Studio session',
            visualDensity: VisualDensity.compact,
            onPressed: onNew,
            icon: const Icon(Icons.add_rounded, size: 18),
          ),
      ],
    );
  }
}

/// A short, wide span (2×1): the busiest/most recent session's name and
/// status on one line, or the plain "Studio" title with nothing to report.
class _OneLineRow extends StatelessWidget {
  const _OneLineRow({required this.sessions, required this.running});

  final List<StudioSession> sessions;
  final int running;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (sessions.isEmpty) {
      return Row(
        children: [
          Icon(Icons.auto_awesome, size: 20, color: scheme.tertiary),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Studio',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ),
        ],
      );
    }
    final top = sessions.first;
    final isRunning = StudioHub.instance.isRunning(top.id);
    return Row(
      children: [
        CharacterAvatar(character: top.workspace.character, radius: 14),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(top.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium),
              Text(
                running > 0 ? '$running working' : _statusText(top, isRunning),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: isRunning ? scheme.primary : scheme.outline,
                ),
              ),
            ],
          ),
        ),
        if (isRunning)
          Icon(Icons.bolt_rounded, size: 16, color: scheme.primary),
      ],
    );
  }
}

/// A 2x2-ish span: the empty-state blurb/button, or the top session's
/// detail — status chip, progress bar, current to-do, and a dot per
/// sub-agent — kept live via a [ListenableBuilder] on its controller when
/// one is open.
class _DetailCard extends StatelessWidget {
  const _DetailCard({
    required this.sessions,
    required this.onNew,
    required this.onOpen,
    required this.inner,
  });

  final List<StudioSession> sessions;
  final VoidCallback? onNew;
  final void Function(StudioSession)? onOpen;
  final Size inner;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final titleStyle =
        theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700);

    if (sessions.isEmpty) {
      // HomeShrink hands this an unbounded height, so the blurb below the
      // header is given an explicit height rather than Expanded.
      final headerH = homeLineHeight(context, titleStyle).clamp(28.0, 40.0);
      final blurbH =
          (inner.height - headerH - 6).clamp(0.0, double.infinity);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Header(title: 'Studio', onNew: onNew, wide: inner.width >= 200),
          const SizedBox(height: 6),
          HomeShrink(
            size: Size(inner.width, blurbH),
            alignment: AlignmentDirectional.topStart,
            child: SizedBox(
              width: inner.width,
              child: _EmptyBlurb(onStart: onNew),
            ),
          ),
        ],
      );
    }

    final top = sessions.first;
    final controller = StudioHub.instance.find(top.id);

    Widget detail(StudioSession s, bool running, StudioController? live) {
      final todo = _currentTodo(s);
      final progress = _todoProgress(s);
      final subagents = live?.subagents ?? s.subagents;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome, size: 18, color: scheme.tertiary),
              const SizedBox(width: 6),
              Expanded(
                child: Text('Studio',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle),
              ),
              _StatusChip(running: running),
            ],
          ),
          const SizedBox(height: 10),
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onOpen == null ? null : () => onOpen!(s),
            child: Row(
              children: [
                CharacterAvatar(character: s.workspace.character, radius: 16),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(s.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium),
                ),
              ],
            ),
          ),
          if (progress.total > 0) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress.done / progress.total,
                minHeight: 6,
                backgroundColor: scheme.surfaceContainerHighest,
                color: scheme.tertiary,
              ),
            ),
          ],
          if (todo != null) ...[
            const SizedBox(height: 8),
            Text(
              todo.content,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          if (subagents.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final a in subagents)
                  _SubagentDot(subagent: a),
              ],
            ),
          ],
        ],
      );
    }

    final running = StudioHub.instance.isRunning(top.id);
    if (controller == null) return detail(top, running, null);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) =>
          detail(controller.session, controller.busy, controller),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.running});

  final bool running;

  @override
  Widget build(BuildContext context) {
    if (!running) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: ShapeDecoration(
        color: scheme.primary.withValues(alpha: 0.15),
        shape: const StadiumBorder(),
      ),
      child: Text(
        'Working…',
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: scheme.primary),
      ),
    );
  }
}

class _SubagentDot extends StatelessWidget {
  const _SubagentDot({required this.subagent});

  final StudioSubagent subagent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (subagent.status) {
      StudioAgentStatus.running => scheme.primary,
      StudioAgentStatus.done => scheme.tertiary,
      StudioAgentStatus.failed => scheme.error,
      StudioAgentStatus.cancelled => scheme.outline,
    };
    return Tooltip(
      message: '${subagent.description} (${subagent.status.name})',
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

class _EmptyBlurb extends StatelessWidget {
  const _EmptyBlurb({required this.onStart});

  final VoidCallback? onStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          "Make someone new — the Studio's agents draft a character with you.",
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: onStart,
          style: FilledButton.styleFrom(
            backgroundColor: scheme.tertiary,
            foregroundColor: scheme.onTertiary,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            minimumSize: const Size(0, 44),
          ),
          icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
          label: const Text('New draft', maxLines: 1, softWrap: false),
        ),
      ],
    );
  }
}

class _SessionList extends StatelessWidget {
  const _SessionList({
    required this.sessions,
    required this.editing,
    required this.onTap,
  });

  final List<StudioSession> sessions;
  final bool editing;
  final void Function(StudioSession) onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView.builder(
      padding: EdgeInsets.zero,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: sessions.length,
      itemBuilder: (context, i) {
        final s = sessions[i];
        final controller = StudioHub.instance.find(s.id);

        Widget row(StudioSession session, bool running) => InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: editing ? null : () => onTap(session),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    CharacterAvatar(
                        character: session.workspace.character, radius: 16),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            session.displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                          Text(
                            _statusText(session, running),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: running
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.outline,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (running) ...[
                      const SizedBox(width: 8),
                      Icon(Icons.bolt_rounded,
                          size: 18, color: theme.colorScheme.primary),
                    ],
                  ],
                ),
              ),
            );

        if (controller == null) {
          return row(s, StudioHub.instance.isRunning(s.id));
        }
        return ListenableBuilder(
          listenable: controller,
          builder: (context, _) => row(controller.session, controller.busy),
        );
      },
    );
  }
}

/// A 4×4-and-up span's second column: the top session's most recent changes.
class _OpsTimeline extends StatelessWidget {
  const _OpsTimeline({required this.session});

  final StudioSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ops = session.ops.reversed.take(6).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Recent changes',
            style: theme.textTheme.labelLarge
                ?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 6),
        if (ops.isEmpty)
          Text('Nothing yet',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.outline))
        else
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: ops.length,
              itemBuilder: (context, i) {
                final op = ops[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: op.reverted ? scheme.outline : scheme.tertiary,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          op.summary,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: op.reverted
                                ? scheme.outline
                                : scheme.onSurface,
                            decoration: op.reverted
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
