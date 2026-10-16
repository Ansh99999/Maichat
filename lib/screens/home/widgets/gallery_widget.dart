import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../models/gallery_image.dart';
import '../../../models/home_layout.dart';
import '../../../widgets/avatar_image.dart';
import '../../../widgets/picture_viewer.dart';
import '../../../widgets/smooth_image.dart';
import '../home_spec.dart';
import 'chat_card_tile.dart';

/// A grid of pictures from the gallery — one, or as many as fit the span.
/// Each slot swipes independently through its pool, like a small Pinterest.
class GallerySpec extends HomeWidgetSpec {
  const GallerySpec();

  @override
  HomeWidgetKind get kind => HomeWidgetKind.gallery;

  @override
  String get title => 'Gallery';

  @override
  String get description => 'Pictures from your gallery, swipe to change';

  @override
  IconData get icon => Icons.photo_library_outlined;

  @override
  List<HomeOption> options(HomeTile tile) => [
        const HomeChoiceOption(
          key: 'count',
          label: 'Pictures',
          choices: {'1': '1', '2': '2', '4': '4', '6': '6'},
        ),
        const HomeChoiceOption(
          key: 'fit',
          label: 'Fit',
          choices: {'cover': 'Cover', 'contain': 'Contain'},
        ),
        const HomeChoiceOption(
          key: 'source',
          label: 'Source',
          choices: {'all': 'All pictures', 'starred': 'Starred', 'character': 'One character'},
        ),
        HomePickOption(
          key: 'characterId',
          label: 'Character',
          pick: HomePickKind.character,
          allowNone: true,
          noneLabel: 'Any',
        ),
        HomePickOption(
          key: 'image',
          label: 'Pin a picture',
          pick: HomePickKind.picture,
          allowNone: true,
          noneLabel: 'None — all swipeable',
        ),
        const HomeToggleOption(
          key: 'shuffle',
          label: 'Shuffle every 30s',
        ),
      ];

  @override
  String describe(BuildContext context, HomeTile tile) {
    final count = tile.integer('count', 1);
    return 'Gallery · $count ${count == 1 ? 'picture' : 'pictures'}';
  }

  @override
  Widget build(BuildContext context, HomeTileContext tile) {
    final state = homeWatch(context, (s) {
      final b = StringBuffer();
      for (final g in s.gallery) {
        b
          ..write(g.id)
          ..write(g.image)
          ..write(g.starred ? '*' : '')
          ..write(g.characterId)
          ..write('|');
      }
      return b.toString();
    });
    final count = tile.tile.integer('count', 1).clamp(1, 6);
    final fit = tile.tile.str('fit') == 'contain' ? BoxFit.contain : BoxFit.cover;
    final source = tile.tile.str('source') ?? 'all';
    final characterId = tile.tile.str('characterId');
    final pinnedImage = tile.tile.str('image');
    final shuffle = tile.tile.flag('shuffle', false);

    var pool = state.gallery.toList();
    if (source == 'starred') {
      pool = pool.where((g) => g.starred).toList();
    } else if (source == 'character' && characterId != null) {
      pool = pool.where((g) => g.characterId == characterId).toList();
    }

    if (pool.isEmpty) {
      return const HomeEmptyCard(
        icon: Icons.photo_outlined,
        message: 'Your pictures will show here',
      );
    }

    return HomeCard(
      padding: EdgeInsets.zero,
      clip: true,
      // The grid sizes itself to the box; nothing to scale.
      fit: false,
      semanticLabel: 'Gallery, $count ${count == 1 ? 'picture' : 'pictures'}',
      child: _GalleryGrid(
        key: ValueKey('${tile.tile.id}-${pool.length}'),
        pool: pool,
        count: count,
        fit: fit,
        pinnedImage: pinnedImage,
        shuffle: shuffle && !tile.editing,
        editing: tile.editing,
      ),
    );
  }
}

class _GalleryGrid extends StatefulWidget {
  const _GalleryGrid({
    super.key,
    required this.pool,
    required this.count,
    required this.fit,
    required this.pinnedImage,
    required this.shuffle,
    required this.editing,
  });

  final List<GalleryImage> pool;
  final int count;
  final BoxFit fit;
  final String? pinnedImage;
  final bool shuffle;
  final bool editing;

  @override
  State<_GalleryGrid> createState() => _GalleryGridState();
}

class _GalleryGridState extends State<_GalleryGrid> {
  late List<PageController> _controllers;
  Timer? _timer;
  ValueListenable<TickerModeData>? _mode;
  bool _enabled = false;

  @override
  void initState() {
    super.initState();
    _buildControllers();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final mode = TickerMode.getValuesNotifier(context);
    if (!identical(mode, _mode)) {
      _mode?.removeListener(_modeChanged);
      _mode = mode..addListener(_modeChanged);
      _modeChanged();
    }
  }

