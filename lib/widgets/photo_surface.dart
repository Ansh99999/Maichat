import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// How far the transform must be from rest before the picture counts as zoomed.
const double _kZoomedAt = 1.01;

/// How far a squeeze may go past rest before it springs back — a little give,
/// so pinching in reads as elastic rather than as hitting a wall.
const double _kSqueezeFloor = 0.6;

/// Released below this, a squeeze is read as "put it away" rather than as a
/// zoom that undershot.
const double _kSqueezeToClose = 0.82;

/// Logical pixels per second that count as a flick rather than a drag.
const double _kFlickVelocity = 620;

/// Where a double tap lands.
const double _kDoubleTapScale = 2.5;

/// A picture you can pinch, pan, double tap, and throw away.
///
/// ## Why this is not an `InteractiveViewer`
///
/// `InteractiveViewer` builds its own `GestureDetector`, so its scale recogniser
/// competes on equal terms with whatever else wants the pointer — inside a
/// `PageView`, that is the pager's horizontal drag. The drag accepts after
/// [kTouchSlop] (18 logical pixels) of sideways travel; the scale recogniser
/// waits for [kScaleSlop] (18) of *span* change or [kPanSlop] (36) of focal
/// travel. A real pinch is never symmetric — one finger anchors, or both slide
/// as they spread — so the sideways component crosses 18 first, the pager wins
/// the arena, and the pinch is discarded for the whole touch. Measured: a
/// drifting or thumb-anchored pinch left the scale at exactly 1.0, which is the
/// "I can't zoom in at all" this replaces.
///
/// So the gesture is one recogniser that **claims the arena the moment a second
/// finger lands**, before any drag has its 18 pixels. A single finger is left to
/// the pager unless the picture is zoomed (then a drag pans it) or the movement
/// is clearly vertical (then it is the flick that closes the picture) — the same
/// directional race a nested vertical scrollable would run.
///
/// Deliberately one recogniser rather than a scale plus a vertical drag: a pinch
/// that begins as a one-finger drag then adds a finger stays with the same
/// recogniser, so it turns into a pinch instead of being stranded behind a drag
/// that already owns the pointer.
class PhotoSurface extends StatefulWidget {
  const PhotoSurface({
    super.key,
    required this.child,
    this.onTap,
    this.onZoomChanged,
    this.onDismiss,
    this.dismissProgress,
    this.maxScale = 6,
  });

  /// The picture. Laid out to fill the surface; transformed, never rebuilt.
  final Widget child;

  final VoidCallback? onTap;

  /// Reports whether the picture is zoomed in, so a pager can get out of the way.
  final ValueChanged<bool>? onZoomChanged;

  /// Called when a flick, a long drag or a hard squeeze asks for the picture to
  /// be let go of. Null leaves the picture un-dismissable — a one-finger drag
  /// then belongs entirely to whatever is around it.
  final VoidCallback? onDismiss;

  /// Driven 0 (at rest) → 1 (released now, it goes away), so the screen can fade
  /// its backdrop and chrome without rebuilding the picture every frame.
  final ValueNotifier<double>? dismissProgress;

  final double maxScale;

  @override
  State<PhotoSurface> createState() => _PhotoSurfaceState();
}

