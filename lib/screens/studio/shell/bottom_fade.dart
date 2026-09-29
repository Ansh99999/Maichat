import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// What sits behind the Studio's floating capsule and composer: a band that
/// frosts the page under it and fades it out, so text scrolling down reads as
/// disappearing into the composer rather than being cut off by a slab.
///
/// Two layers, both painted once per frame and no more. A blur over the lower
/// part of the band only — the part the capsule and composer cover — and over
/// the whole band a gradient from clear to the page colour. The gradient starts
/// [fade] above the blur, so the blur's top edge is already half hidden by the
/// time it begins and there is no seam to see.
///
/// The blur is the one per-frame cost here, and it is kept small on purpose:
/// it covers the bottom band alone, never the page, and it sits on its own
/// layer so the composer's caret and the capsule's springs repaint above it
/// without re-running it.
class StudioBottomFade extends StatelessWidget {
  const StudioBottomFade({
    super.key,
    this.fade = 36,
    this.blur = 6,
  });

  /// How far above the covered area the fade begins.
  final double fade;

  /// The frost's strength.
  final double blur;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    return IgnorePointer(
      child: RepaintBoundary(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final height = constraints.maxHeight;
            final start = height <= 0 ? 0.0 : (fade / height).clamp(0.0, 0.9);
            return Stack(
              fit: StackFit.expand,
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: fade * 0.6,
                  bottom: 0,
                  child: ClipRect(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        surface.withValues(alpha: 0),
                        surface.withValues(alpha: 0.55),
                        surface.withValues(alpha: 0.82),
                      ],
                      stops: [0, start, 1],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
