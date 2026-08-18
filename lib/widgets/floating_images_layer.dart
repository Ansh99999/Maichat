import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../models/floating_image.dart';
import '../state/app_state.dart';
import 'avatar_image.dart';

/// The pictures pinned over a chat.
///
/// One finger drags, two resize and turn. All three come from a single
/// [ScaleGestureRecognizer], which is what makes it feel like handling a
/// photograph rather than operating three modes.
///
/// **Everything here is built for the gesture loop**, because the first version
/// was unusable on a real phone:
///
/// * A picture's geometry lives in a [ValueNotifier] while a gesture runs, and
///   only the [Transform] listens to it. A `setState` per pointer-move rebuilt the
///   whole float — image, shadow, ✕ — sixty times a second.
/// * Nothing writes to [AppState] during a gesture. Both the raise-to-front and
///   the final position used to go through `_editConversation`, which calls
///   `notifyListeners()` and re-encodes *every* conversation to JSON. At the start
///   of a drag that stalls the frame the drag is trying to start in, and every
///   listener of AppState — the whole message list included — rebuilt with it.
/// * The bitmap is decoded for a *bucket*, not for the live width, so pinching
///   does not ask the decoder for a new size on every frame.
/// * Each float is its own [RepaintBoundary], so moving one does not repaint the
///   conversation behind it.
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
    // Rebuilt only when the set of floats changes — not on every AppState
    // notification, which includes each streaming delta of a reply.
    final floats = context.select<AppState, List<FloatedPicture>>(
      (state) =>
          state.floatingImagesFor(state.conversationById(widget.conversationId)),
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
                _FloatingPicture(
                  // Keyed by picture, so raising one (which reorders the list)
                  // moves its existing state instead of rebuilding it and
                  // dropping an in-flight gesture.
                  key: ValueKey('float-${floated.float.key}'),
                  conversationId: widget.conversationId,
                  floated: floated,
                  area: area,
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The live geometry of one float, as something only the transform listens to.
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
    super.key,
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

  /// The decode size the bitmap was asked for. Held across a pinch and only
  /// stepped when the picture has grown well past it, so resizing never asks the
  /// image decoder for a new bitmap mid-gesture.
  late double _decodeWidth;

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
  }

  @override
  void didUpdateWidget(_FloatingPicture old) {
    super.didUpdateWidget(old);
    // Only adopt stored geometry when it actually differs — a rebuild in the
    // middle of a gesture must not yank the picture back to where it started.
    final float = widget.floated.float;
    final live = _live.value;
    if (float.x != old.floated.float.x ||
        float.y != old.floated.float.y ||
        float.width != old.floated.float.width ||
        float.rotation != old.floated.float.rotation) {
      _live.value = _Geometry(
        x: float.x,
        y: float.y,
        width: float.width,
        rotation: float.rotation,
      );
    } else if (live.width != float.width) {
      // Stored width is authoritative between gestures.
      _live.value = live.copyWith(width: float.width);
    }
  }

  @override
  void dispose() {
    _live.dispose();
    super.dispose();
  }

  void _onStart(ScaleStartDetails details) {
    _startWidth = _live.value.width;
    _startRotation = _live.value.rotation;
    // Raising is a local concern until the gesture ends: reordering the stored
    // list here would notify every listener and re-encode the whole chat store,
    // in the very frame the drag is trying to begin.
    _RaiseScope.of(context)?.raise(widget.floated.float.key);
  }

  void _onUpdate(ScaleUpdateDetails details) {
    final width = widget.area.width <= 0 ? 1.0 : widget.area.width;
    final height = widget.area.height <= 0 ? 1.0 : widget.area.height;
    final live = _live.value;

    // One finger drags. `focalPointDelta` is movement since the last update, so
    // position accumulates rather than being derived from the start point.
    var next = live.copyWith(
      x: FloatingImage.clampFraction(
          live.x + details.focalPointDelta.dx / width),
      y: FloatingImage.clampFraction(
          live.y + details.focalPointDelta.dy / height),
    );
    if (details.pointerCount >= 2) {
      next = next.copyWith(
        width: (_startWidth * details.scale)
            .clamp(kFloatingImageMinWidth, kFloatingImageMaxWidth)
            .toDouble(),
        rotation: _startRotation + details.rotation,
      );
    }
    // No setState: the notifier drives a single AnimatedBuilder around the
    // transform, so a pointer-move repaints one picture and rebuilds nothing else.
    _live.value = next;
  }

  Future<void> _onEnd(ScaleEndDetails details) async {
    final geometry = _live.value;
    // The write, once the fingers have stopped. Note a two-finger manipulation
    // can end more than once: lifting one finger makes the recogniser end this
    // gesture and start another for the finger still down
    // (`ScaleGestureRecognizer._reconfigure`), so a pinch settles once per finger
    // lifted. That is a couple of writes per manipulation rather than one per
    // pointer-move, which is the cost that mattered.
    //
    // Raising is committed here too, so the z-order the user set by touching
    // things outlives the screen.
    final state = context.read<AppState>();
    await state.settleFloatingImage(
      widget.conversationId,
      widget.floated.float,
      x: geometry.x,
      y: geometry.y,
      width: geometry.width,
      rotation: geometry.rotation,
      raise: true,
    );
    if (!mounted) return;
    // A picture much larger than the bitmap it was decoded for is worth one
    // re-decode, now the gesture is over rather than during it.
    if (geometry.width > _decodeWidth * 1.6 ||
        geometry.width < _decodeWidth / 2) {
      setState(() => _decodeWidth = geometry.width);
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // Decoded once for a size that holds across a pinch, not for the live width.
    final provider = avatarImage(
      widget.floated.ref,
      displaySize: _decodeWidth,
      devicePixelRatio: media.devicePixelRatio,
    );

    // Built once and reused by every frame of a gesture: the picture, its frame
    // and the ✕ do not change while it is being moved.
    final picture = _Frame(
      provider: provider,
      onDismiss: () => context.read<AppState>().unfloatImage(
            widget.conversationId,
            widget.floated.float,
          ),
    );

    return AnimatedBuilder(
      animation: _live,
      builder: (context, _) {
        final geometry = _live.value;
        return Positioned(
          left: geometry.x * widget.area.width,
          top: geometry.y * widget.area.height,
          child: Transform.rotate(
            angle: geometry.rotation,
            child: SizedBox(
              width: geometry.width,
              child: RawGestureDetector(
                gestures: <Type, GestureRecognizerFactory>{
                  ScaleGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                          ScaleGestureRecognizer>(
                    () => ScaleGestureRecognizer(debugOwner: this),
                    (instance) => instance
                      ..onStart = _onStart
                      ..onUpdate = _onUpdate
                      ..onEnd = _onEnd
                      // Report movement from the first pointer-move rather than
                      // after the slop is crossed, so a drag starts under the
                      // finger instead of jumping once it is recognised.
                      ..dragStartBehavior = DragStartBehavior.down,
                  ),
                },
                child: picture,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The drawn float: the picture, a rounded frame, and the ✕.
///
/// Deliberately const-friendly and free of geometry, so one instance survives a
/// whole gesture and only its ancestor transform changes.
class _Frame extends StatelessWidget {
  const _Frame({required this.provider, required this.onDismiss});

  final ImageProvider? provider;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: Stack(
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
                // A plain shadow rather than a Material elevation: an elevation
                // is an implicitly-animated, separately-composited layer, and
                // that is not what a picture being dragged needs.
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
                        // No fade-in: a float that is being dragged should not
                        // animate its own opacity underneath the finger.
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => const AspectRatio(
                          aspectRatio: 4 / 3,
                          child:
                              Center(child: Icon(Icons.broken_image_outlined)),
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
      ),
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
