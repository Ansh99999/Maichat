import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../models/floating_image.dart';
import '../models/gallery_image.dart';
import '../state/app_state.dart';
import 'avatar_image.dart';

/// The pictures pinned over a chat.
///
/// Each one can be dragged with one finger, and resized and turned with two. They
/// are decoration: nothing here is part of the conversation, so nothing here
/// reaches the model or an export — the chat carries only where each picture sits.
///
/// The layer itself is transparent and lets every touch it does not use fall
/// through to the thread underneath, so a chat with floats on it still scrolls.
class FloatingImagesLayer extends StatelessWidget {
  const FloatingImagesLayer({super.key, required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final conversation = state.conversationById(conversationId);
    final floats = state.floatingImagesFor(conversation);
    if (floats.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        // The area a float's fractional position is measured against. Taking it
        // from the layout rather than the window means the sums are the same
        // whether the keyboard is up, the bar is showing, or the phone is turned.
        final area = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            for (final (float, image) in floats)
              _FloatingPicture(
                // Keyed by picture so raising one (which reorders the list) moves
                // the existing state rather than rebuilding it from scratch and
                // dropping an in-flight gesture.
                key: ValueKey('float-${float.imageId}'),
                conversationId: conversationId,
                float: float,
                image: image,
                area: area,
              ),
          ],
        );
      },
    );
  }
}

class _FloatingPicture extends StatefulWidget {
  const _FloatingPicture({
    super.key,
    required this.conversationId,
    required this.float,
    required this.image,
    required this.area,
  });

  final String conversationId;
  final FloatingImage float;
  final GalleryImage image;
  final Size area;

  @override
  State<_FloatingPicture> createState() => _FloatingPictureState();
}

class _FloatingPictureState extends State<_FloatingPicture> {
  /// The live transform while a gesture runs. Held here, not in the store: a
  /// gesture produces several updates per frame, and writing the conversation on
  /// each one would rewrite the whole store dozens of times a second.
  double? _x;
  double? _y;
  double? _width;
  double? _rotation;

  /// Where the two-finger part of the gesture began. Scale and rotation are
  /// measured from here rather than accumulated, so the picture tracks the fingers
  /// exactly instead of drifting over a long manipulation. Position *is*
  /// accumulated, because a drag reports movement since the last update.
  late double _startWidth;
  late double _startRotation;

  double get _liveX => _x ?? widget.float.x;
  double get _liveY => _y ?? widget.float.y;
  double get _liveWidth => _width ?? widget.float.width;
  double get _liveRotation => _rotation ?? widget.float.rotation;

  void _onStart(ScaleStartDetails details) {
    _startWidth = _liveWidth;
    _startRotation = _liveRotation;
    // Touching a float brings it forward, so the one being handled is the one on
    // top — and z-order stays something the user controls by touching things.
    context.read<AppState>().raiseFloatingImage(
          widget.conversationId,
          widget.image.id,
        );
  }

  void _onUpdate(ScaleUpdateDetails details) {
    final width = widget.area.width <= 0 ? 1.0 : widget.area.width;
    final height = widget.area.height <= 0 ? 1.0 : widget.area.height;
    setState(() {
      // One finger drags. `focalPointDelta` is the movement since the last
      // update, which is why the position accumulates rather than being derived
      // from the start point.
      _x = FloatingImage.clampFraction(
          _liveX + details.focalPointDelta.dx / width);
      _y = FloatingImage.clampFraction(
          _liveY + details.focalPointDelta.dy / height);
      if (details.pointerCount >= 2) {
        // Two fingers scale and turn, both measured from where the gesture began
        // so the picture tracks the fingers exactly.
        _width = (_startWidth * details.scale)
            .clamp(kFloatingImageMinWidth, kFloatingImageMaxWidth)
            .toDouble();
        _rotation = _startRotation + details.rotation;
      }
    });
  }

  Future<void> _onEnd(ScaleEndDetails details) async {
    final state = context.read<AppState>();
    await state.moveFloatingImage(
      widget.conversationId,
      widget.image.id,
      x: _liveX,
      y: _liveY,
      width: _liveWidth,
      rotation: _liveRotation,
    );
    if (!mounted) return;
    // Hand control back to the stored values now they agree with the screen.
    setState(() {
      _x = null;
      _y = null;
      _width = null;
      _rotation = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final media = MediaQuery.of(context);
    final provider = avatarImage(
      widget.image.image,
      // Asked for at the size it is drawn, so a photo straight off the camera
      // does not sit in memory at full resolution while it floats.
      displaySize: _liveWidth,
      devicePixelRatio: media.devicePixelRatio,
    );

    return Positioned(
      left: _liveX * widget.area.width,
      top: _liveY * widget.area.height,
      child: Transform.rotate(
        angle: _liveRotation,
        child: RawGestureDetector(
          gestures: <Type, GestureRecognizerFactory>{
            // One recogniser for all three gestures: a pan and a pinch are the
            // same thing to `ScaleGestureRecognizer`, which is what makes drag,
            // resize and rotate feel like one continuous manipulation instead of
            // three modes.
            ScaleGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<ScaleGestureRecognizer>(
              () => ScaleGestureRecognizer(debugOwner: this),
              (instance) => instance
                ..onStart = _onStart
                ..onUpdate = _onUpdate
                ..onEnd = _onEnd,
            ),
          },
          child: SizedBox(
            width: _liveWidth,
            // The ✕ hangs over the corner, so the frame needs room for it or half
            // the control would be outside its own hit region.
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 10, right: 10),
                  child: Material(
                    elevation: 6,
                    borderRadius: BorderRadius.circular(12),
                    clipBehavior: Clip.antiAlias,
                    child: provider == null
                        ? SizedBox(
                            height: _liveWidth * 0.75,
                            child: const Center(
                              child: Icon(Icons.broken_image_outlined),
                            ),
                          )
                        : Image(
                            image: provider,
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => SizedBox(
                              height: _liveWidth * 0.75,
                              child: const Center(
                                child: Icon(Icons.broken_image_outlined),
                              ),
                            ),
                          ),
                  ),
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: _DismissButton(
                    // Turned back the other way, so the ✕ stays upright however
                    // far the picture has been rotated.
                    counterRotation: -_liveRotation,
                    onTap: () => state.unfloatImage(
                      widget.conversationId,
                      widget.image.id,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The ✕ that takes a picture back off the chat.
class _DismissButton extends StatelessWidget {
  const _DismissButton({required this.counterRotation, required this.onTap});

  final double counterRotation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Transform.rotate(
      angle: counterRotation,
      child: Material(
        color: scheme.surface.withValues(alpha: 0.92),
        shape: const CircleBorder(),
        elevation: 3,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(Icons.close, size: 16, color: scheme.onSurface),
          ),
        ),
      ),
    );
  }
}

