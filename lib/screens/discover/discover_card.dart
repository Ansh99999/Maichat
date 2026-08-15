import 'package:flutter/material.dart';

import '../../models/discover.dart';
import '../../widgets/avatar_image.dart';

/// A compact count: 1200 reads as "1.2k", 34000 as "34k".
String compactCount(int value) {
  if (value < 1000) return '$value';
  if (value < 10000) {
    final tenths = (value / 100).round() / 10;
    return '${tenths.toStringAsFixed(tenths == tenths.roundToDouble() ? 0 : 1)}k';
  }
  if (value < 1000000) return '${(value / 1000).round()}k';
  final millions = (value / 100000).round() / 10;
  return '${millions.toStringAsFixed(millions == millions.roundToDouble() ? 0 : 1)}M';
}

/// The picture on a Discover card. Remote, so it has to survive being slow,
/// missing, or refused — every failure lands on the same quiet placeholder
/// rather than a broken-image glyph.
class DiscoverImage extends StatelessWidget {
  const DiscoverImage({
    super.key,
    required this.url,
    required this.fallbackIcon,
    this.size,
    this.fit = BoxFit.cover,
  });

  final String? url;
  final IconData fallbackIcon;

  /// Logical size the image is drawn at, so the bitmap is decoded no larger.
  final double? size;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Icon(fallbackIcon, color: scheme.onSurfaceVariant, size: 28),
      ),
    );
    final link = url?.trim() ?? '';
    if (link.isEmpty) return placeholder;
    final provider = avatarImage(
      link,
      displaySize: size,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
    if (provider == null) return placeholder;
    return Image(
      image: provider,
      fit: fit,
      gaplessPlayback: true,
      errorBuilder: (context, error, stack) => placeholder,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded || frame != null) return child;
        return placeholder;
      },
    );
  }
}

/// One character in the feed: the art, the name, who made it, and the two
/// numbers worth knowing before you tap.
class DiscoverCard extends StatelessWidget {
  const DiscoverCard({super.key, required this.item, required this.onTap});

  final DiscoverItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final stats = _stats(item);

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DiscoverImage(
                    url: item.thumbnailUrl,
                    fallbackIcon: Icons.person_outline,
                    size: 220,
                  ),
                  if (item.nsfw)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: _Badge(label: '18+', color: scheme.errorContainer,
                          textColor: scheme.onErrorContainer),
                    ),
                  if (item.hasLore)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: _Badge(
                        label: 'Lore',
                        color: scheme.secondaryContainer,
                        textColor: scheme.onSecondaryContainer,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  if (item.creator.trim().isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      'by ${item.creator.trim()}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                  if (stats.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      stats,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A lorebook or preset in the feed. No art worth showing, so it reads as a
/// row rather than a tile.
class DiscoverRow extends StatelessWidget {
  const DiscoverRow({super.key, required this.item, required this.onTap});

  final DiscoverItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final blurb = item.tagline.trim().isNotEmpty
        ? item.tagline.trim()
        : item.description.trim();
    final meta = <String>[
      if (item.creator.trim().isNotEmpty) 'by ${item.creator.trim()}',
      if (item.entryCount != null) '${item.entryCount} entries',
      if (item.downloads != null) '${compactCount(item.downloads!)} downloads',
    ].join(' · ');

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  item.kind == DiscoverKind.preset
                      ? Icons.tune_outlined
                      : Icons.menu_book_outlined,
                  color: scheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                    if (blurb.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        blurb,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
              if (item.nsfw) ...[
                const SizedBox(width: 8),
                _Badge(
                  label: '18+',
                  color: scheme.errorContainer,
                  textColor: scheme.onErrorContainer,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The one line of numbers under a card's name.
String _stats(DiscoverItem item) {
  final parts = <String>[
    if (item.downloads != null) '↓ ${compactCount(item.downloads!)}',
    if (item.favourites != null && item.favourites! > 0)
      '♥ ${compactCount(item.favourites!)}',
    if (item.tokens != null && item.tokens! > 0)
      '${compactCount(item.tokens!)} tok',
  ];
  return parts.take(2).join('   ');
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.label,
    required this.color,
    required this.textColor,
  });

  final String label;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: textColor,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
      );
}