class _PhotoSurfaceState extends State<PhotoSurface>
    // Several tickers over a lifetime, one at a time: every settle (spring-back,
    // double-tap zoom, throw-out) makes its own, so `Single` would assert the
    // second time a picture is double-tapped.
    with TickerProviderStateMixin {
  /// Live geometry. A notifier, not `setState`: the picture is one `Image` that
  /// must not be rebuilt sixty times a second — only the `Transform` above it.
  final ValueNotifier<PhotoGeometry> _geometry =
      ValueNotifier<PhotoGeometry>(const PhotoGeometry());

  AnimationController? _spring;

  /// The surface's own size, kept from layout: every clamp and every threshold
  /// is measured against it.
  Size _viewport = Size.zero;

  /// The focal point the last update was measured from, and the scale the
  /// current gesture started at.
  Offset _focal = Offset.zero;
  double _startScale = 1;

  Offset? _doubleTapAt;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _geometry.addListener(_report);
  }

  @override
  void dispose() {
    _geometry.removeListener(_report);
    _spring?.dispose();
    _geometry.dispose();
    super.dispose();
  }

  /// How far the picture must be dragged to be let go of. A share of the height
  /// rather than a fixed distance, capped so a tall screen does not demand a
  /// sweep of the whole thing.
  double get _dismissDistance =>
      math.min(_viewport.height * 0.18, 150).toDouble();

  bool get _canDismiss => widget.onDismiss != null;

  void _report() {
    final geometry = _geometry.value;
    final zoomed = geometry.scale > _kZoomedAt;
    if (zoomed != _zoomed) {
      _zoomed = zoomed;
      widget.onZoomChanged?.call(zoomed);
    }
    widget.dismissProgress?.value = _canDismiss ? _closeness(geometry) : 0;
  }

  /// 0 at rest, 1 when letting go now would put the picture away.
  double _closeness(PhotoGeometry geometry) {
    final distance = _dismissDistance;
    final byDrag = distance <= 0
        ? 0.0
        : (geometry.drag.dy.abs() / distance).clamp(0.0, 1.0);
    final bySqueeze =
        ((1 - geometry.scale) / (1 - _kSqueezeToClose)).clamp(0.0, 1.0);
    return math.max(byDrag, bySqueeze);
  }

  Offset get _centre => Offset(_viewport.width / 2, _viewport.height / 2);

  /// Keeps a zoomed picture covering the surface, so it cannot be dragged off
  /// into empty space and lost.
  Offset _clampPan(Offset offset, double scale) {
    final maxX = math.max(0.0, (scale - 1) * _viewport.width / 2);
    final maxY = math.max(0.0, (scale - 1) * _viewport.height / 2);
    return Offset(
      offset.dx.clamp(-maxX, maxX),
      offset.dy.clamp(-maxY, maxY),
    );
  }

  // --- the gesture ---------------------------------------------------------

  void _onStart(ScaleStartDetails details) {
    _stopSpring();
    _startScale = _geometry.value.scale;
    _focal = details.localFocalPoint;
  }

  void _onUpdate(ScaleUpdateDetails details) {
    final geometry = _geometry.value;
    final focal = details.localFocalPoint;

    // Split by fingers, not by scale: a mode that flips partway through a pinch
    // makes the picture jump at the moment the squeeze crosses rest.
    if (details.pointerCount >= 2) {
      // A pinch. Whatever is under the fingers stays under the fingers —
      // measured from the *previous* focal point, not the gesture's start, so a
      // pinch that walks across the picture tracks it instead of drifting.
      final scale =
          (_startScale * details.scale).clamp(_kSqueezeFloor, widget.maxScale);
      final step = scale / geometry.scale;
      final anchored =
          (focal - _centre) - (_focal - _centre - geometry.offset) * step;
      _geometry.value = PhotoGeometry(
        scale: scale,
        offset: _clampPan(anchored, scale),
        drag: geometry.drag,
      );
    } else if (geometry.scale > _kZoomedAt) {
      // One finger on a zoomed picture pans it.
      _geometry.value = PhotoGeometry(
        scale: geometry.scale,
        offset: _clampPan(geometry.offset + (focal - _focal), geometry.scale),
        drag: geometry.drag,
      );
    } else if (_canDismiss) {
      // One finger at rest: the picture follows the hand, ready to be thrown
      // away. Both axes, because a photo that only moves down feels pinned.
      _geometry.value = PhotoGeometry(
        scale: geometry.scale,
        drag: geometry.drag + (focal - _focal),
      );
    }
    _focal = focal;
  }

  void _onEnd(ScaleEndDetails details) {
    // A pinch ends and restarts every time a finger changes, so this fires
    // mid-gesture with fingers still down. Only the empty hand means the end.
    if (details.pointerCount > 0) return;

    final geometry = _geometry.value;
    final velocity = details.velocity.pixelsPerSecond.dy;
    final flicked = geometry.drag.dy != 0 &&
        velocity.abs() > _kFlickVelocity &&
        velocity.sign == geometry.drag.dy.sign;
    final thrown = geometry.drag.dy.abs() > _dismissDistance || flicked;
    if (_canDismiss && (thrown || geometry.scale < _kSqueezeToClose)) {
      _throwOut(geometry, flicked ? velocity : 0);
      return;
    }

    final settled = geometry.scale.clamp(1.0, widget.maxScale);
    final target = PhotoGeometry(
      scale: settled,
      offset: _clampPan(geometry.offset, settled),
    );
    if (target != geometry) _springTo(target);
  }

  /// Lets the picture keep going the way it was thrown while the route fades out
  /// behind it. Asks to be closed straight away rather than after the animation:
  /// the fade and the throw then run together, which is what makes it read as one
  /// movement instead of a pause and then a screen closing.
  void _throwOut(PhotoGeometry from, double velocity) {
    widget.dismissProgress?.value = 1;
    widget.onDismiss!();
    if (from.drag == Offset.zero) {
      // Squeezed shut rather than thrown: it shrinks away where it stands.
      _springTo(
        PhotoGeometry(scale: from.scale * 0.7, offset: from.offset),
        duration: const Duration(milliseconds: 180),
      );
      return;
    }
    final direction = velocity != 0 ? velocity.sign : from.drag.dy.sign;
    _springTo(
      PhotoGeometry(
        scale: from.scale,
        offset: from.offset,
        drag: Offset(from.drag.dx, direction * _viewport.height),
      ),
      duration: const Duration(milliseconds: 180),
    );
  }

  void _onTap() => widget.onTap?.call();

  /// A double tap zooms to [_kDoubleTapScale] on the spot touched, and back out
  /// again — the gesture every photo viewer has.
  void _onDoubleTap() {
    final geometry = _geometry.value;
    if (geometry.scale > _kZoomedAt) {
      _springTo(const PhotoGeometry());
      return;
    }
    final point = _doubleTapAt ?? _centre;
    _springTo(PhotoGeometry(
      scale: _kDoubleTapScale,
      offset: _clampPan(
        (point - _centre) * (1 - _kDoubleTapScale),
        _kDoubleTapScale,
      ),
    ));
  }

  // --- settling -----------------------------------------------------------

  void _stopSpring() {
    _spring?.stop();
    _spring?.dispose();
    _spring = null;
  }

  /// Eases the geometry to [target] — the spring back from a squeeze, from an
  /// abandoned drag, or the double-tap zoom.
  void _springTo(
    PhotoGeometry target, {
    Duration duration = const Duration(milliseconds: 240),
  }) {
    final from = _geometry.value;
    _stopSpring();
    final controller = AnimationController(vsync: this, duration: duration);
    final animation =
        CurvedAnimation(parent: controller, curve: Curves.easeOutCubic);
    animation.addListener(() {
      _geometry.value = PhotoGeometry.lerp(from, target, animation.value);
    });
    _spring = controller;
    controller.forward();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          _viewport = constraints.biggest;
          return RawGestureDetector(
            // The letterbox around a contained picture is part of the surface:
            // a pinch that starts on the black bars is still a pinch.
            behavior: HitTestBehavior.opaque,
            gestures: <Type, GestureRecognizerFactory>{
              PhotoGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<PhotoGestureRecognizer>(
                () => PhotoGestureRecognizer(
                  debugOwner: this,
                  claimSingleFinger: () => _geometry.value.scale > _kZoomedAt,
                  claimVerticalDrag: () =>
                      _canDismiss && _geometry.value.scale <= _kZoomedAt,
                ),
                (instance) => instance
                  ..onStart = _onStart
                  ..onUpdate = _onUpdate
                  ..onEnd = _onEnd,
              ),
              TapGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                () => TapGestureRecognizer(debugOwner: this),
                (instance) => instance.onTap = _onTap,
              ),
              DoubleTapGestureRecognizer: GestureRecognizerFactoryWithHandlers<
                  DoubleTapGestureRecognizer>(
                () => DoubleTapGestureRecognizer(debugOwner: this),
                (instance) => instance
                  ..onDoubleTapDown =
                      ((details) => _doubleTapAt = details.localPosition)
                  ..onDoubleTap = _onDoubleTap,
              ),
            },
            child: ValueListenableBuilder<PhotoGeometry>(
              valueListenable: _geometry,
              // The picture is passed as `child`, so a frame of a gesture costs
              // one transform and no rebuild of the image at all.
              child: widget.child,
              builder: (context, geometry, child) => Transform(
                transform: geometry.matrixFor(_viewport),
                alignment: Alignment.center,
                child: child,
              ),
            ),
          );
        },
      );
}

