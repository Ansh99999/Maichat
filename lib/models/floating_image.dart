import 'dart:math' as math;

/// One picture floating over a chat: where it sits, how big it is, and how far it
/// has been turned.
///
/// [x] and [y] are **fractions of the chat area** (0..1 measured from its top
/// left), not logical pixels. A phone rotated, a tablet, or a different text
/// scale all change the area's size, and a float stored in pixels would drift off
/// screen or bunch into a corner; a fraction lands in the same visual place
/// everywhere. [width] is in logical pixels because a picture should not grow
/// just because the window did.
class FloatingImage {
  FloatingImage({
    required this.imageId,
    this.x = 0.08,
    this.y = 0.12,
    this.width = kFloatingImageDefaultWidth,
    this.rotation = 0,
  });

  /// The [GalleryImage.id] being shown. The picture reference itself is not
  /// copied here, so editing or re-pointing the gallery entry is reflected, and a
  /// deleted picture simply stops resolving (the layer skips it).
  final String imageId;

  /// Position of the float's top-left corner, as a fraction of the chat area.
  double x;
  double y;

  /// The drawn width in logical pixels; the height follows the picture's own
  /// aspect ratio.
  double width;

  /// Rotation in radians, clockwise.
  double rotation;

  FloatingImage copyWith({
    double? x,
    double? y,
    double? width,
    double? rotation,
  }) =>
      FloatingImage(
        imageId: imageId,
        x: x ?? this.x,
        y: y ?? this.y,
        width: width ?? this.width,
        rotation: rotation ?? this.rotation,
      );

  Map<String, dynamic> toJson() => {
        'imageId': imageId,
        'x': x,
        'y': y,
        'width': width,
        if (rotation != 0) 'rotation': rotation,
      };

  factory FloatingImage.fromJson(Map<String, dynamic> json) => FloatingImage(
        imageId: json['imageId'] as String? ?? '',
        // Clamped on the way in as well as on the way out: a stored value can
        // come from an older build, a hand-edited store, or a screen that has
        // since changed shape, and a float nobody can reach is a float nobody can
        // dismiss.
        x: _fraction(json['x']),
        y: _fraction(json['y']),
        width: ((json['width'] as num?)?.toDouble() ??
                kFloatingImageDefaultWidth)
            .clamp(kFloatingImageMinWidth, kFloatingImageMaxWidth)
            .toDouble(),
        rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
      );

  static double _fraction(Object? value) {
    final n = (value as num?)?.toDouble() ?? 0;
    if (n.isNaN || n.isInfinite) return 0;
    return n.clamp(kFloatingImageMinFraction, kFloatingImageMaxFraction)
        .toDouble();
  }

  /// Keeps a float's corner inside the chat area, leaving a sliver of it always
  /// reachable so it can be dragged back or closed.
  static double clampFraction(double value) => _fraction(value);

  /// Rotation, normalised into (-π, π] so repeated turns do not accumulate into
  /// a huge number in the store.
  static double normaliseRotation(double radians) {
    if (radians.isNaN || radians.isInfinite) return 0;
    const twoPi = math.pi * 2;
    var r = radians % twoPi;
    if (r > math.pi) r -= twoPi;
    if (r <= -math.pi) r += twoPi;
    return r;
  }
}

/// How wide a picture arrives on the chat, in logical pixels — big enough to see,
/// small enough that it does not bury the conversation.
const double kFloatingImageDefaultWidth = 180;

/// The pinch-to-resize bounds. The floor keeps the ✕ tappable; the ceiling is
/// generous because "as big as the screen" is a legitimate thing to want.
const double kFloatingImageMinWidth = 72;
const double kFloatingImageMaxWidth = 1600;

/// A float may hang a little off the edge, but never so far that its handle
/// leaves the chat area.
const double kFloatingImageMinFraction = -0.15;
const double kFloatingImageMaxFraction = 0.95;