  void _modeChanged() {
    final enabled = _mode?.value.enabled ?? false;
    if (enabled == _enabled) return;
    _enabled = enabled;
    _maybeStartShuffle();
  }

  /// Pages start far from zero so a slot swipes both ways without an end.
  static const int _lap = 1000;

  void _buildControllers() {
    final n = widget.pool.length;
    _controllers = List.generate(widget.count, (i) {
      // Each slot starts on a different picture.
      return PageController(initialPage: n == 0 ? 0 : n * _lap + i % n);
    });
  }

  void _maybeStartShuffle() {
    _timer?.cancel();
    _timer = null;
    if (!_enabled || !widget.shuffle || widget.pool.length < 2) return;
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      for (final c in _controllers) {
        if (!c.hasClients) continue;
        c.nextPage(
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeInOutCubicEmphasized,
        );
      }
    });
  }

  @override
  void didUpdateWidget(_GalleryGrid old) {
    super.didUpdateWidget(old);
    if (old.count != widget.count || old.pool.length != widget.pool.length) {
      for (final c in _controllers) {
        c.dispose();
      }
      _buildControllers();
    }
    if (old.shuffle != widget.shuffle ||
        old.pool.length != widget.pool.length) {
      _maybeStartShuffle();
    }
  }

  @override
  void dispose() {
    _mode?.removeListener(_modeChanged);
    _timer?.cancel();
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  /// The columns × rows that keep [count] cells closest to square in [box].
  static (int, int) _gridFor(int count, Size box) {
    var best = (1, count);
    var bestScore = double.infinity;
    for (var cols = 1; cols <= count; cols++) {
      final rows = (count / cols).ceil();
      if (cols * rows - count >= cols) continue; // a whole empty row
      final aspect = (box.width / cols) / (box.height / rows);
      final score = (aspect > 1 ? aspect : 1 / aspect) + (cols * rows - count) * 0.6;
      if (score < bestScore) {
        bestScore = score;
        best = (cols, rows);
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final pinnedIndex = widget.pinnedImage == null
        ? -1
        : widget.pool.indexWhere((g) => g.image == widget.pinnedImage);
    const gap = 3.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = constraints.biggest;
        final (cols, rows) = _gridFor(widget.count, box);
        final cellW = (box.width - gap * (cols + 1)) / cols;
        final cellH = (box.height - gap * (rows + 1)) / rows;
        if (cellW <= 0 || cellH <= 0) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.all(gap),
          child: Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (var i = 0; i < widget.count; i++)
                SizedBox(
                  width: cellW,
                  height: cellH,
                  child: ClipRSuperellipse(
                    borderRadius: BorderRadius.circular(
                      widget.count == 1 ? HomeCard.radius - gap : 18,
                    ),
                    child: i == 0 && pinnedIndex >= 0
                        ? _Picture(
                            picture: widget.pool[pinnedIndex],
                            pool: widget.pool,
                            index: pinnedIndex,
                            fit: widget.fit,
                            editing: widget.editing,
                          )
                        : _Slot(
                            pool: widget.pool,
                            controller: _controllers[i],
                            fit: widget.fit,
                            editing: widget.editing,
                          ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Slot extends StatelessWidget {
  const _Slot({
    required this.pool,
    required this.controller,
    required this.fit,
    required this.editing,
  });

  final List<GalleryImage> pool;
  final PageController controller;
  final BoxFit fit;
  final bool editing;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      label: 'Picture, swipe to change',
      child: PageView.builder(
        controller: controller,
        physics: editing
            ? const NeverScrollableScrollPhysics()
            : const PageScrollPhysics(),
        // Endless: the pool repeats in both directions.
        itemBuilder: (context, i) {
          final index = i % pool.length;
          return _Picture(
            picture: pool[index],
            pool: pool,
            index: index,
            fit: fit,
            editing: editing,
          );
        },
      ),
    );
  }
}

/// One picture filling its cell, opening the viewer on a tap.
class _Picture extends StatelessWidget {
  const _Picture({
    required this.picture,
    required this.pool,
    required this.index,
    required this.fit,
    required this.editing,
  });

  final GalleryImage picture;
  final List<GalleryImage> pool;
  final int index;
  final BoxFit fit;
  final bool editing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: editing
          ? null
          : () => showPictureViewer(
                context,
                refs: [for (final g in pool) g.image],
                index: index,
              ),
      child: LayoutBuilder(
        builder: (context, c) {
          final provider = avatarImage(
            picture.image,
            displaySize: c.biggest.longestSide,
            devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
          );
          if (provider == null) {
            return ColoredBox(
              color: scheme.surfaceContainerHighest,
              child: Icon(Icons.image_outlined, color: scheme.outline),
            );
          }
          return ColoredBox(
            color: scheme.surfaceContainerHighest,
            child: SmoothImage(
              image: provider,
              fit: fit,
              width: double.infinity,
              height: double.infinity,
            ),
          );
        },
      ),
    );
  }
}