/// Where the picture is: how far zoomed, panned within itself, and how far it has
/// been dragged towards being let go of.
@immutable
class PhotoGeometry {
  const PhotoGeometry({
    this.scale = 1,
    this.offset = Offset.zero,
    this.drag = Offset.zero,
  });

  /// 1 is resting, fitted to the surface.
  final double scale;

  /// Pan within a zoomed picture, in surface pixels.
  final Offset offset;

  /// How far it has been dragged towards being thrown away.
  final Offset drag;

  /// A dragged picture shrinks as it goes, which is what makes it read as
  /// leaving rather than as sliding.
  double shrinkIn(Size viewport) {
    if (drag == Offset.zero || viewport.height <= 0) return 1;
    final gone = (drag.distance / viewport.height).clamp(0.0, 1.0);
    return 1 - gone * 0.5;
  }

  Matrix4 matrixFor(Size viewport) {
    final drawn = scale * shrinkIn(viewport);
    return Matrix4.identity()
      ..translateByDouble(offset.dx + drag.dx, offset.dy + drag.dy, 0, 1)
      ..scaleByDouble(drawn, drawn, 1, 1);
  }

  static PhotoGeometry lerp(PhotoGeometry a, PhotoGeometry b, double t) =>
      PhotoGeometry(
        scale: a.scale + (b.scale - a.scale) * t,
        offset: Offset.lerp(a.offset, b.offset, t)!,
        drag: Offset.lerp(a.drag, b.drag, t)!,
      );

