import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// How far the transform must be from rest before the picture counts as zoomed.
const double _kZoomedAt = 1.01;

/// How far a touch must travel before it is committed to being a pinch, a page
/// turn or a throw. Deliberately small — a fifth of [kTouchSlop] — because this
/// surface owns every touch on it and so has nobody to lose a race to. The old
/// 18 pixels was the pager's threshold, and waiting for it is what made zooming
/// feel like it "wasn't there".
const double _kDecideAt = 4;

/// Logical pixels per second that count as a flick rather than a drag.
const double _kFlickVelocity = 620;

/// Horizontal pixels per second that carry the picture on to the next page even
/// when the finger stopped short of half way. Used by [PhotoPager].
const double _kPageVelocity = 380;

/// Where a double tap lands.
const double _kDoubleTapScale = 2.5;

/// The tag that ties a picture's tile in a grid to the same picture full screen,
/// so opening one grows it out of where it was tapped instead of fading a new
/// screen in over the top.
String photoHeroTag(String id) => 'photo-$id';

/// What a touch on a [PhotoSurface] turned out to be.
///
/// Decided once per touch and then kept, so a diagonal drag does not page and
/// dismiss at the same time, and a pinch that wanders sideways does not turn into
/// a page turn half way through.
enum _Doing { undecided, pinch, pan, page, dismiss }

/// A picture you can pinch, pan, double tap, page and throw away.
///
/// ## Why this owns every touch on it
///
/// The first cut of this put the surface inside a scrollable `PageView` and tried
/// to share: two fingers went to the pinch, a sideways drag to the pager. That
/// cannot be made to work, and the reason is worth keeping. A `PageView`'s
/// horizontal drag accepts after [kTouchSlop] — 18 logical pixels — and a hand
/// reaching in to pinch *slides before the second finger lands*. Thirty pixels of
/// drift is nothing on a real screen. Once the pager has won the arena the surface
/// is dropped from it, and it never sees the second finger at all: the pinch
/// simply does not exist. Measured, with a bare `ScaleGestureRecognizer` inside a
/// `PageView`: after 30px of drift the scale recogniser was **never even started**,
/// and the scale stayed at exactly 1.0. That is the "not zoomable" this replaces.
///
/// So the pager is switched off ([NeverScrollableScrollPhysics], no recognisers at
/// all) and this surface drives it through [onPageDrag] / [onPageSettle]. Every
/// touch belongs here, nothing competes, and a gesture can therefore be read from
/// its first few pixels ([_kDecideAt]) rather than after somebody else's slop.
class PhotoSurface extends StatefulWidget {
  const PhotoSurface({
    super.key,
    required this.child,
    this.onTap,
    this.onZoomChanged,
    this.onDismiss,
    this.dismissProgress,
    this.onPageDrag,
    this.onPageSettle,
    this.maxScale = 6,
  });

  /// The picture. Laid out to fill the surface; transformed, never rebuilt.
  final Widget child;

  final VoidCallback? onTap;

  /// Reports whether the picture is zoomed in. A zoomed picture cannot be paged
  /// off or thrown away — a drag pans it instead.
  final ValueChanged<bool>? onZoomChanged;

  /// Called when a flick or a long drag asks for the picture to be let go of.
  final VoidCallback? onDismiss;

  /// Driven 0 (at rest) → 1 (released now, it goes away), so the screen can fade
  /// its backdrop and chrome without rebuilding the picture every frame.
  final ValueNotifier<double>? dismissProgress;

  /// A sideways drag, in logical pixels of finger movement. Null leaves the
  /// picture unpageable, and a sideways drag then does nothing.
  final ValueChanged<double>? onPageDrag;

  /// The hand has left a sideways drag, at this horizontal velocity.
  final ValueChanged<double>? onPageSettle;

  final double maxScale;

  @override
  State<PhotoSurface> createState() => _PhotoSurfaceState();
}

