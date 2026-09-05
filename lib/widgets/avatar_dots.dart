import 'package:flutter/material.dart';

/// The row of dots under a run of pictures: which one of them you are looking at.
///
/// Deliberately tiny and quiet — it is a position indicator, not a control. It
/// draws nothing at all for a single picture, so every caller can hand it a pool
/// without first asking whether there is anything to indicate.
///
/// [onArtwork] switches the palette to white-on-a-shadow, for dots that sit over
/// a picture rather than over a surface; the theme's own colours are unreadable
/// against arbitrary art.
class AvatarDots extends StatelessWidget {
  const AvatarDots({
    super.key,
    required this.count,
    required this.index,
    this.onArtwork = false,
  });

  final int count;
  final int index;
  final bool onArtwork;

  @override
  Widget build(BuildContext context) {
    if (count < 2) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final active = onArtwork ? Colors.white : scheme.onSurface;
    final idle = onArtwork
        ? Colors.white.withValues(alpha: 0.45)
        : scheme.onSurfaceVariant.withValues(alpha: 0.4);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            // The current one is a longer pill rather than merely a brighter
            // dot, so the position reads at a glance and in one colour.
            width: i == index ? 16 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: i == index ? active : idle,
              borderRadius: BorderRadius.circular(3),
              boxShadow: onArtwork
                  ? const [
                      BoxShadow(
                        color: Color(0x66000000),
                        blurRadius: 3,
                        offset: Offset(0, 1),
                      ),
                    ]
                  : null,
            ),
          ),
      ],
    );
  }
}
