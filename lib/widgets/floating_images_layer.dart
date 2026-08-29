import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../models/floating_image.dart';
import '../services/jank_logger.dart';
import '../state/app_state.dart';
import 'avatar_image.dart';

/// The pictures pinned over a chat.
///
/// One finger drags, two resize and turn. All three come from a single
/// [ScaleGestureRecognizer], which is what makes it feel like handling a
/// photograph rather than operating three modes.
///
/// **Everything here is shaped by the gesture loop**, because the first two
/// attempts were unusable on a real phone. What a moving float must not do:
///
/// * **Write to [AppState].** Both the raise-to-front and the position used to,
///   and `_editConversation` notifies every listener and re-encodes the whole
///   conversation store. Now nothing is written until the fingers stop.
/// * **Trigger layout.** Position is a [Transform], not `Positioned.left/top`:
///   changing a Positioned relays out the whole [Stack] every frame, while a
///   transform only changes a matrix.
/// * **Rebuild its subtree.** The picture, frame and ✕ are built once and passed
///   to [AnimatedBuilder] as `child`, so a pointer-move rebuilds one Transform and
///   nothing beneath it.
/// * **Rebuild its recogniser.** The gesture detector sits *outside* the animated
///   part, so it is never reconfigured mid-gesture.
/// * **Re-decode its bitmap.** The decode size is held across a whole touch and
///   only stepped once the fingers have left and the picture has grown well past
///   it — the framed and bare pictures deliberately share one provider, so the
///   swap on touch-down can never wait on a decode.
/// * **Repaint the conversation.** Each float is a [RepaintBoundary], so moving
///   one does not redraw the thread — which also keeps the chat's frosted menu
///   button from re-blurring its backdrop on every frame.
class FloatingImagesLayer extends StatefulWidget {
  const FloatingImagesLayer({super.key, required this.conversationId});

  final String conversationId;

  @override
  State<FloatingImagesLayer> createState() => _FloatingImagesLayerState();
}

class _FloatingImagesLayerState extends State<FloatingImagesLayer> {
  /// The float last touched, drawn in front of the others until the stored order
  /// catches up when its gesture ends.
  String? _front;

  void _raise(String key) {
    if (_front == key) return;
    setState(() => _front = key);
  }