class _PhotoSurfaceState extends State<PhotoSurface>
    // Several tickers over a lifetime, one at a time: every settle (spring-back,
    // double-tap zoom) makes its own, so `Single` would assert the second time a
    // picture is double-tapped.
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

  /// Where this touch began and what it has turned out to be.
  Offset _from = Offset.zero;
  _Doing _doing = _Doing.undecided;

  Offset? _doubleTapAt;
  bool _zoomed = false;

  /// Fingers on the surface, counted from raw pointer events.
  int _fingers = 0;

  /// Whether the current touch has already been settled.
  bool _settled = true;

  /// The velocity the recogniser last reported, kept because it does not report
  /// one on the segment that matters: a pinch ends and restarts every time a
  /// finger changes, and the last lift often *reconfigures* rather than ending, so
  /// `onEnd` with an empty hand cannot be relied on.
  Velocity _lastVelocity = Velocity.zero;

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
  bool get _canPage => widget.onPageDrag != null;

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
  ///
  /// Only the drag counts. A squeeze used to feed this too, so pinching in dimmed
  /// the screen as if the picture were leaving. Zoom is zoom; leaving is a drag.
  double _closeness(PhotoGeometry geometry) {
    final distance = _dismissDistance;
    if (distance <= 0) return 0;
    return (geometry.drag.dy.abs() / distance).clamp(0.0, 1.0);
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
    _from = details.localFocalPoint;
    // A second finger already down is a pinch before it has moved at all.
    _doing = details.pointerCount >= 2
        ? _Doing.pinch
        : _geometry.value.scale > _kZoomedAt
            ? _Doing.pan
            : _Doing.undecided;
  }

  void _onUpdate(ScaleUpdateDetails details) {
    final geometry = _geometry.value;
    final focal = details.localFocalPoint;

    // A second finger turns anything into a pinch, at once — this is the whole
    // point of owning the touch, and it is why a hand that slides on its way in
    // still zooms.
    if (details.pointerCount >= 2) _doing = _Doing.pinch;

    if (_doing == _Doing.undecided) {
      final moved = focal - _from;
      if (moved.distance < _kDecideAt) {
        _focal = focal;
        return;
      }
      // Committed by direction, once, on the first few pixels.
      _doing = moved.dx.abs() > moved.dy.abs()
          ? (_canPage ? _Doing.page : _Doing.undecided)
          : (_canDismiss ? _Doing.dismiss : _Doing.undecided);
      if (_doing == _Doing.undecided) {
        _focal = focal;
        return;
      }
    }

    switch (_doing) {
      case _Doing.pinch:
        // Never below 1: fitted is as far out as a photo goes, so squeezing past
        // it simply stops rather than shrinking the picture into a stamp floating
        // over the gallery. Whatever is under the fingers stays under the fingers
        // — measured from the *previous* focal point, not the gesture's start, so
        // a pinch that walks across the picture tracks it instead of drifting.
        final scale = (_startScale * details.scale).clamp(1.0, widget.maxScale);
        final step = scale / geometry.scale;
        final anchored =
            (focal - _centre) - (_focal - _centre - geometry.offset) * step;
        _geometry.value = PhotoGeometry(
          scale: scale,
          offset: _clampPan(anchored, scale),
        );
      case _Doing.pan:
        _geometry.value = PhotoGeometry(
          scale: geometry.scale,
          offset: _clampPan(geometry.offset + (focal - _focal), geometry.scale),
        );
      case _Doing.page:
        // Straight to the pager, one pixel of picture per pixel of finger.
        widget.onPageDrag!(focal.dx - _focal.dx);
      case _Doing.dismiss:
        // The picture follows the hand, ready to be thrown away. Both axes,
        // because a photo that only moves down feels pinned.
        _geometry.value = PhotoGeometry(
          scale: geometry.scale,
          drag: geometry.drag + (focal - _focal),
        );
      case _Doing.undecided:
        break;
    }
    _focal = focal;
  }

  /// Records the velocity of each segment and settles once the hand is empty.
  ///
  /// The empty-hand case is belt to [_settle]'s braces: it is reached from the raw
  /// finger count too, whichever arrives first.
  void _onEnd(ScaleEndDetails details) {
    _lastVelocity = details.velocity;
    if (details.pointerCount == 0) _settle();
  }

  /// Puts the picture where it belongs now the hand has gone: away if it was
  /// thrown, on to the next page if it was swiped, back to fitted otherwise.
  ///
  /// Idempotent, because both the recogniser's end and the raw last-finger-up can
  /// reach it and either may be first.
  void _settle() {
    if (_settled) return;
    _settled = true;

    final geometry = _geometry.value;
    final velocity = _lastVelocity.pixelsPerSecond;

    if (_doing == _Doing.page) {
      widget.onPageSettle?.call(velocity.dx);
      _doing = _Doing.undecided;
      return;
    }

    if (_doing == _Doing.dismiss) {
      final flicked = geometry.drag.dy != 0 &&
          velocity.dy.abs() > _kFlickVelocity &&
          velocity.dy.sign == geometry.drag.dy.sign;
      if (geometry.drag.dy.abs() > _dismissDistance || flicked) {
        // Nothing to animate here on purpose. The picture is left exactly where
        // the hand put it and closing the route hands it to the Hero flight,
        // which carries it from there back into the tile it came from. An
        // animation of our own would be a second thing moving one picture.
        widget.onDismiss!();
        return;
      }
    }

    _doing = _Doing.undecided;
    final settled = geometry.scale.clamp(1.0, widget.maxScale);
    final target = PhotoGeometry(
      scale: settled,
      offset: _clampPan(geometry.offset, settled),
    );
    if (target != geometry) _springTo(target);
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

  /// Eases the geometry to [target] — the spring back from an abandoned drag, or
  /// the double-tap zoom.
  void _springTo(
    PhotoGeometry target, {
    Duration duration = const Duration(milliseconds: 200),
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

  void _pressFinger(PointerDownEvent event) {
    if (_fingers == 0) {
      // A fresh touch: the last one's velocity must not decide this one's fate.
      _lastVelocity = Velocity.zero;
      _settled = false;
    }
    _fingers += 1;
  }

  void _liftFinger(PointerEvent event) {
    _fingers = math.max(0, _fingers - 1);
    if (_fingers == 0) _settle();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          _viewport = constraints.biggest;
          // Fingers are counted from raw pointer events, which survive the scale
          // recogniser ending and restarting itself as fingers change. Its own
          // `onEnd` cannot be trusted to report the empty hand: when the last
          // finger lifts without moving first it *reconfigures* instead of ending,
          // so `onEnd` arrives saying one finger is still down and never comes
          // again. That is how a squeezed picture was once left stuck small.
          return Listener(
            onPointerDown: _pressFinger,
            onPointerUp: _liftFinger,
            onPointerCancel: _liftFinger,
            child: RawGestureDetector(
              // The letterbox around a contained picture is part of the surface:
              // a pinch that starts on the black bars is still a pinch.
              behavior: HitTestBehavior.opaque,
              gestures: <Type, GestureRecognizerFactory>{
                PhotoGestureRecognizer: GestureRecognizerFactoryWithHandlers<
                    PhotoGestureRecognizer>(
                  () => PhotoGestureRecognizer(debugOwner: this),
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
                DoubleTapGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
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
/// Claims the arena as soon as a second finger lands, or as soon as one finger has
/// travelled [_kDecideAt]. Both thresholds are this low because nothing else on
/// this surface wants the touch: the pager it sits in is switched off and driven by
/// hand, so the only other recognisers are the tap and the double tap, and a tap
/// does not move four pixels. That is what makes a pinch survive a hand that slides
/// on its way in — the pager's eighteen-pixel drag used to win that race and the
/// second finger was then never delivered here at all.
class PhotoGestureRecognizer extends ScaleGestureRecognizer {
  PhotoGestureRecognizer({super.debugOwner});

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
    // Two fingers on a photo are never anything but a pinch, and waiting for them
    // to move first is what a shared arena forced.
    if (pointerCount >= 2) {
      resolve(GestureDisposition.accepted);
      return;
    }
    final origin = _origin;
    if (event is! PointerMoveEvent || origin == null) return;
    if ((event.position - origin).distance > _kDecideAt) {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  String get debugDescription => 'photo';
}

/// Turns the pages of a run of pictures, driven entirely by hand.
///
/// The `PageView` inside has **no gesture recognisers of its own**
/// ([NeverScrollableScrollPhysics]); each page's [PhotoSurface] reports sideways
/// drags here through [drag] and [settle]. That is the whole reason pinching works
/// — see [PhotoSurface]'s note — and it costs only what a pager does anyway: a
/// controller offset per frame.
class PhotoPager {
  PhotoPager({required this.controller, required this.pageCount});

  final PageController controller;

  /// How many pages there are, so a drag cannot be carried off either end.
  int pageCount;

  /// The page the last settle aimed at, so a second flick during the animation
  /// counts from where it is going rather than where it started.
  int? _aiming;

  double get _width => controller.position.viewportDimension;

  /// Moves the run by [delta] logical pixels of finger.
  void drag(double delta) {
    final position = controller.position;
    if (!position.hasPixels || _width <= 0) return;
    // One pixel of picture per pixel of finger, and no rubber band past the ends:
    // a photo run that bounces reads as broken rather than as elastic.
    final limit = math.max(0.0, (pageCount - 1) * _width);
    position.jumpTo((position.pixels - delta).clamp(0.0, limit));
  }

  /// The hand has gone at [velocity] logical pixels per second sideways.
  void settle(double velocity) {
    final position = controller.position;
    if (!position.hasPixels || _width <= 0) return;
    final at = position.pixels / _width;
    final from = _aiming ?? at.round();
    // A flick carries one page, whatever distance it covered; otherwise the
    // nearest page wins, which is the "past half way" rule without the arithmetic.
    final target = velocity.abs() > _kPageVelocity
        ? (velocity < 0 ? from + 1 : from - 1)
        : at.round();
    final landing = target.clamp(0, math.max(0, pageCount - 1)).toInt();
    _aiming = landing;
    controller
        .animateToPage(
          landing,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() {
      if (_aiming == landing) _aiming = null;
    });
  }
}

/// A route for a picture that can be thrown away.
///
/// See-through, so the gallery underneath shows while the photo is dragged out of
/// the way and the backdrop fades — that is what makes a flick read as putting
/// the picture back where it came from rather than as a screen closing.
///
/// The picture itself arrives by [Hero] flight, growing out of the tile that was
/// tapped, so this route only has to bring the black and the chrome with it. That
/// is why the fade is **fast** and starts from a third rather than from nothing: a
/// full cross-fade over the length of a flight is the "takes a full second to
/// open" this replaced.
PageRoute<T> photoRoute<T>(WidgetBuilder builder) => PageRouteBuilder<T>(
      opaque: false,
      barrierColor: null,
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (context, _, _) => builder(context),
      transitionsBuilder: (context, animation, _, child) => FadeTransition(
        opacity: Tween<double>(begin: 0.35, end: 1).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        ),
        child: child,
      ),
    );

/// The picture, ready to fly between a grid tile and the full-screen viewer.
///
/// [tag] is null for a picture that has nowhere to fly from — an avatar that was
/// never a gallery record, say — and it then simply appears.
class PhotoHero extends StatelessWidget {
  const PhotoHero({super.key, required this.tag, required this.child});

  final String? tag;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tag = this.tag;
    if (tag == null) return child;
    return Hero(
      tag: tag,
      // A tile is a cropped square and the viewer shows the whole picture, so the
      // two ends draw the image differently. Flying the *destination's* widget
      // the whole way keeps one bitmap on screen: without this the shuttle
      // cross-fades two Images and the picture visibly double-exposes.
      flightShuttleBuilder: (_, _, _, _, toContext) =>
          (toContext.widget as Hero).child,
      child: child,
    );
  }
}

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
