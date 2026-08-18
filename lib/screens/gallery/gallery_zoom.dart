import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../models/gallery_image.dart';

/// Makes a gallery pinchable: spreading two fingers walks down the ladder to
/// bigger pictures, squeezing them walks up to more per row.
///
/// The gesture is added *around* the scroll view rather than inside it, and only
/// ever acts on two fingers. A [ScaleGestureRecognizer] joins the same gesture
/// arena as the list's own vertical drag, and the drag claims the pointer first
/// (its slop is [kTouchSlop], 18 logical pixels, against the scale recogniser's
/// [kPanSlop] of 36), so ordinary one-finger scrolling is untouched — that is why
/// this is a plain recogniser and not something that grabs the pointer eagerly.
///
/// Deliberately **not** `ImmediateMultiDragGestureRecognizer`: it satisfies widget
/// tests and does nothing at all on a real touchscreen, which has cost this app
/// two releases already.
class GalleryZoomDetector extends StatefulWidget {
  const GalleryZoomDetector({
    super.key,
    required this.zoom,
    required this.onChanged,
    required this.child,
  });

  /// The rung currently shown.
  final GalleryZoom zoom;

  /// Called with the new rung when a pinch crosses a step.
  final ValueChanged<GalleryZoom> onChanged;

  final Widget child;

  @override
  State<GalleryZoomDetector> createState() => _GalleryZoomDetectorState();
}

class _GalleryZoomDetectorState extends State<GalleryZoomDetector> {
  /// The scale the current gesture is measured against. Reset after every step so
  /// one long pinch can walk several rungs, the way a photo app behaves.
  double _baseline = 1;

  /// How far apart the fingers must travel, proportionally, to move a rung.
  /// Loose enough that a small wobble does not jump the grid, tight enough that
  /// the ladder feels reachable in one motion.
  static const double _spreadStep = 1.35;
  static const double _squeezeStep = 0.74;

  void _onUpdate(ScaleUpdateDetails details) {
    // One finger is a scroll, not a pinch. The recogniser also reports single
    // pointers (it doubles as a pan), so this guard is what keeps a horizontal
    // swipe from silently resizing the gallery.
    if (details.pointerCount < 2) return;

    final relative = details.scale / _baseline;
    if (relative >= _spreadStep) {
      // Fingers apart: fewer, larger pictures.
      _baseline *= _spreadStep;
      _step(widget.zoom.inward);
    } else if (relative <= _squeezeStep) {
      // Fingers together: more pictures, coarser date buckets.
      _baseline *= _squeezeStep;
      _step(widget.zoom.out);
    }
  }

  void _step(GalleryZoom next) {
    if (next == widget.zoom) return; // Already at that end of the ladder.
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) => RawGestureDetector(
        gestures: <Type, GestureRecognizerFactory>{
          ScaleGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<ScaleGestureRecognizer>(
            () => ScaleGestureRecognizer(
              debugOwner: this,
              // A trackpad scroll is a scroll on the desktop build; only a real
              // pinch should change the grid.
              trackpadScrollCausesScale: false,
            ),
            (instance) => instance
              // A block body, not `(_) => _baseline = 1`: an expression-bodied
              // closure would swallow the cascade that follows it.
              ..onStart = (_) {
                _baseline = 1;
              }
              ..onUpdate = _onUpdate,
          ),
        },
        child: widget.child,
      );
}