  @override
  Widget build(BuildContext context) {
    // Selected on the *keys*, not the list: `context.select` compares with `==`,
    // and a freshly built List never equals the last one — so returning the list
    // itself rebuilt this layer on every single AppState notification, sixty times
    // a second through a streaming reply.
    //
    // Joined on a separator no key can contain (a key ends in a picture ref, and
    // a filename may well have a space in it), written as an escape rather than
    // the raw byte — a NUL in the source makes git treat this whole file as
    // binary, which means no diff and no review of it.
    final keys = context.select<AppState, String>(
      (state) => state
          .floatingImagesFor(state.conversationById(widget.conversationId))
          .map((f) => f.float.key)
          .join('\u0000'),
    );
    if (keys.isEmpty) return const SizedBox.shrink();

    final floats = context
        .read<AppState>()
        .floatingImagesFor(
          context.read<AppState>().conversationById(widget.conversationId),
        );
    if (floats.isEmpty) return const SizedBox.shrink();

    // Stored order is z-order; the float under the finger is pulled to the end so
    // it is on top the instant it is touched, without writing anything.
    final ordered = _front == null
        ? floats
        : [
            ...floats.where((f) => f.float.key != _front),
            ...floats.where((f) => f.float.key == _front),
          ];

    return _RaiseScope(
      raise: _raise,
      // No boundary wraps the whole layer. A screen-sized RepaintBoundary here
      // (what shipped in 1.14.1–1.14.7) had to re-rasterise a full-screen texture
      // on the GPU every frame a float moved — which the performance overlay
      // showed as the raster-thread spike behind *all* the stutter. Instead each
      // float's own picture is a small [RepaintBoundary] (in `_FloatingPicture`),
      // so a move re-records the chat's cheap display list on the UI thread (which
      // had headroom) and the GPU only re-composites a small retained texture.
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The area a float's fractional position is measured against. Taken
          // from the layout rather than the window, so the sums hold whether the
          // keyboard is up, a bar is showing, or the phone has been turned.
          final area = Size(constraints.maxWidth, constraints.maxHeight);
          return Stack(
            clipBehavior: Clip.none,
            children: [
              for (final floated in ordered)
                // Each float fills the layer so it can be hit where the picture
                // is actually drawn: a full-size box passes the `size.contains`
                // hit gate everywhere, then the inner Transform maps the touch to
                // the moved picture.
                //
                // **The key belongs on this Positioned, not on the picture
                // inside it.** Reconciliation matches children by key at *this*
                // level; unkeyed Positioneds wrapping keyed pictures matched
                // slot-for-slot on a raise-reorder, found a different key under
                // each, and rebuilt all of them — destroying the State (and
                // gesture recogniser) of the float being dragged, mid-drag. That
                // froze a float the instant it was touched.
                Positioned.fill(
                  key: ValueKey('float-${floated.float.key}'),
                  child: _FloatingPicture(
                    conversationId: widget.conversationId,
                    floated: floated,
                    area: area,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The live geometry of one float — what a gesture changes, and the only thing
/// that changes per frame.
@immutable
class _Geometry {
  const _Geometry({
    required this.x,
    required this.y,
    required this.width,
    required this.rotation,
  });

  final double x;
  final double y;
  final double width;
  final double rotation;

  _Geometry copyWith({
    double? x,
    double? y,
    double? width,
    double? rotation,
  }) =>
      _Geometry(
        x: x ?? this.x,
        y: y ?? this.y,
        width: width ?? this.width,
        rotation: rotation ?? this.rotation,
      );
}

class _FloatingPicture extends StatefulWidget {
  const _FloatingPicture({
    required this.conversationId,
    required this.floated,
    required this.area,
  });

  final String conversationId;
  final FloatedPicture floated;
  final Size area;

  @override
  State<_FloatingPicture> createState() => _FloatingPictureState();
}

class _FloatingPictureState extends State<_FloatingPicture> {
  late final ValueNotifier<_Geometry> _live;

  /// Where the two-finger part of the gesture began. Scale and rotation are
  /// measured from here rather than accumulated, so the picture tracks the fingers
  /// exactly instead of drifting over a long manipulation.
  double _startWidth = 0;
  double _startRotation = 0;

  /// The gesture's focal point at the previous update, in **global** (screen)
  /// coordinates — the reference the drag delta is measured from.
  ///
  /// Deliberately *not* `ScaleUpdateDetails.focalPointDelta`, which is the one
  /// thing in those details expressed in the **receiver's local space**:
  /// `_delta = _localFocalPoint - localPreviousFocalPoint` in
  /// `ScaleGestureRecognizer._update`. This recogniser sits inside the live
  /// [Transform] (it has to, or the picture cannot be hit where it is drawn), so a
  /// local delta arrives turned by minus the float's rotation and divided by its
  /// live scale. Two consequences, both reported from a phone:
  ///
  /// * A turned picture did not follow the finger — drag it right and it set off
  ///   at an angle, because the delta was measured along the *picture's* axes.
  /// * Far worse: the recogniser converts through `_lastTransform`, the transform
  ///   of whichever pointer delivered the last event, and each pointer's transform
  ///   is frozen at *its own* touch-down. Add a second finger after the picture has
  ///   been moved and consecutive updates convert the same focal point through two
  ///   different matrices, manufacturing a large, constant delta out of a
  ///   stationary hand — the ~104px-every-frame rows in the 1.16.0 jank trace, with
  ///   scale and rotation frozen. That is the displacement left behind at release.
  ///
  /// `focalPoint` is global (the recogniser averages `event.position`, which
  /// `PointerEvent.transformed` leaves untransformed), so a delta taken from it is
  /// immune to both. Re-anchored in [_onStart], which the recogniser re-dispatches
  /// after every change in finger count — so the focal point's jump when a finger
  /// lands or leaves is never applied as movement either.
  Offset _lastFocal = Offset.zero;

  /// The decode size the bitmap was asked for. Held across a pinch and only
  /// stepped when the picture has grown well past it, so resizing never asks the
  /// image decoder for a new bitmap mid-gesture.
  late double _decodeWidth;

  /// The width the picture is *laid out* at. Held fixed for the whole touch, so a
  /// pinch never relayouts: the live size rides a transform scale off this. Baked
  /// to the final width once, when the touch ends.
  late double _baseWidth;

  /// How many fingers are currently on *this* float, whether it has been a
  /// two-finger gesture at any point in the current touch, and whether the touch
  /// actually moved the picture. Tracked from raw pointer events (a [Listener])
  /// rather than the scale recogniser, because the recogniser restarts itself
  /// when a finger lifts. Three jobs: (1) fix the "glitch away on release" — once
  /// a gesture has had two fingers, a lone remaining finger no longer drags it
  /// (see [_onUpdate]); (2) persist exactly once, when the last finger leaves;
  /// (3) swap the picture to a bare, decoration-free bitmap while a touch is in
  /// progress — the buttery bit (see [build]).
  int _activePointers = 0;
  bool _hadTwoFingers = false;
  bool _moved = false;

  /// True from the first *move* of a touch until it ends. While true the picture
  /// is drawn bare (no clip/shadow) for buttery transforms. Kept separate from
  /// "finger down" so a plain tap (e.g. on the ✕) never swaps the framed picture
  /// out from under itself.
  bool _manipulating = false;

  // --- TEMPORARY placement trace (see JankLogger.notePlacement) ------------
  // Captures the final frames of each release to diagnose "placed a little
  // further away on release". Delete with the rest of the jank diagnostic.
  DateTime _touchDownAt = DateTime.now();
  DateTime _lastUpdateAt = DateTime.now();
  int _moveCount = 0;
  int _maxFingers = 0;
  final List<double> _shiftHistory = <double>[]; // px moved per update frame
  final List<String> _sampleTail = <String>[]; // last few frames, formatted

  @override
  void initState() {
    super.initState();
    final float = widget.floated.float;
    _live = ValueNotifier(_Geometry(
      x: float.x,
      y: float.y,
      width: float.width,
      rotation: float.rotation,
    ));
    _decodeWidth = float.width;
    _baseWidth = float.width;
  }

  @override
  void didUpdateWidget(_FloatingPicture old) {
    super.didUpdateWidget(old);
    if (_activePointers > 0) return; // never yank a picture being handled
    final float = widget.floated.float;
    final live = _live.value;
    if (live.x != float.x ||
        live.y != float.y ||
        live.width != float.width ||
        live.rotation != float.rotation) {
      _baseWidth = float.width;
      _live.value = _Geometry(
        x: float.x,
        y: float.y,
        width: float.width,
        rotation: float.rotation,
      );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Warm the bitmap this float draws. Nothing here is about performance — it
    // is about the picture never being *absent*.
    //
    // An `Image` whose provider is not in the image cache paints nothing until
    // the decode lands, and the swap between the framed and bare pictures
    // crosses a widget boundary, so `gaplessPlayback` cannot carry the old frame
    // over. That is the reported blink: float a picture and the route that
    // floated it pops while the float's own bitmap is still decoding, so the
    // picture is on screen (the sheet's copy), gone for a frame or two, then
    // back. Returning from the recents switcher is the same story with a trimmed
    // cache. Warming it up front closes the gap for every touch; the *first*
    // appearance is closed at the two places that float a picture, which
    // precache before they pop.
    //
    // One size, not two: both states draw [_decodeWidth], so the touch-down swap
    // is a change of decoration around an already-decoded bitmap.
    _warm(_decodeWidth);
  }

  /// The provider this float draws at a given display width — the one function
  /// [build] and the warming paths must agree on.
  ImageProvider? _providerFor(double displayWidth) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    return avatarImage(
      widget.floated.ref,
      displaySize: displayWidth,
      devicePixelRatio: dpr <= 0 ? 1 : dpr,
    );
  }

  /// Decodes the bitmap for [displayWidth] into the image cache without drawing
  /// it, so whatever asks for it next has it immediately.
  void _warm(double displayWidth) {
    final provider = _providerFor(displayWidth);
    if (provider == null) return;
    // Failure is not interesting: a missing or broken picture already has a
    // placeholder, and this is only ever an optimisation of *when* it appears.
    precacheImage(provider, context, onError: (_, _) {});
  }

  /// Steps the decode size after a big resize — but only once the sharper bitmap
  /// is actually in hand. Swapping `_decodeWidth` first would hand the framed
  /// picture a provider that has to decode, blanking it for a frame or two at the
  /// exact moment the fingers leave. Until then the previous bitmap is drawn
  /// scaled: slightly soft for an instant, rather than absent.
  Future<void> _stepDecodeWidth(double width) async {
    final provider = _providerFor(width);
    if (provider == null) {
      _decodeWidth = width;
      return;
    }
    try {
      await precacheImage(provider, context, onError: (_, _) {});
    } catch (_) {
      // A picture that will not decode keeps the size it had.
      return;
    }
    // Not mid-touch: a fresh gesture may have moved on to another size, and it
    // will step again itself when it ends.
    if (!mounted || _activePointers > 0) return;
    setState(() => _decodeWidth = width);
  }

  @override
  void dispose() {
    _live.dispose();
    super.dispose();
  }

  void _onPointerDown() {
    if (_activePointers == 0) {
      // A fresh touch. Pin the layout width for its whole duration so the live
      // size can ride a transform scale off it. No visual change yet — the swap
      // to the bare picture waits for the first actual move, so a tap on the ✕
      // still hits the framed control.
      _moved = false;
      _baseWidth = _live.value.width;
      // TEMP placement trace: begin a fresh capture for this touch.
      _touchDownAt = DateTime.now();
      _lastUpdateAt = _touchDownAt;
      _moveCount = 0;
      _maxFingers = 0;
      _shiftHistory.clear();
      _sampleTail.clear();
    }
    _activePointers++;
    if (_activePointers > _maxFingers) _maxFingers = _activePointers;
    if (_activePointers >= 2) _hadTwoFingers = true;
  }

  void _onPointerUp() {
    _activePointers = (_activePointers - 1).clamp(0, 10);
    if (_activePointers > 0) return;
    // The whole touch is over. Bake the transform-scale into a real layout width
    // (and re-decode for a big size change), swap back to the framed picture, and
    // persist exactly **once** — here, not on every finger change. Settling calls
    // notifyListeners and schedules a whole-store save; doing that on each
    // finger-lift during a manipulation is what froze the app every few seconds
    // (and the mid-manipulation rebuild is what made it shift).
    final g = _live.value;
    final redecode = g.width > _decodeWidth * 1.6 || g.width < _decodeWidth / 2;
    // TEMP placement trace: record what the final frames did, before the guard
    // state is reset. Only for a touch that actually moved the picture.
    if (_moved) _emitPlacement();
    _hadTwoFingers = false;
    setState(() {
      _manipulating = false;
      _baseWidth = g.width;
    });
    // Sharper (or smaller) bitmap for the new size, applied only once it has
    // decoded — see [_stepDecodeWidth].
    if (redecode) _stepDecodeWidth(g.width);
    if (_moved && mounted) {
      _moved = false;
      context.read<AppState>().settleFloatingImage(
            widget.conversationId,
            widget.floated.float,
            x: g.x,
            y: g.y,
            width: g.width,
            rotation: g.rotation,
            raise: true,
          );
    }
  }

  void _onStart(ScaleStartDetails details) {
    // Per gesture segment (a pinch restarts as fingers shift): the reference the
    // scale/rotation are measured from. Purely local — no setState, no persist.
    _startWidth = _live.value.width;
    _startRotation = _live.value.rotation;
    // The drag reference too, so the focal point's jump when the finger count
    // changes (it is the *mean* of the fingers) is never applied as movement.
    _lastFocal = details.focalPoint;
    // Raising is a local concern until the touch ends: reordering the stored list
    // here would notify every listener and re-encode the whole chat store, in the
    // very frame the drag is trying to begin.
    _RaiseScope.of(context)?.raise(widget.floated.float.key);
  }

  void _onUpdate(ScaleUpdateDetails details) {
    final width = widget.area.width <= 0 ? 1.0 : widget.area.width;
    final height = widget.area.height <= 0 ? 1.0 : widget.area.height;
    final live = _live.value;

    // How far the fingers moved on **screen** since the last update. Always
    // advanced, even on a frame whose movement is thrown away below, or the
    // suppressed distance would be banked up and applied in one lurch later.
    final moved = details.focalPoint - _lastFocal;
    _lastFocal = details.focalPoint;

    // Translation is applied for a genuine drag (two fingers on the picture, or a
    // single finger that was *never* part of a pinch). It is deliberately NOT
    // applied for a lone finger left over from a two-finger gesture — that finger
    // sliding as the hand lifts is what used to fling the picture off to a new
    // spot on release.
    final translating = details.pointerCount >= 2 || !_hadTwoFingers;
    var next = translating
        ? live.copyWith(
            x: FloatingImage.clampFraction(live.x + moved.dx / width),
            y: FloatingImage.clampFraction(live.y + moved.dy / height),
          )
        : live;
    if (details.pointerCount >= 2) {
      final wanted = _startWidth * details.scale;
      final bounded = wanted
          .clamp(kFloatingImageMinWidth, kFloatingImageMaxWidth)
          .toDouble();
      // Pinching past a bound must not bank up a dead zone. With the reference
      // left alone, spreading to 3x the cap means the fingers have to travel all
      // the way back to where they started before the size responds at all — and
      // the picture then settles at a size with no relation to where the fingers
      // are, which reads as "it jumps to a different size every time I touch it".
      // Re-anchoring keeps it pinned at the bound and lets it leave the moment the
      // fingers reverse.
      if (bounded != wanted && details.scale > 0) {
        _startWidth = bounded / details.scale;
      }
      next = next.copyWith(
        width: bounded,
        rotation: _startRotation + details.rotation,
      );
    }
    _moved = true;
    _recordSample(details, translating, next, moved);
    // First move of the touch: swap to the bare picture (one rebuild). After
    // that the notifier drives the transforms, so a pointer-move repaints without
    // rebuilding.
    if (!_manipulating) {
      JankLogger.instance.breadcrumb('float:drag start');
      setState(() => _manipulating = true);
    }
    _live.value = next;
  }

  // --- TEMPORARY placement trace helpers -----------------------------------

  /// Records one update frame: the on-screen px the picture actually moved
  /// (0 when the leftover-finger guard blocked translation), plus the raw
  /// figures needed to tell a legitimate drag from a lift-off jump.
  void _recordSample(ScaleUpdateDetails details, bool translating,
      _Geometry next, Offset moved) {
    try {
      _moveCount++;
      final now = DateTime.now();
      // What the picture visibly moved this frame: the applied screen-space
      // delta, which is exactly what got added to the position (0 if the guard
      // suppressed translation this frame).
      final shift = translating ? moved.distance : 0.0;
      _shiftHistory.add(shift);
      final dt = now.difference(_touchDownAt).inMilliseconds;
      _sampleTail.add('dt=${dt}ms d=${shift.toStringAsFixed(1)}px '
          'pc=${details.pointerCount} ${translating ? 'T' : '.'} '
          's=${details.scale.toStringAsFixed(2)} '
          'r=${(next.rotation * 180 / 3.1415926).toStringAsFixed(0)}');
      if (_sampleTail.length > 8) _sampleTail.removeAt(0);
      _lastUpdateAt = now;
    } catch (_) {
      // A diagnostic must never take the app down.
    }
  }

  /// Emits the finished trace for this touch to [JankLogger].
  void _emitPlacement() {
    try {
      if (_shiftHistory.isEmpty) return;
      final last = _shiftHistory.last;
      final releaseShift = _shiftHistory.length >= 2
          ? _shiftHistory[_shiftHistory.length - 1] +
              _shiftHistory[_shiftHistory.length - 2]
          : last;
      final sorted = List<double>.from(_shiftHistory)..sort();
      final median = sorted[sorted.length ~/ 2];
      JankLogger.instance.notePlacement(FloatPlacement(
        at: DateTime.now(),
        label: widget.floated.float.imageId.isNotEmpty
            ? widget.floated.float.imageId
            : widget.floated.float.key,
        moves: _moveCount,
        hadTwoFingers: _hadTwoFingers,
        maxFingers: _maxFingers,
        durationMs: DateTime.now().difference(_touchDownAt).inMilliseconds,
        gapBeforeUpMs: DateTime.now().difference(_lastUpdateAt).inMilliseconds,
        releaseShiftPx: releaseShift,
        lastShiftPx: last,
        typicalShiftPx: median,
        tail: List<String>.from(_sampleTail),
      ));
    } catch (_) {
      // A diagnostic must never take the app down.
    }
  }

  @override
  Widget build(BuildContext context) {
    // One bitmap, decoded for the size the picture is drawn at, used whether it
    // is at rest or under a finger.
    //
    // It used to drop to a ~512 device-px working texture with nearest-neighbour
    // sampling for the duration of a touch, on the theory that re-sampling a big
    // bitmap is what stalls a phone GPU during a pinch. The visible cost of that
    // was the reported bug: a float went blocky the moment it was touched and
    // stayed blocky for the whole drag, because 512px is *half* the bucket a
    // normal float sits in and nearest-neighbour shows every one of those missing
    // pixels. The theory was also aimed at the wrong thing — [avatarImage]
    // already caps the decode at the display bucket (never source resolution),
    // and a GPU's cost for a scaled blit is per destination pixel, which does not
    // change with the size of the texture behind it. What actually cost 16ms a
    // frame was re-rasterising the rounded clip and the blurred shadow under a
    // changing scale, and that is what [_BarePicture] still drops.
    final provider = _providerFor(_decodeWidth);

    // The inner boundary keeps the picture and the ✕ as a retained layer of its
    // own. A [Listener] wraps the gesture detector purely to count fingers on
    // this float (raw pointer events survive the scale recogniser restarting
    // itself when a finger lifts), which is what lets [_onUpdate] ignore the lone
    // finger left over from a pinch.
    final target = Listener(
      onPointerDown: (_) => _onPointerDown(),
      onPointerUp: (_) => _onPointerUp(),
      onPointerCancel: (_) => _onPointerUp(),
      child: RawGestureDetector(
        // The gesture detector sits **inside** the transform. A `Transform` moves
        // paint, not hit-testing: a box is only hit within its own layout bounds,
        // so a detector wrapped *around* the transform keeps its target at the
        // origin while the picture is drawn elsewhere — fingers then hit nothing.
        // `RenderTransform.hitTestChildren` maps the touch through the matrix, so
        // a child of the transform is hit exactly where it looks. Built once and
        // handed to [AnimatedBuilder] as `child`, so a drag frame rebuilds only
        // the transforms and never reconfigures the recogniser.
        gestures: <Type, GestureRecognizerFactory>{
          ScaleGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<ScaleGestureRecognizer>(
            () => ScaleGestureRecognizer(debugOwner: this),
            (instance) => instance
              ..onStart = _onStart
              ..onUpdate = _onUpdate
              // Report movement from the first pointer-move rather than after the
              // slop is crossed, so a drag starts under the finger instead of
              // jumping once it is recognised.
              ..dragStartBehavior = DragStartBehavior.down,
          ),
        },
        // While a touch is in progress the picture is drawn as its **bare bitmap**
        // — no blurred shadow, no ✕ — so moving/scaling/rotating it is just a GPU
        // sample of a texture (drawImageRect under the transform) with no
        // per-frame re-rasterisation. A benchmark on Linux measured the framed
        // version at ~16ms raster (120/250 frames over budget, spikes to 36ms+)
        // and this bare version at ~5ms (0 sustained over-budget frames). The
        // shadow — the expensive part to re-raster under a scale — comes back the
        // instant the fingers leave. Nothing is captured or re-captured (unlike a
        // SnapshotWidget), so it behaves the same on Skia and Impeller. Both
        // states draw the *same* provider, so the swap cannot blink.
        child: _manipulating
            ? _BarePicture(provider: provider)
            : RepaintBoundary(
                child: _Frame(
                  provider: provider,
                  onDismiss: () => context.read<AppState>().unfloatImage(
                        widget.conversationId,
                        widget.floated.float,
                      ),
                ),
              ),
      ),
    );

    final animated = AnimatedBuilder(
      // Only these paint-only transforms rebuild per frame. The picture, shadow
      // and ✕ are a retained layer of their own (the boundary in `target`), so
      // this re-record is just "push a few transforms, re-add a cached layer".
      animation: _live,
      child: target,
      builder: (context, child) {
        // Resize rides the transform, not the layout: the picture is laid out at
        // the fixed [_baseWidth] and the matrix scales it to the live width. So a
        // pinch is a matrix change on an already-rasterised layer — no relayout,
        // no re-rasterising the picture per frame. The scale is baked back into
        // the width once, on gesture end.
        final geometry = _live.value;
        final scale = _baseWidth <= 0 ? 1.0 : geometry.width / _baseWidth;
        // The float is anchored by its **centre**, and rotation/scale pivot about
        // that same centre — the two must agree or the picture jumps the instant
        // the fingers leave. Here is why it used to jump: a pinch scaled about the
        // centre (right), but the stored anchor was the top-left corner, so on
        // release the picture was re-laid-out pinned to that corner and slid by
        // half the size change. Anchoring the centre removes the mismatch.
        //
        // The centre is placed without ever needing the picture's height:
        // [FractionalTranslation] shifts the box by half of *its own* laid-out
        // size, so `translate(centre)` then `-0.5,-0.5` lands the box's middle on
        // the point whatever its dimensions. All paint-only — nothing relayouts.
        return OverflowBox(
          // Loosen the tight full-screen constraints so the box below takes its
          // own intrinsic size; the transforms then move it from the top-left.
          //
          // **[OverflowBox], not [Align].** Align only *loosens* the layer's
          // constraints, which keeps their maxima — and `SizedBox` enforces its
          // width against what it is given, so a float wider than the chat was
          // silently laid out at the chat's width instead. That is the reported
          // "it stops getting bigger at a certain size", and it also broke the
          // pinch: the live scale is `width / _baseWidth`, so once `_baseWidth`
          // ran past the clamped layout the drawn size no longer matched the
          // geometry, and every release re-baked a width the layout would not
          // honour — the picture snapping to a different size each touch. An
          // OverflowBox hands the child genuinely unbounded constraints (and
          // still sizes *itself* to the layer, so the hit gate below is
          // unchanged), so the laid-out width is the width.
          alignment: Alignment.topLeft,
          minWidth: 0,
          maxWidth: double.infinity,
          minHeight: 0,
          maxHeight: double.infinity,
          child: Transform.translate(
            offset: Offset(
              geometry.x * widget.area.width,
              geometry.y * widget.area.height,
            ),
            child: FractionalTranslation(
              translation: const Offset(-0.5, -0.5),
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.rotationZ(geometry.rotation)
                  ..scaleByDouble(scale, scale, scale, 1),
                child: SizedBox(width: _baseWidth, child: child),
              ),
            ),
          ),
        );
      },
    );

    return animated;
  }
}

/// The picture with no shadow and no ✕, shown *only while a touch is in
/// progress*. Drawing a bare bitmap under the live transform is a GPU texture
/// sample with no per-frame re-rasterisation, which is what makes the
/// manipulation buttery. It keeps the same top/right padding as [_Frame] so the
/// picture does not shift when the framed and bare versions swap on touch
/// start/end.
class _BarePicture extends StatelessWidget {
  const _BarePicture({required this.provider});

  final ImageProvider? provider;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, right: 10),
      child: provider == null
          ? const AspectRatio(
              aspectRatio: 4 / 3,
              child: Center(child: Icon(Icons.broken_image_outlined)),
            )
          // Rounded to match the framed picture, so the corners don't snap
          // square the instant a finger lands. Only the *clip* is kept — no
          // shadow, no ✕ — so this stays the cheap manipulation path. The clip
          // is far lighter than the shadow it omits, and on Impeller (this app's
          // renderer) a rounded clip is a stencil op, not an offscreen layer.
          : ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image(
                image: provider!,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                // Bilinear — what a GPU's texture unit does in hardware, so it
                // costs the same as no filtering at all while a scale or rotation
                // is live. This used to be [FilterQuality.none]
                // (nearest-neighbour) on the same reasoning photo_view uses it,
                // but nearest-neighbour is exactly what made a touched float look
                // blocky, and the saving it bought is not measurable next to the
                // shadow this widget already drops.
                filterQuality: FilterQuality.low,
                errorBuilder: (_, _, _) => const AspectRatio(
                  aspectRatio: 4 / 3,
                  child: Center(child: Icon(Icons.broken_image_outlined)),
                ),
              ),
            ),
    );
  }
}

/// The drawn float: the picture, a rounded frame, and the ✕.
///
/// Deliberately free of geometry, so one instance survives a whole gesture and
/// only its ancestor transform changes.
class _Frame extends StatelessWidget {
  const _Frame({required this.provider, required this.onDismiss});

  final ImageProvider? provider;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(
          // Room for the ✕ hanging over the corner, or half of it would sit
          // outside its own hit region.
          padding: const EdgeInsets.only(top: 10, right: 10),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: scheme.surfaceContainerHighest,
              // A plain shadow rather than a Material elevation: an elevation is
              // an implicitly-animated, separately-composited layer, and that is
              // not what a picture being dragged needs. The blur is cheap here
              // because during a manipulation the whole frame is captured to a
              // texture (see the SnapshotWidget) and only that texture is moved.
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.32),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: provider == null
                  ? const AspectRatio(
                      aspectRatio: 4 / 3,
                      child: Center(child: Icon(Icons.broken_image_outlined)),
                    )
                  : Image(
                      image: provider!,
                      fit: BoxFit.contain,
                      // No fade-in: a float being dragged should not animate its
                      // own opacity underneath the finger.
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => const AspectRatio(
                        aspectRatio: 4 / 3,
                        child: Center(child: Icon(Icons.broken_image_outlined)),
                      ),
                    ),
            ),
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          child: _DismissButton(onTap: onDismiss),
        ),
      ],
    );
  }
}

/// The ✕ that takes a picture back off the chat.
class _DismissButton extends StatelessWidget {
  const _DismissButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface.withValues(alpha: 0.92),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(Icons.close, size: 16, color: scheme.onSurface),
        ),
      ),
    );
  }
}

/// Carries the "bring this float forward" callback down to each picture without
/// making it a write to persisted state.
///
/// Z-order is the list's order, and the list is only rewritten when a gesture
/// ends. In between, this moves the float within the layer's own children so the
/// one under the finger is the one on top, immediately.
class _RaiseScope extends InheritedWidget {
  const _RaiseScope({required this.raise, required super.child});

  final void Function(String key) raise;

  static _RaiseScope? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_RaiseScope>();

  @override
  bool updateShouldNotify(_RaiseScope old) => false;
}