  @override
  bool operator ==(Object other) =>
      other is PhotoGeometry &&
      other.scale == scale &&
      other.offset == offset &&
      other.drag == drag;

  @override
  int get hashCode => Object.hash(scale, offset, drag);
}

/// The one recogniser a [PhotoSurface] runs on.
///
/// Claims the arena outright as soon as a second finger is down — before any
/// drag has travelled its slop — because two fingers on a photo are never
/// anything but a pinch. A lone finger is claimed only when the picture is
/// zoomed (a drag pans it) or when the movement is plainly vertical (the flick
/// that closes it); anything else is left to whatever surrounds the picture, so
/// a sideways swipe still turns the page.
class PhotoGestureRecognizer extends ScaleGestureRecognizer {
  PhotoGestureRecognizer({
    required this.claimSingleFinger,
    required this.claimVerticalDrag,
    super.debugOwner,
  });

  final bool Function() claimSingleFinger;
  final bool Function() claimVerticalDrag;

  /// Where the first finger of this sequence landed, in global coordinates.
  Offset? _origin;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (pointerCount == 0) _origin = event.position;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    super.handleEvent(event);
    if (pointerCount >= 2) {
      resolve(GestureDisposition.accepted);
      return;
    }
    if (event is! PointerMoveEvent) return;
    if (claimSingleFinger()) {
      resolve(GestureDisposition.accepted);
      return;
    }
    final origin = _origin;
    if (origin == null || !claimVerticalDrag()) return;
    // The same race a nested vertical scrollable runs: ours if it is going up or
    // down, theirs if it is going sideways.
    final moved = event.position - origin;
    if (moved.dy.abs() > kTouchSlop && moved.dy.abs() > moved.dx.abs()) {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  String get debugDescription => 'photo';
}

/// A route for a picture that can be thrown away.
///
/// See-through, so the gallery underneath shows while the photo is dragged out of
/// the way and the backdrop fades — that is what makes a flick read as putting
/// the picture back where it came from rather than as a screen closing.
PageRoute<T> photoRoute<T>(WidgetBuilder builder) => PageRouteBuilder<T>(
      opaque: false,
      barrierColor: null,
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, _, _) => builder(context),
      transitionsBuilder: (context, animation, _, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      ),
    );

/// Fades [child] out as the picture is dragged towards being let go of.
///
/// Listens rather than rebuilding its parent: a drag would otherwise re-run the
/// whole viewer — page view, decoded picture, action strip — on every frame.
class PhotoFade extends StatelessWidget {
  const PhotoFade({
    super.key,
    required this.leaving,
    required this.child,
    this.floor = 0,
  });

  /// A [PhotoSurface.dismissProgress].
  final ValueNotifier<double> leaving;

  /// The least it may fade to.
  final double floor;

  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
        valueListenable: leaving,
        child: child,
        builder: (context, progress, child) => IgnorePointer(
          // Half-way gone, the controls are no longer aimed at: taps then belong
          // to the picture underneath the finger.
          ignoring: progress > 0.5,
          child: Opacity(
            opacity: (1 - progress).clamp(floor, 1.0),
            child: child,
          ),
        ),
      );
}

/// The black a photo is judged against, which thins out as the picture is dragged
/// away so whatever it was opened from shows through behind it.
class PhotoBackdrop extends StatelessWidget {
  const PhotoBackdrop({super.key, required this.leaving});

  final ValueNotifier<double> leaving;

  @override
  Widget build(BuildContext context) => PhotoFade(
        leaving: leaving,
        // Never all the way to nothing: a photo half-way out still wants
        // something dark behind it, or the two screens read as one mess.
        floor: 0.25,
        child: const ColoredBox(color: Colors.black),
      );
}
