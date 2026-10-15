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
/// agents are doing.
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
    final isIconTile = tile.w <= 1 && tile.h <= 1;
    if (isIconTile) {
      return _StudioIcon(
        editing: tile.editing,
        shape: tile.layout.iconShape,
        showLabel: tile.layout.showLabels,
      );
    }
    return _StudioCard(key: ValueKey(tile.tile.id), editing: tile.editing);
  }
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
            final icon = Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: side,
                  height: side,
                  decoration: ShapeDecoration(
                    // Tertiary, so the Studio stands apart from the shortcuts.
                    color: scheme.tertiaryContainer,
                    shape: homeIconBorder(widget.shape, side),
                  ),
                  child: Icon(Icons.auto_awesome,
                      size: side * 0.46, color: scheme.onTertiaryContainer),
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
  const _StudioCard({super.key, required this.editing});

  final bool editing;

  @override
  State<_StudioCard> createState() => _StudioCardState();
}

class _StudioCardState extends State<_StudioCard> {
  List<StudioSession>? _sessions;
  StudioStore? _store;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    if (!widget.editing) _load();
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
    if (widget.editing) return;
    await openNewStudioSession(context);
    if (mounted) await _load();
  }

  Future<void> _openSession(StudioSession session) async {
    if (widget.editing || _store == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: kStudioSessionRoute),
      builder: (_) => StudioScreen(store: _store!, session: session),
    ));
    if (mounted) await _load();
  }

  Future<void> _openHome() async {
    if (widget.editing) return;
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
    return HomeCard(
      semanticLabel: running > 0 ? 'Studio, $running working' : 'Studio',
      color: scheme.tertiaryContainer.withValues(alpha: 0.55),
      alignment: AlignmentDirectional.topStart,
      onTap: widget.editing ? null : _openHome,
      builder: (context, inner) {
        final titleStyle =
            theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700);
        final headerH = homeLineHeight(context, titleStyle) > 40
            ? homeLineHeight(context, titleStyle)
            : 40.0;
        final rowH = 44.0 * MediaQuery.textScalerOf(context).scale(1);
        final room = inner.height - headerH - 6;
        final rows = sessions == null || sessions.isEmpty
            ? 0
            : (room / rowH).floor().clamp(0, sessions.length);
        final blurbLine = homeLineHeight(context, theme.textTheme.bodySmall);
        final showBlurb = (sessions?.isEmpty ?? false) && room >= blurbLine;
        // The button wants ~48 px under up to three lines of words.
        final showStart = showBlurb && room >= blurbLine * 3 + 62 &&
            inner.width >= 120;
        final blurbLines = showStart
            ? 3
            : (room / blurbLine).floor().clamp(1, 5);
        final wideButton = inner.width >= 200;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: headerH,
              child: Row(
                children: [
                  Icon(Icons.auto_awesome, size: 20, color: scheme.tertiary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      running > 0 ? 'Studio · $running working' : 'Studio',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: titleStyle,
                    ),
                  ),
                  if (wideButton)
                    FilledButton.tonalIcon(
                      onPressed: widget.editing ? null : _openNew,
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
                      onPressed: widget.editing ? null : _openNew,
                      icon: const Icon(Icons.add_rounded, size: 18),
                    ),
                ],
              ),
            ),
            if (showBlurb)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  "Make someone new — the Studio's agents draft a character "
                  'with you.',
                  maxLines: blurbLines,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            // Room to spare on an empty Studio: say it with a button too.
            if (showStart)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: FilledButton.icon(
                  onPressed: widget.editing ? null : _openNew,
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.tertiary,
                    foregroundColor: scheme.onTertiary,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    minimumSize: const Size(0, 44),
                  ),
                  icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
                  label: const Text('New draft', maxLines: 1, softWrap: false),
                ),
              ),
            if (rows > 0) ...[
              const SizedBox(height: 6),
              _SessionList(
                sessions: sessions!.take(rows).toList(),
                editing: widget.editing,
                onTap: _openSession,
              ),
            ],
          ],
        );
      },
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final s in sessions)
          () {
            final running = StudioHub.instance.isRunning(s.id);
            return InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: editing ? null : () => onTap(s),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    CharacterAvatar(character: s.workspace.character, radius: 16),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            s.displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                          Text(
                            _status(s, running),
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
          }(),
      ],
    );
  }

  String _status(StudioSession s, bool running) {
    if (running) return 'Working…';
    if (s.appliedAt == null && s.ops.isNotEmpty) return 'Not applied yet';
    return _ago(s.updatedAt);
  }

  String _ago(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }
}
